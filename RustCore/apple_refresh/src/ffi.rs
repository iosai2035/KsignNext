//! FFI plumbing: C-string handling, the uniform JSON envelope
//! (design doc §5.1.3 / §7) and the panic boundary (§5.1.8).
//!
//! Every function returns `int32_t` (0 = success, non-zero = failure,
//! matching `ZsignBridge.h`) and writes a JSON string to `char
//! **out_json` on both success and failure. The caller frees it with
//! `apple_refresh_string_free`. The JSON never contains a password or
//! a token value.

use serde_json::Value;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::errors;

/// Run an FFI body behind the panic boundary. The body returns
/// `Ok(json)` for a JSON payload to write (its `"ok"` field decides
/// the 0/1 return code) or `Err(json)` for an already-built error
/// envelope. A panic anywhere inside becomes an `internal` error —
/// a panic must never unwind across the FFI boundary.
///
/// Note: `run` deliberately does NOT require `F: UnwindSafe`.
/// The closures capture `&AppleRefreshSession`, whose
/// `Arc<SessionInner>` → `Arc<GrandSlam>` → reqwest/rustls trait
/// objects contain interior mutability and are not `UnwindSafe`,
/// so such a bound would reject every session call site. Instead
/// `AssertUnwindSafe` asserts the boundary is safe: a panic inside
/// is caught here and reported as the `internal` error envelope,
/// and the caller must treat the session as dead afterwards
/// (a panic may have left session state inconsistent).
pub fn run<F>(out_json: *mut *mut c_char, step: &str, f: F) -> i32
where
    F: FnOnce() -> Result<Value, Value>,
{
    let result = catch_unwind(AssertUnwindSafe(f));
    let value = match result {
        Ok(Ok(v)) => v,
        Ok(Err(v)) => v,
        Err(_) => errors::internal(step, "Rust panic at the FFI boundary"),
    };
    unsafe { write_json(out_json, &value) }
}

/// Write `value` into `*out_json` as a fresh heap string and return
/// 0 when `value["ok"]` is true, 1 otherwise. If `out_json` itself
/// is NULL there is nowhere to write, so just return 1.
pub unsafe fn write_json(out_json: *mut *mut c_char, value: &Value) -> i32 {
    let ok = value
        .get("ok")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if out_json.is_null() {
        return 1;
    }
    match CString::new(value.to_string()) {
        Ok(s) => {
            unsafe {
                *out_json = s.into_raw();
            }
            if ok {
                0
            } else {
                1
            }
        }
        Err(_) => {
            unsafe {
                *out_json = std::ptr::null_mut();
            }
            1
        }
    }
}

/// Read a required NUL-terminated UTF-8 C string into an owned
/// `String`. NULL or invalid UTF-8 is an `invalid_argument` error.
pub unsafe fn read_str(ptr: *const c_char, step: &str, name: &str) -> Result<String, Value> {
    if ptr.is_null() {
        return Err(errors::invalid_argument(
            step,
            &format!("{name} must not be NULL"),
        ));
    }
    let s = unsafe { CStr::from_ptr(ptr) };
    match s.to_str() {
        Ok(s) => Ok(s.to_string()),
        Err(_) => Err(errors::invalid_argument(
            step,
            &format!("{name} must be valid UTF-8"),
        )),
    }
}

/// Read an optional NUL-terminated UTF-8 C string. NULL or an empty
/// string means "absent" (`Ok(None)`); invalid UTF-8 is an error.
pub unsafe fn read_opt_str(
    ptr: *const c_char,
    step: &str,
    name: &str,
) -> Result<Option<String>, Value> {
    if ptr.is_null() {
        return Ok(None);
    }
    let s = read_str(ptr, step, name)?;
    if s.is_empty() {
        Ok(None)
    } else {
        Ok(Some(s))
    }
}

//! apple_refresh — Ksign Next Apple ID sign-in core.
//!
//! A Rust static library (XCFramework) + thin C FFI that Swift calls
//! to (1) provision anisette-v3, (2) sign in to an Apple ID via
//! GrandSlam SRP-6a with 2FA, (3) fetch the `com.apple.gs.xcode.auth`
//! app token. Built on isideload 0.5.2 (MIT, pinned commit — see
//! Cargo.toml). Full design: `Documentation/Phase1-FFI-Design.md`.
//!
//! The C interface is `include/AppleRefreshBridge.h` — the 13
//! functions below, one per declaration there. Every function
//! returns 0 on success, non-zero on failure, and writes a JSON
//! envelope to `out_json` (freed with
//! `apple_refresh_string_free`). Panics never cross the boundary
//! (see `ffi::run`); the release profile additionally sets
//! `panic = "abort"`.

mod apptokens;
mod claims;
mod errors;
mod ffi;
mod session;
mod storage;

use std::ffi::CString;
use std::os::raw::{c_char, c_int};

use session::AppleRefreshSession;

/// The library version string, e.g.
/// "apple_refresh 0.1.0 (isideload 0.5.2 @ 326e5622)".
/// Static storage — do NOT free. Testable without network.
static VERSION_CSTR: &[u8] = b"apple_refresh 0.1.0 (isideload 0.5.2 @ 326e5622)\0";

#[no_mangle]
pub extern "C" fn apple_refresh_version() -> *const c_char {
    VERSION_CSTR.as_ptr() as *const c_char
}

unsafe fn session_ref<'a>(
    session: *mut AppleRefreshSession,
    step: &str,
) -> Result<&'a AppleRefreshSession, serde_json::Value> {
    if session.is_null() {
        return Err(errors::error_value(
            step,
            "session_invalid",
            "session handle must not be NULL",
            None,
            None,
            None,
        ));
    }
    Ok(unsafe { &*session })
}

#[no_mangle]
pub extern "C" fn apple_refresh_session_new(
    config_json: *const c_char,
    out_session: *mut *mut AppleRefreshSession,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "session_new", || {
        if out_session.is_null() {
            return Err(errors::invalid_argument(
                "session_new",
                "out_session must not be NULL",
            ));
        }
        let config = unsafe { ffi::read_str(config_json, "session_new", "config_json")? };
        let (session, success) = session::SessionInner::create(&config)?;
        unsafe {
            *out_session = Box::into_raw(Box::new(session));
        }
        Ok(success)
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_session_free(session: *mut AppleRefreshSession) {
    if session.is_null() {
        return;
    }
    unsafe {
        let _ = Box::from_raw(session);
    }
}

#[no_mangle]
pub extern "C" fn apple_refresh_provision_anisette(
    session: *mut AppleRefreshSession,
    force_reset: c_int,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "provision_anisette", || {
        let s = unsafe { session_ref(session, "provision_anisette")? };
        s.inner.provision_anisette(force_reset != 0)
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_reset_anisette(
    session: *mut AppleRefreshSession,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "reset_anisette", || {
        let s = unsafe { session_ref(session, "reset_anisette")? };
        s.inner.reset_anisette()
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_login(
    session: *mut AppleRefreshSession,
    email: *const c_char,
    password: *const c_char,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "login", || {
        let s = unsafe { session_ref(session, "login")? };
        let email_s = unsafe { ffi::read_str(email, "login", "email")? };
        // The password is copied into a Zeroizing<String> inside
        // SessionInner::login and zeroed on return; this local copy
        // is dropped (and its bytes freed) when this closure ends.
        let password_s = unsafe { ffi::read_str(password, "login", "password")? };
        s.inner.login(&email_s, &password_s)
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_poll_prompt(
    session: *mut AppleRefreshSession,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "poll_prompt", || {
        let s = unsafe { session_ref(session, "poll_prompt")? };
        Ok(s.inner.poll_prompt())
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_respond_2fa(
    session: *mut AppleRefreshSession,
    response_json: *const c_char,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "respond_2fa", || {
        let s = unsafe { session_ref(session, "respond_2fa")? };
        let response =
            unsafe { ffi::read_str(response_json, "respond_2fa", "response_json")? };
        s.inner.respond_2fa(&response)
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_cancel(
    session: *mut AppleRefreshSession,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "cancel", || {
        let s = unsafe { session_ref(session, "cancel")? };
        Ok(s.inner.cancel())
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_get_app_token(
    session: *mut AppleRefreshSession,
    app: *const c_char,
    apptokens_claim_json: *const c_char,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "get_app_token", || {
        let s = unsafe { session_ref(session, "get_app_token")? };
        let app_s = unsafe { ffi::read_str(app, "get_app_token", "app")? };
        let claim = unsafe {
            ffi::read_opt_str(apptokens_claim_json, "get_app_token", "apptokens_claim_json")?
        };
        s.inner.get_app_token(&app_s, claim.as_deref())
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_session_info(
    session: *mut AppleRefreshSession,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "session_info", || {
        let s = unsafe { session_ref(session, "session_info")? };
        Ok(s.inner.session_info())
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_sign_in_claims(
    session: *mut AppleRefreshSession,
    out_json: *mut *mut c_char,
) -> c_int {
    ffi::run(out_json, "sign_in_claims", || {
        let s = unsafe { session_ref(session, "sign_in_claims")? };
        Ok(s.inner.sign_in_claims())
    })
}

#[no_mangle]
pub extern "C" fn apple_refresh_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}

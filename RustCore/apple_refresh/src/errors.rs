//! Error mapping: isideload `rootcause::Report` chain -> the stable
//! FFI error JSON of design doc §4 and §7.
//!
//! Walk order (design doc §4): (1) a `SideloadError::AuthWithMessage`
//! or `DeveloperError` in the chain (via `downcast_current_context`,
//! the pattern already used in isideload's `apple_account.rs`
//! `verify_trusted_device_2fa`), (2) a `reqwest::Error` (HTTP status,
//! timeout, TLS), (3) substring matches for anisette codes.
//!
//! The password is never part of any error string, and no token or
//! SPD value is ever included: the message is the first line of the
//! report text only, truncated to 300 characters. (isideload's own
//! `SensitivePlistAttachment` already redacts the SPD unless
//! `DEBUG_SENSITIVE` is set — this crate never sets it.)

use serde_json::{Value, json};

/// Build the `{"ok": false, "error": {…}}` envelope (design doc §7).
pub fn error_value(
    step: &str,
    code: &str,
    message: &str,
    apple_ec: Option<i64>,
    apple_em: Option<String>,
    http_status: Option<u16>,
) -> Value {
    json!({
        "ok": false,
        "error": {
            "code": code,
            "step": step,
            "apple_ec": apple_ec,
            "apple_em": apple_em,
            "http_status": http_status,
            "message": message,
        }
    })
}

pub fn invalid_argument(step: &str, message: &str) -> Value {
    error_value(step, "invalid_argument", message, None, None, None)
}

pub fn internal(step: &str, message: &str) -> Value {
    error_value(step, "internal", message, None, None, None)
}

fn first_line(text: &str) -> String {
    let line = text.lines().next().unwrap_or("").trim();
    if line.is_empty() {
        "Unknown error".to_string()
    } else {
        line.chars().take(300).collect()
    }
}

fn is_tls_error(err: &reqwest::Error) -> bool {
    // reqwest has no is_tls() predicate; TLS failures surface as
    // connect errors whose source chain names rustls / certificates.
    let debug = format!("{err:?}").to_lowercase();
    debug.contains("tls") || debug.contains("certificate") || debug.contains("rustls")
}

pub fn from_report(step: &str, report: &rootcause::Report) -> Value {
    let text = format!("{report}");

    // (1) SideloadError anywhere in the chain.
    for node in report.iter_reports() {
        if let Some(err) = node.downcast_current_context::<isideload::SideloadError>() {
            return match err {
                isideload::SideloadError::AuthWithMessage(code, message) => {
                    // -20209 (account locked) is the only Apple code with
                    // its own stable code so far; every other GrandSlam
                    // ec maps to apple_auth (design doc §4). The wrong-
                    // password ec is still unknown (design doc §9 Q2):
                    // once the spike captures it with the throwaway
                    // account, add a `wrong_password` arm here.
                    let code_str = if *code == -20209 {
                        "account_locked"
                    } else {
                        "apple_auth"
                    };
                    error_value(
                        step,
                        code_str,
                        &first_line(&text),
                        Some(*code),
                        Some(message.clone()),
                        None,
                    )
                }
                isideload::SideloadError::DeveloperError(code, message) => error_value(
                    step,
                    "developer_error",
                    &first_line(&text),
                    Some(*code),
                    Some(message.clone()),
                    None,
                ),
                _ => error_value(step, "internal", &first_line(&text), None, None, None),
            };
        }
    }

    // (2) reqwest::Error anywhere in the chain.
    for node in report.iter_reports() {
        if let Some(err) = node.downcast_current_context::<reqwest::Error>() {
            let status = err.status().map(|s| s.as_u16());
            let code = match status {
                Some(503) => "server_503",
                Some(429) => "too_many_requests",
                _ if err.is_timeout() => "timeout",
                _ if is_tls_error(err) => "tls",
                _ => "network",
            };
            return error_value(step, code, &first_line(&text), None, None, status);
        }
    }

    // (3) Substring matches for anisette codes (design doc §4).
    // -45063 has no isideload handling at all (SideStore #1752/#1761
    // workaround only) — this match is a guess, to be confirmed live
    // or dropped (design doc §9 Q3).
    let lower = text.to_lowercase();
    if lower.contains("-45063") {
        return error_value(
            step,
            "anisette_provision",
            &first_line(&text),
            Some(-45063),
            None,
            None,
        );
    }
    if lower.contains("-45061") {
        return error_value(
            step,
            "anisette_provision",
            &first_line(&text),
            Some(-45061),
            None,
            None,
        );
    }
    if lower.contains("too many requests") || lower.contains("429") {
        return error_value(step, "too_many_requests", &first_line(&text), None, None, None);
    }
    if lower.contains("client_info") || lower.contains("anisette server") {
        return error_value(
            step,
            "anisette_unavailable",
            &first_line(&text),
            None,
            None,
            None,
        );
    }
    if lower.contains("provision") {
        return error_value(
            step,
            "anisette_provision",
            &first_line(&text),
            None,
            None,
            None,
        );
    }

    error_value(step, "internal", &first_line(&text), None, None, None)
}

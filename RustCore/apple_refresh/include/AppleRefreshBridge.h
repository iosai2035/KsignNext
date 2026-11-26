// KsignNext — AppleRefreshBridge.h
//
// C interface between KsignNext's Swift sign-in code and the Rust
// Apple-refresh core (isideload 0.5.2, MIT — see THIRD_PARTY_NOTICES.md).
//
// Conventions (same as Engines/SigningEngine/ZsignBridge.h):
//   * Return value: 0 on success, non-zero on failure.
//   * All string parameters are UTF-8, NUL-terminated C strings.
//   * Every function that takes `char **out_json` ALWAYS writes a JSON
//     string there on success AND on failure (never NULL on return):
//       success: {"ok": true, ...payload...}
//       failure: {"ok": false, "error": {"code", "step", "apple_ec",
//                  "apple_em", "http_status", "message"}}
//     Free it with apple_refresh_string_free(). The JSON never contains
//     a password or a token value.
//   * Blocking functions (marked BLOCKING) run network I/O and must be
//     called from a Swift background thread, never the main thread.
//   * A session handle is an opaque pointer owned by the caller:
//     create with apple_refresh_session_new, destroy with
//     apple_refresh_session_free. NULL handles are rejected with
//     code "invalid_argument". One session = one Apple ID + one
//     anisette server + one claim set. Phase 1 supports one live
//     login at a time; serialise logins on the Swift side.

#ifndef KSIGNNEXT_APPLE_REFRESH_BRIDGE_H
#define KSIGNNEXT_APPLE_REFRESH_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AppleRefreshSession AppleRefreshSession;

/// Library version string, e.g.
/// "apple_refresh 0.1.0 (isideload 0.5.2 @ 326e5622)".
/// Static storage — do NOT free. Testable without network.
const char *apple_refresh_version(void);

/// BLOCKING. Create a session for one Apple ID sign-in.
///
/// config_json (required): {
///   "anisette_server_url": "https://mac-ani.jkcoxson.com",
///   "storage_dir": "/…/Application Support/KsignNext/AppleRefresh",
///   "serial_number": "0",
///   "sign_in_claim": {"preset": "server"|"apparition"|
///                     "sideinstaller"|"custom",
///                     "client_info": "…",   // custom only
///                     "user_agent": "…"},   // custom only
///   "err_429_retries": 10
/// }
/// Missing keys fall back to the defaults shown. This call performs
/// network I/O (GET {server}/v3/client_info + the GSA URL bag) and
/// fails with code "anisette_unavailable" / "network" if either
/// fails. The password is NOT part of the config and is NOT stored.
int32_t apple_refresh_session_new(const char *config_json,
                                  AppleRefreshSession **out_session,
                                  char **out_json);

/// Destroy a session. Safe to call with NULL (no-op). Must NOT be
/// called while a BLOCKING call on the same session is in flight —
/// call apple_refresh_cancel first and wait for the in-flight call
/// to return.
void apple_refresh_session_free(AppleRefreshSession *session);

/// BLOCKING. Provision (or reuse) the anisette identity for this
/// session's server and fetch fresh anisette headers once.
/// force_reset != 0 deletes the stored identity first (same as
/// apple_refresh_reset_anisette, then provisions).
/// Success payload: {"ok": true, "provisioned": true,
///   "server": "https://…", "client_info": "…", "user_agent": "…"}.
/// A -45061 from the server triggers an automatic re-provision
/// inside (up to 3 attempts) before this returns an error.
int32_t apple_refresh_provision_anisette(AppleRefreshSession *session,
                                         int32_t force_reset,
                                         char **out_json);

/// Delete the stored anisette identity (adi_pb + keychain id) for
/// this session's server. Non-blocking (local file delete only).
/// The next provision_anisette / login re-provisions from scratch.
/// This is the "-45063 / Reset adi.pb" escape hatch.
int32_t apple_refresh_reset_anisette(AppleRefreshSession *session,
                                     char **out_json);

/// BLOCKING. Sign in with the Apple ID password. Drives isideload's
/// AppleAccount::login (SRP init + complete, with 2FA via the
/// poll/respond functions below). Returns only after login succeeds,
/// fails, or is aborted.
/// Success payload: {"ok": true, "email": "…", "first_name": "…",
///   "last_name": "…", "adsid": "…"}.
/// While a 2FA code is needed this call stays blocked; Swift polls
/// apple_refresh_poll_prompt and answers with
/// apple_refresh_respond_2fa. The password buffer is zeroed on
/// return; it is never logged or persisted.
int32_t apple_refresh_login(AppleRefreshSession *session,
                            const char *email,
                            const char *password,
                            char **out_json);

/// Non-blocking. Returns {"pending": false} or
/// {"pending": true, "prompt": {"unknown": bool, "sms": bool,
///   "last_error": null|"…",
///   "numbers": [{"id": n, "number_with_dial_code": "…",
///     "last_two_digits": "…", "push_mode": "…"}],
///   "selected_number_id": null|n}}.
/// Poll this on a timer (e.g. every 250 ms) while apple_refresh_login
/// is blocked on another thread. "sms": true means the code goes to
/// the selected_number_id by SMS; false means a trusted device.
int32_t apple_refresh_poll_prompt(AppleRefreshSession *session,
                                  char **out_json);

/// Non-blocking. Answer a pending 2FA prompt.
/// response_json is one of:
///   {"action": "code", "code": "123456"}
///   {"action": "sms", "id": 2}
///   {"action": "devices"}
///   {"action": "resend"}
///   {"action": "abort"}
/// Returns {"ok": true, "accepted": true} when a prompt was pending
/// and the answer was delivered, {"ok": false, "error":
/// {"code": "no_prompt_pending", …}} otherwise. A wrong code does
/// NOT fail login: isideload re-prompts (see poll_prompt's
/// last_error) and Swift shows "wrong code, try again".
int32_t apple_refresh_respond_2fa(AppleRefreshSession *session,
                                  const char *response_json,
                                  char **out_json);

/// Thread-safe. Ask a blocked apple_refresh_login to stop at the
/// next 2FA boundary (delivers "abort" to any pending prompt).
/// A login stuck in a bare network read (no isideload timeout on
/// GSA requests — see the design doc) will return on the OS TCP
/// timeout; Swift must still treat the session as dead after
/// cancel and create a fresh session for the next attempt.
/// Returns {"ok": true, "cancelled": true}.
int32_t apple_refresh_cancel(AppleRefreshSession *session,
                             char **out_json);

/// BLOCKING. Fetch the app token for `app` (normally
/// "com.apple.gs.xcode.auth"; "xcode.auth" is accepted and
/// normalised). Requires a successful login on this session.
/// apptokens_claim_json: NULL or "" to reuse the sign-in claim
/// (isideload's own get_app_token path); otherwise the same
/// {"preset": …, "client_info": …, "user_agent": …} object as in
/// the session config, used ONLY for this request.
/// Success payload: {"ok": true, "app": "com.apple.gs.xcode.auth",
///   "duration": 0, "expiry": 0, "token_length": 0,
///   "has_token": true}.
/// The token VALUE is deliberately not returned (Phase 2's
/// DeveloperSession uses it inside Rust on this same handle).
int32_t apple_refresh_get_app_token(AppleRefreshSession *session,
                                    const char *app,
                                    const char *apptokens_claim_json,
                                    char **out_json);

/// Non-blocking. {"ok": true, "email": "…", "first_name": null|"…",
///   "last_name": null|"…", "adsid": null|"…",
///   "logged_in": false, "server": "…",
///   "sign_in_claim": "…"} — names/adsid are null before login.
int32_t apple_refresh_session_info(AppleRefreshSession *session,
                                   char **out_json);

/// Non-blocking, no network. Returns the claim presets and the
/// anisette server's own client_info (fetched at session_new):
/// {"ok": true, "server_client_info": "…",
///   "server_user_agent": "…", "presets": {"server": {…},
///   "apparition": {…}, "sideinstaller": {…}}}.
/// For the Settings UI and for the spike variant switch.
int32_t apple_refresh_sign_in_claims(AppleRefreshSession *session,
                                     char **out_json);

/// Free a JSON string returned in out_json. Safe to call with NULL.
void apple_refresh_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* KSIGNNEXT_APPLE_REFRESH_BRIDGE_H */

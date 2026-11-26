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
///   "lastError": null|"…",
///   "numbers": [{"id": n, "number_with_dial_code": "…",
///     "last_two_digits": "…", "push_mode": "…"}],
///   "selectedNumberId": null|n}}.
/// NOTE on key casing (verified against isideload 0.5.2
/// `auth/apple_account.rs`): the top-level prompt fields are
/// camelCase (`lastError`, `selectedNumberId`) because
/// `TwoFactorCallbackParams` carries
/// `#[serde(rename_all = "camelCase")]`; the nested `numbers`
/// items keep snake_case (`number_with_dial_code`,
/// `last_two_digits`, `push_mode`, `id`) because `TrustedNumber`
/// has no rename attribute.
/// Poll this on a timer (e.g. every 250 ms) while apple_refresh_login
/// is blocked on another thread. "sms": true means the code goes to
/// the selectedNumberId by SMS; false means a trusted device.
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

/// ---------------------------------------------------------------------------
/// Developer services (Phase 2, see src/dev.rs). All BLOCKING network
/// calls on the same session handle; every one requires a login
/// (`"not_signed_in"` otherwise). Apple server errors arrive as
/// {"ok": false, "error": {"code": "developer_error",
/// "apple_ec": <Apple resultCode>, "apple_em": "…"}}.
/// Apple codes Swift branches on: 7460 = certificate limit reached,
/// 35 = already registered / invalid value.
/// ---------------------------------------------------------------------------

/// Blocking. {"ok": true, "teams": [{"team_id": "…",
///   "name": null|"…", "type": null|"…", "status": null|"…"}]}.
int32_t apple_refresh_list_teams(AppleRefreshSession *session,
                                 char **out_json);

/// Blocking. {"ok": true, "devices": [{"device_id": null|"…",
///   "device_number": "…" (the UDID), "name": null|"…",
///   "status": null|"…"}]}.
int32_t apple_refresh_list_devices(AppleRefreshSession *session,
                                   const char *team_id,
                                   char **out_json);

/// Blocking. request_json:
///   {"team_id": "…", "name": "…", "udid": "…"}
/// Idempotent: registers the device if it is not already on the
/// team. {"ok": true, "registered": true, "device": {…}}.
int32_t apple_refresh_ensure_device(AppleRefreshSession *session,
                                    const char *request_json,
                                    char **out_json);

/// Blocking. {"ok": true, "app_ids": [{"app_id_id": "…",
///   "identifier": "…", "name": "…",
///   "expiration_date": null|"2026-12-03T13:00:00Z"}],
///   "max_quantity": null|n, "available_quantity": null|n}.
int32_t apple_refresh_list_app_ids(AppleRefreshSession *session,
                                   const char *team_id,
                                   char **out_json);

/// Blocking. request_json:
///   {"team_id": "…", "name": "…", "identifier": "…"}
/// (identifier = bundle ID; the name is normalised by isideload.)
/// {"ok": true, "app_id": {…same shape as list_app_ids items…}}.
int32_t apple_refresh_add_app_id(AppleRefreshSession *session,
                                 const char *request_json,
                                 char **out_json);

/// Blocking. {"ok": true, "certificates":
///   [{"certificate_id": null|"…", "name": null|"…",
///     "serial_number": null|"…", "machine_id": null|"…",
///     "machine_name": null|"…", "status": null|"…",
///     "status_code": null|n,
///     "expiration_date": null|"2027-11-26T00:00:00Z"}]}.
int32_t apple_refresh_list_certificates(AppleRefreshSession *session,
                                        const char *team_id,
                                        char **out_json);

/// Blocking (slow: key generation / CSR / submit / re-list).
/// request_json:
///   {"team_id": "…", "machine_name": "…", "email": "…"}
/// Reuses the certificate matching the stored key and machine name
/// when one exists, otherwise creates one. {"ok": true,
///   "reused": bool, "machine_id": "…", "machine_name": "…",
///   "serial_number": "…", "not_after": null|"2027-…Z",
///   "p12_base64": "…", "p12_password": "…"}.
/// The .p12 password is returned once; Swift must store it in the
/// Keychain immediately and never log it. On the certificate limit
/// this fails with apple_ec 7460 and Swift offers revocation.
int32_t apple_refresh_create_certificate(AppleRefreshSession *session,
                                         const char *request_json,
                                         char **out_json);

/// Blocking. request_json:
///   {"team_id": "…", "serial_number": "…"}
/// {"ok": true, "revoked": true}.
int32_t apple_refresh_revoke_certificate(AppleRefreshSession *session,
                                         const char *request_json,
                                         char **out_json);

/// Blocking. request_json:
///   {"team_id": "…", "app_id_id": "…"}
/// {"ok": true, "profile": {
///   "provisioning_profile_id": "…", "name": "…", "status": "…",
///   "type": "…", "distribution_method": "…", "uuid": "…",
///   "date_expire": "2026-12-03T13:00:00Z",
///   "date_expire_unix": 1796302800, "app_id_id": "…",
///   "filename": "…", "is_free_provisioning_profile": null|bool,
///   "encoded_profile_base64": "…" (the raw .mobileprovision)}}.
int32_t apple_refresh_download_profile(AppleRefreshSession *session,
                                       const char *request_json,
                                       char **out_json);

/// Free a JSON string returned in out_json. Safe to call with NULL.
void apple_refresh_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* KSIGNNEXT_APPLE_REFRESH_BRIDGE_H */

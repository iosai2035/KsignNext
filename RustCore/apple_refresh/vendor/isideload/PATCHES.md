# Vendored isideload — patches

This directory vendors **isideload 0.5.2** (`nab138/isideload`,
commit `326e56229d0727cb6e7b34c8cf03e37e2cd3e17d`, MIT) so Ksign
Next can carry a small patch to its login flow. The vendored copy
is otherwise byte-identical to that commit; `Cargo.toml` in
`RustCore/apple_refresh/` points the `isideload` dependency at this
directory with a `[patch]` section.

## Patch 1 — a failed trusted-device 2FA request must not kill the login

File: `isideload/src/auth/apple_account.rs`, `login_impl`,
`LoginState::NeedsDevice2FA` arm.

Stock behaviour: `update_trusted_numbers()` runs first (unbounded),
then `send_trusted_device_2fa()?` — a failure there aborts the
whole login with an error. On a phone that surfaces as an endless
spinner: the password was accepted, Apple already pushed a
verification code to the user's trusted device, but the app never
shows a field to type the code into, and the sign-in silently
retries across claims and servers.

Patched behaviour:

1. `send_trusted_device_2fa()` runs FIRST — it is the call that
   makes Apple push the code — and a failure is logged, not fatal.
   The state machine still moves to `NeedsDevice2FAVerification`,
   so the 2FA callback fires and the app shows the code field.
   A wrong or stale code re-prompts with `last_error`, and Resend
   retries the request, so nothing is lost by asking anyway.
2. `update_trusted_numbers()` runs after the send, bounded by a
   15-second `tokio::time::timeout`. The trusted numbers only feed
   the SMS picker; a slow lookup must never delay the code field.

## Patch 1 extension — the same bound on the other two lookups

Found by a Gemini audit of the sign-in path (2026-11-28) and
verified against this file: Patch 1 bounded the lookup in the
`NeedsDevice2FA` arm, but two other `update_trusted_numbers()`
calls stayed unbounded, and one of them is the exact path Apple
takes when the code was already pushed:

1. `login_inner`, second step, `hsc == 409` ("2FA code already
   sent"): the stock code awaited the numbers lookup with no
   timeout before returning `NeedsDevice2FAVerification`. A slow
   `GET https://gsa.apple.com/auth` there meant the 2FA callback
   never fired and the app spun until Swift's 120 s timeout, then
   silently retried the next claim — the live symptom on the
   user's phone. Now bounded by the same 15-second timeout.
2. `login_impl`, `LoginState::NeedsSMS2FA` arm: same bound, for
   the same reason (the numbers only feed the SMS picker).

The poll contract itself (`poll_prompt` returning
`{"pending": true, "prompt": ...}`) was verified correct and
needed no change, and the `"devices"` callback action was already
handled by the Rust session layer.

## Re-vendoring

To update to a newer isideload commit: replace this directory with
a fresh copy of that commit, re-apply the patch above (it is a
single arm in `login_impl`), and update the pinned revision in
`RustCore/apple_refresh/Cargo.toml` and this file.

# Phase 1 FFI Design — Rust Core + C FFI for Apple ID Sign-In (Ksign Next)

Date: 2026-11-26. Status: design only — no code written, no code changed.
Read first: `Documentation/RealRefresh-Research.md` (§3, §4, §11, 2026-11-26 update),
`Documentation/Phase0-Spike/REPORT-2026-11-26.md`, and the spike harness
`Documentation/Phase0-Spike/spike_gsa.py` (the author's own Python
implementation of the isideload 0.5.2 flow).

Scope of Phase 1: a Rust static library (XCFramework) + thin C FFI that
Swift calls to (1) provision anisette-v3, (2) sign in to an Apple ID via
GrandSlam SRP-6a with 2FA, (3) fetch the `com.apple.gs.xcode.auth` app
token. No developer-services calls yet (Phase 2), no re-signing changes
(Phase 3). The session handle created here is the same handle Phase 2
extends (`DeveloperSession::from_account` runs inside Rust, on the
`AppleAccount` the handle already owns).

## 0. Executive summary

- **Base library: isideload 0.5.2, MIT, pinned to git commit
  `326e56229d0727cb6e7b34c8cf03e37e2cd3e17d`** (verified below). Nothing
  newer exists: no commits on git main since 28 Oct 2026, no newer
  crates.io version. The `-22410` fix does **not** exist upstream.
- **Dependency audit: no iOS build-blocker found on paper.** Every
  isideload dependency is pure Rust except `ring` (C + assembly, with
  an explicit Apple-ABI `ios64` target) and the `Security` /
  `SystemConfiguration` / `CoreFoundation` system frameworks (via
  `getrandom`, `security-framework`, `rustls-platform-verifier`). The
  same stack is already shipped on iOS by AltLoad (isideload 0.4.6 +
  idevice) and Madeira (isideload 0.4.4 + idevice) as a static
  library / XCFramework — that is the strongest evidence the iOS
  build works. It still has to be proven by the first
  `cargo build --target aarch64-apple-ios` on the macOS runner.
- **Two hard findings that shape the FFI:**
  1. `isideload` 0.5.2 **cannot be built without the `install`
     feature** (hence without `idevice`): `src/lib.rs:1` does
     `use idevice::IdeviceError;` unconditionally, and
     `src/util/device.rs` / `src/sideload/sideloader.rs` use idevice
     with no `cfg` gate (only `install.rs` is gated). The FFI crate
     must enable `install` + `tokio-mt` and **must not** enable
     `keyring-storage` (our own file storage instead, AltLoad-style).
  2. `isideload` 0.5.2 **hardcodes the two things the
     Apparition/SideInstaller fixes change**: `Content-Type:
     text/x-xml-plist` and `X-Xcode-Version: 27.0 (27A5218g)`
     (`src/auth/grandslam.rs`, `base_headers`), and it uses **one**
     `client_info` for init/complete/apptokens (from the anisette
     server, or the `set_client_info_override` API). The FFI
     therefore exposes a **sign-in claim override** (first-class
     isideload API) and an **apptokens claim override** (small
     reimplementation in our crate using only isideload's *public*
     fields — `GrandSlam.client`, `GrandSlam.get_url`,
     `AppleAccount.spd` — verified against the spike harness's
     Python). It does **not** expose a Content-Type override: if the
     on-device spike shows `text/xml` is required, that needs a
     one-line fork patch to isideload (MIT — allowed, documented in
     §9 Q1), not an FFI change.
- **FFI shape (chosen):** opaque session handle + blocking calls
  (Swift calls them on a background thread) + **one uniform JSON
  envelope** (`{"ok": true, ...}` / `{"ok": false, "error": {...}}`)
  returned as a heap string the caller frees with
  `apple_refresh_string_free`. Justification in §5. 2FA is
  **poll-based, not callback-based**: the blocking `login` call
  waits on a Rust channel; Swift polls `poll_prompt` and answers
  with `respond_2fa`. This keeps every Swift interaction on
  Swift-owned threads and matches the codebase (the existing
  `ZsignBridge.h` has no C-callbacks into Swift); AltLoad's
  push-callback model (`AltLoadPromptCb` + `respond`) was the
  pattern reference, not the template.
- **Biggest risk: `-22410` is still unanswered and unfixable from
  inside this design.** Phase 0 could not test it from the VM (the
  VM cannot reach `gsa.apple.com` at all). The on-device sign-in
  test with the throwaway account is the go/no-go gate; if both
  client-info variants fail there, Phase 1 stops — the only known
  working implementation (S2Arm v0.6.4) is closed-source.
- **Nothing blocks starting the builders.** First two milestones:
  (a) iOS `cargo build` green for all three targets,
  (b) on-device sign-in test (throwaway account) through the FFI.

## 1. Pinned isideload version, commit, licence

| Item | Value | Verified how |
|---|---|---|
| Crate | `isideload` **0.5.2** | `isideload/Cargo.toml`: `version = "0.5.2"`, `edition = "2024"`, `license = "MIT"` |
| crates.io | published **2026-10-28T14:43:09Z**, `created_at` = `updated_at` = same, 3,561 downloads at check time, `yanked: false`, sha256 `7cab6348bffd8f32c9358b80c8723bc1da45ad97b0c1f30a1533ade22d4d9496`, edition 2024, `license: "MIT"`, default features `["install", "keyring-storage", "tokio-mt"]` | `https://crates.io/api/v1/crates/isideload/0.5.2` |
| Git HEAD (= release commit) | **`326e56229d0727cb6e7b34c8cf03e37e2cd3e17d`**, message *"Stop using seperate client info for url bag"*, 2026-10-28T14:42:44Z, author/committer nab138, parent `20b06c78fe4ce0579965175e01c4d8a21ea78921` | GitHub API for that commit; the commit's own `Cargo.lock` diff bumps `isideload 0.5.1 → 0.5.2`, so HEAD **is** the 0.5.2 release commit (25 s before the crates.io publish) |
| Licence | **MIT, Copyright (c) 2025 nab138** | `LICENSE` file at repo root, read verbatim. (An old docs.rs page for 0.1.9 says MPL-2.0 — superseded; trust the repo + crates.io, both MIT.) |
| Repo | https://github.com/nab138/isideload | — |
| Later commits | **none** — zero commits on `main` since 28 Oct 2026 (checked 2026-11-26) | GitHub commits page |

**Recommendation: depend on isideload by git + exact rev, not
crates.io.** Both resolve to the same code today, but git+rev is
the only form that lets us later point at a fork commit carrying a
one-line patch (Content-Type, §9 Q1) without republishing anything,
and it pins the exact tree including `Cargo.lock`. Commit
`Cargo.lock` in our repo so transitive versions are pinned too.

```toml
isideload = { git = "https://github.com/nab138/isideload",
              rev = "326e56229d0727cb6e7b34c8cf03e37e2cd3e17d",
              default-features = false,
              features = ["install", "tokio-mt"] }
```

Features explained: `install` is **mandatory** (finding F1, §2);
`tokio-mt` is mandatory (multi-thread runtime + `tokio-tungstenite`
for the provisioning WebSocket); `keyring-storage` is deliberately
**off** — our crate supplies its own `SideloadingStorage` backed by
a file (see §6), so the `keyring` crate is never compiled.

### What isideload 0.5.2 does that the research doc asked to confirm

All verified by reading the source at the pinned commit (file:line
is the pinned tree):

- **Anisette-v3 provisioning** — `src/anisette/remote_v3/mod.rs`:
  `RemoteV3AnisetteProvider::new(url, storage, serial_number)`;
  `set_url` / `set_storage` / `set_serial_number` /
  `set_client_info_override(Option<AnisetteClientInfo>)` /
  `set_websocket_proxy`. `DEFAULT_ANISETTE_V3_URL =
  "https://ani.iloader.app"`. `get_client_info()` → `GET
  {url}/v3/client_info` → `AnisetteClientInfo { client_info,
  user_agent }` (or the override, if set). `provision(&mut self,
  gs: &Arc<GrandSlam>, force_reset)` → WebSocket
  `{url}/v3/provisioning_session` (`wss://…`), messages
  `GiveIdentifier` → `GiveStartProvisioningData` (POST URL-bag
  `midStartProvisioning`, returns `spim`) → `GiveEndProvisioningData
  { cpim }` (POST URL-bag `midFinishProvisioning`, returns `ptm`,
  `tk`) → `ProvisioningSuccess { adi_pb }`. `fetch_headers` →
  `POST {url}/v3/get_headers` with `{"identifier": base64(16-byte
  keychain id), "adi_pb": base64(...)}` (+ `sim` / `device_id` /
  `md_lu` on resync); response is a serde internally-tagged enum
  (`#[serde(tag = "result")]`): success `{"result": "Headers",
  "X-Apple-I-MD": …, "X-Apple-I-MD-M": …, "X-Apple-I-MD-RINFO":
  …}`, error `{"result": "GetHeadersError", "message": …}`. A
  `GetHeadersError` whose message contains `-45061` maps to
  `AnisetteDataResponse::IncorrectlyProvisioned` → automatic
  re-provision. Provisioning headers sent to Apple:
  `X-Apple-I-MD-LU: hex(sha256(keychain_id))` and
  `X-Mme-Device-Id: <uuid of keychain_id>`.
  State persisted (plist) under key `"anisette_state"` via the
  injected storage: `AnisetteState { keychain_identifier: [u8; 16],
  adi_pb: Option<Vec<u8>> }` (`src/anisette/remote_v3/state.rs` —
  serialization borrowed from SideStore's `apple-private-apis`,
  per the file's own comment).
  `serial_number` is stored but **never used** by remote-v3 — any
  string works (`"0"` in `default()`, `"2"` in the minimal example).
- **Anisette data use** — `src/anisette/mod.rs`:
  `AnisetteData::get_headers()` → `X-Mme-Device-Id`,
  `X-Apple-I-MD` (= one-time password), `X-Apple-I-MD-M` (=
  machine id). `get_client_provided_data()` → cpd dict:
  `bootstrap: "true"`, `icscrec: "true"`, `loc: "en_US"`,
  `pbe: "false"`, `prkgen: "true"`, `svct: "iCloud"` + the three
  headers above. Headers expire after **60 s**
  (`needs_refresh`: `elapsed > 60`) — the generator refetches
  them per request; `AnisetteDataGenerator::get_data_or_provision`
  retries up to 3 times (load → `-45061` reprovision → fetch).
- **URL bag** — `src/auth/grandslam.rs`: `GrandSlam::new
  (client_info, debug, proxy_url)` builds the client and fetches
  `GET https://gsa.apple.com/grandslam/GsService2/lookup`, caching
  the `urls` dict. Since commit `326e562` the URL bag is fetched
  with the **same** client-info as sign-in (no separate claim).
  URL-bag keys used: `gsService`, `midStartProvisioning`,
  `midFinishProvisioning`, `trustedDeviceSecondaryAuth`,
  `validateCode`.
- **GrandSlam transport** — `GrandSlam::build_reqwest_client`:
  adds Apple's root cert (`APPLE_ROOT`,
  `src/sideload/cert_identity.rs`, `include_bytes!
  ("../assets/apple_root.cer")`), `http1_title_case_headers()`,
  `danger_accept_invalid_certs(debug)` (false in our build).
  `base_headers` sets on **every** request: `Content-Type:
  text/x-xml-plist`, `Accept: text/x-xml-plist`,
  `X-Mme-Client-Info: <client_info>`, `User-Agent:
  <user_agent>`, `X-Xcode-Version: 27.0 (27A5218g)`,
  `X-Apple-App-Info: com.apple.gs.xcode.auth`, `Connection:
  close`. SMS endpoints use `application/json` instead.
  **Fresh connection per request:** isideload builds **one**
  reqwest client per `GrandSlam` and reuses it for
  init→complete→apptokens, but every request carries
  `Connection: close`, so the server closes the connection after
  each response and reqwest cannot reuse it — each GSA request
  gets a fresh TCP/TLS connection. (The Sep 2026 commit "Disable
  pooling on reqwest client" left `.pool_max_idle_per_host(0)`
  commented out; `Connection: close` is the live mechanism.)
  `plist_request` retries HTTP **429** up to `err_429_retries`
  (builder default `Some(10)`), then bails with `"Received 429
  Too Many Requests, no retries left"`. Note: **no per-request
  timeout is set** anywhere in the GSA client (only the
  provisioning WebSocket has a 30 s timeout) — see §9 Q11.
- **SRP login** — `src/auth/apple_account.rs`, `login_inner`
  (private; driven via the public `login(password,
  two_factor_callback)`): `init` request
  `{"A2k": A_pub, "cpd", "o": "init", "ps": ["s2k", "s2k_fo"],
  "u": email}`; response `s` (salt), `B`, `i` (iterations), `c`,
  `sp` (`s2k` → PBKDF2-HMAC-SHA256 over `SHA256(password)`;
  `s2k_fo` → over the hex string of `SHA256(password)`). `hsc ==
  434` in the init response → anisette resync: extract
  `X-Apple-I-MD-DATA` from `Status` (base64 `sim`), call
  `anisette_generator.resync(&sim)`, retry init once.
  `complete` request `{"M1": proof, "c", "cpd", "o": "complete",
  "u": email}`; verifies server proof `M2`; decrypts `spd`
  (AES-256-CBC, key/IV derived by HMAC-SHA256 of the SRP session
  key with `"extra data key:"` / `"extra data iv:"`, PKCS7).
  Status mapping: `au == "trustedDeviceSecondaryAuth"` →
  device 2FA; `au == "secondaryAuth"` → SMS 2FA (starts with
  phone id 1, user can correct); `au == "repair"` → logged in
  (no 2FA configured); `hsc == 409` → 2FA code already sent;
  other `au` → `NeedsExtraStep(string)`.
  2FA, trusted device: `GET <url-bag trustedDeviceSecondaryAuth>`
  then `GET <url-bag validateCode>` with header
  `security-code: <code>` and `X-Apple-Identity-Token:
  base64("<adsid>:<GsIdmsToken>")`. 2FA, SMS: `PUT
  https://gsa.apple.com/auth/verify/phone`
  `{"phoneNumber": {"id": id}, "mode": "sms"}` then `POST
  https://gsa.apple.com/auth/verify/phone/securitycode`
  `{"securityCode": {"code": code}, "phoneNumber": {"id": id},
  "mode": "sms"}`; trusted numbers via `GET
  https://gsa.apple.com/auth`. Wrong 2FA code = **-21669**
  (retry, `last_error` surfaced to the prompt). SMS send
  errors: **-28248** (unknown method), **-22979 / -22981**
  (Apple refused a new SMS; the last code is still valid).
  The `login()` loop retries up to 15 state transitions.
- **GSA token field names (confirmed)** — the SPD (decrypted
  `spd` plist) holds: `fn`, `ln` (display name, via public
  `get_name()`), **`adsid`** (DSID), **`GsIdmsToken`**
  (session/auth token), **`sk`** (32-byte SRP session key),
  **`c`**, and **`t`** → **`com.apple.gs.idms.pet`** →
  **`token`** (the persistent `pet` token; private `get_pet()`).
  There is **no bare `idmsa` field** in the SPD as isideload
  reads it — the research doc's open item is closed as: `pet`
  lives at `spd.t["com.apple.gs.idms.pet"].token`.
- **apptokens** — `AppleAccount::get_app_token(app)`
  (`src/auth/apple_account.rs`, public): `app` is normalised to
  `com.apple.gs.<app>`; checksum = `HMAC-SHA256(sk,
  "apptokens" || dsid || app)`; request `{"app": [app], "c": c,
  "checksum", "cpd", "o": "apptokens", "u": dsid, "t":
  GsIdmsToken}`; response `et` is decrypted **inside
  isideload** (AES-256-GCM: `et` = `"XYZ" || 16-byte IV ||
  ciphertext+tag`, AAD `"XYZ"`, key = `sk`) — **Swift never
  has to decrypt anything**. The decrypted plist holds
  `status-code` (must be 200) and `t[app]` =
  `{token, duration, expiry}` → `AppToken { token, duration:
  u64, expiry: u64 }`. `DeveloperSession::from_account`
  calls `get_app_token("xcode.auth")`.
- **Developer-services auth (Phase 2, confirmed now)** —
  `src/dev/developer_session.rs`: `POST
  https://developerservices2.apple.com/services/QH65B2/{action}{deviceType}.action?clientId=XABBG36SBA`
  (see `src/dev/device_type.rs`, `dev_url`), headers =
  anisette headers + **`X-Apple-GS-Token: <xcode token>`** +
  **`X-Apple-I-Identity-Id: <adsid>`**; body always carries
  `clientId: "XABBG36SBA"`, `protocolVersion: "QH65B2"`,
  `requestId: <uppercase UUID>`, `userLocale: ["en_US"]`.
  Confirmed action names: `listTeams`, `listDevices`,
  `addDevice`, `listAppIds`, `addAppId`,
  `downloadTeamProvisioningProfile` (all in `src/dev/*.rs`),
  `listAllDevelopmentCerts`, `revokeDevelopmentCert`,
  `submitDevelopmentCSR` (`src/dev/certificates.rs`).
  Research-doc open items §12.1 and §12.2 are closed.
- **Errors** — `src/lib.rs`: `SideloadError::AuthWithMessage
  (i64, String)` is the carrier for every GrandSlam `Status.ec
  != 0` (`GrandSlamErrorChecker::check_grandslam_error` in
  `grandslam.rs`); `SideloadError::DeveloperError(i64, String)`
  for developer-services `resultCode != 0`. Our crate extracts
  these from the `rootcause::Report` chain with
  `iter_reports()` + `downcast_current_context::<SideloadError>()`
  — the pattern is already used in `apple_account.rs`
  (`verify_trusted_device_2fa`, for -21669).
- **Public API surface our crate uses** (all `pub`, no patching
  needed): `AppleAccount::builder(email)` →
  `AppleAccountBuilder::{anisette_provider,
  err_429_retries, danger_debug(false), build, login}`;
  `RemoteV3AnisetteProvider::{new, set_url, set_storage,
  set_serial_number, set_client_info_override}` (the
  `AnisetteProvider` trait gives `get_client_info`,
  `get_anisette_data`, `resync`, `provision`);
  `AnisetteDataGenerator::{get_anisette_data,
  get_client_info, resync}`; `AppleAccount` fields `email`,
  `spd`, `anisette_generator`, `grandslam_client` (all `pub`);
  `AppleAccount::{login, get_app_token, get_name}`;
  `GrandSlam::{new, get_url, plist_request}` and fields `client`,
  `client_info` (all `pub`); `AnisetteClientInfo { client_info,
  user_agent }`; `TwoFactorCallbackParams /
  TwoFactorCallbackResponse` (`SubmitCode`, `SendSms(u32)`,
  `SendToDevices`, `ResendCode`, `Abort`); `AppToken { token,
  duration, expiry }`; `isideload::init()` (rootcause hooks).
  **Not public (and therefore not stepwise-callable):**
  `login_inner` / `send_init_request` / `decrypt_cbc` /
  `decrypt_gcm` / `get_pet` — init and complete can only be
  driven through the monolithic `login()` + 2FA callback.
  That constraint is what forces the FFI shape in §5.
- **rustls provider (mandatory init step):** reqwest is built
  with feature `rustls-no-provider`, so **no TLS works until
  the application installs a CryptoProvider**. The minimal
  example does it first thing:
  `rustls::crypto::ring::default_provider().install_default()`.
  Our crate must do the same, once, before any client is built
  (see §6). `debug` must stay `false` (it enables
  `danger_accept_invalid_certs`).

## 2. Dependency audit (iOS targets: aarch64-apple-ios / aarch64-apple-ios-sim / x86_64-apple-ios-sim)

Resolved versions are from the pinned commit's own `Cargo.lock`
(`cargo build --locked` reproduces them). "Evidence" is what was
checked; "verify in first build" means the item is expected safe
but only a real `cargo build --target …-apple-ios` proves it.

| # | Crate (required → locked) | iOS-safe? | Evidence |
|---|---|---|---|
| 1 | `isideload` 0.5.2 (local, pinned commit) | **Yes — with finding F1** | MIT. See §1. Requires `install` feature (F1). |
| 2 | `idevice` 0.1.61 → **0.1.68** (MIT) | **Yes (verify)** | **Mandatory, not optional** (F1). Pure Rust + `ring`; deps: aes, async-stream, async_zip, cbc, chacha20poly1305, chrono, ed25519-dalek, futures, getrandom, hkdf, hmac, idevice-srp, indexmap, libc, plist, rand, rsa, rustls, serde, sha1/sha2, tokio, tokio-rustls, uuid, x25519-dalek. **No C library, no libusb, no OpenSSL** (`openssl` feature off; `aws-lc` default off because isideload sets `default-features = false`). No `target_os = "ios"` cfg anywhere in its source — nothing iOS-specific to break, nothing iOS-excluded either. Strongest evidence: **AltLoad ships idevice in an iOS XCFramework** (HOW-IT-WORKS §Components; idevice git `d32c818`) and Madeira does the same. Unused in Phase 1 (no device calls) — dead code, harmless. |
| 3 | `plist` 1.8 → 1.10.3 | Yes | Pure Rust. |
| 4 | `plist-macro` 0.1.4 → 0.1.6 | Yes | Proc macro — host-only, never in the device binary. |
| 5 | `reqwest` 0.13.2 → 0.13.5, `default-features = false`, features `json, gzip, rustls-no-provider, http2, charset, system-proxy` | Yes | Pure Rust + rustls. `system-proxy` reads the proxy via **SystemConfiguration** on Apple targets → link `SystemConfiguration.framework`. TLS verification goes through `rustls-platform-verifier` (see #32) — open item Q5. |
| 6 | `thiserror` 2.0.17 → 2.0.21 | Yes | Pure Rust. |
| 7 | `async-trait` 0.1.89 → 0.1.92 | Yes | Pure Rust. |
| 8 | `serde` 1.0.228 → 1.0.229 | Yes | Pure Rust. |
| 9 | `rand` 0.8.5 → 0.8.8 | Yes | Via `getrandom` 0.2 → iOS `SecRandomCopyBytes` (see #34). |
| 10 | `uuid` 1.20.0 → 1.29.0, feature `v4` | Yes | Via `getrandom`. |
| 11 | `tracing` 0.1.44 | Yes | Pure Rust. (Our crate keeps `tracing` output off by default; no subscriber is installed on iOS — logs go nowhere unless the app installs one. Never log passwords/tokens; isideload already censors the email and redacts SPD unless `DEBUG_SENSITIVE` is set.) |
| 12 | `tokio-tungstenite` 0.29.0 (via `tokio-mt`), feature `rustls-tls-webpki-roots` | Yes | Pure Rust + rustls; used only for the provisioning WebSocket. |
| 13 | `rootcause` 0.12.0 → 0.12.1 | Yes | Pure Rust error-reporting; `isideload::init()` installs its hooks once. |
| 14 | `futures-util` 0.3.31 → 0.3.34, `futures` 0.3.32 | Yes | Pure Rust. |
| 15 | `serde_json` 1.0.149 → 1.0.154 | Yes | Pure Rust. |
| 16 | `base64` 0.22.1 | Yes | Pure Rust. |
| 17 | `hex` 0.4.3 | Yes | Pure Rust. |
| 18 | `sha2` 0.11.0 → 0.11.1, `sha1` 0.11.0 | Yes | Pure Rust. |
| 19 | `srp` **0.7.0-rc.3** | Yes | Pure Rust SRP-6a. **Pre-release** (`-rc.3`) — pinned by our `Cargo.lock`; note the upstream comment in isideload's `Cargo.toml` ("requires a beta version of the srp crate… duplicate dependencies"). Acceptable for Phase 1; revisit if a stable `srp` ships. |
| 20 | `pbkdf2` 0.13.0, `hmac` 0.13.0 | Yes | Pure Rust. |
| 21 | `cbc` 0.2.0 → 0.2.1 (`alloc`), `aes` 0.9.0 → 0.9.3, `aes-gcm` 0.11.1 | Yes | Pure Rust (SPD decrypt + token decrypt). |
| 22 | `rsa` 0.9.10 | Yes | Pure Rust (used by cert paths, Phase 2). |
| 23 | `tokio` 1.49 → **1.54.1** | **Yes (verify)** | **iOS is a listed supported platform** in tokio's own docs ("Supported platforms: Linux, Windows, Android, macOS, **iOS**, FreeBSD"). Default features (rt, macros, time, sync, io-util, fs, net, process, signal) + `rt-multi-thread` via `tokio-mt`. `mio` 1.2.4 underneath uses kqueue on Apple targets. |
| 24 | `keyring` 3.6.3 | **Not compiled** | Optional; `keyring-storage` stays **off**. (For the record, its `apple-native` feature pulls `security-framework` 2.11.1/3.7.0, which does compile for iOS — but we do not need it.) |
| 25 | `rcgen` 0.14.7 → 0.14.10, features `ring, pem` | Yes | Via `ring`. Only used for certificate creation (Phase 2) but compiled regardless. |
| 26 | `p12-keystore` **0.3.0-rc4** (`isideload-p12-keystore`) | Yes | Pure Rust (`der`, `des`, `pkcs12`, `pkcs5`, `pkcs8`, `rc2`, `x509-parser`). Pre-release; pinned by lock. Phase 2. |
| 27 | `zip` 8.3 → 8.6.0, feature `deflate` | Yes | `flate2` → `miniz_oxide` (pure Rust). No C zlib. |
| 28 | `isideload-vfs` 0.0.1 | Yes | No dependencies at all. |
| 29 | `rustls` 0.23 → 0.23.46, features `ring, tls12, std` | Yes | Via `ring` (see #33). **Must install the ring provider once** (§6) because reqwest uses `rustls-no-provider`. |
| 30 | `reqwest-middleware` 0.5.1 → 0.5.2, `http` 1.4.0 → 1.5.0, `urlencoding` 2.1.3, `web-time` 1 → 1.1.0, `x509-cert` 0.2.5 | Yes | Pure Rust (`x509-cert` is `der`-based). |
| 31 | `apple-codesign-quick` 0.1.0 (Dadoum, **LGPL-2.1**) | **Yes (verify)** | Deps: byteorder, `cms`, `der`, **memmap2**, pem-rfc7468, plist, **rayon**, rsa, sha1, sha2, spki, thiserror, x509-cert. `memmap2` = `mmap` (available on iOS); `rayon` = threads (fine on iOS). Only used for signing (Phase 2/3) but compiled regardless. **Licence note:** LGPL-2.1, statically linked — we do not modify it and do not need its signing code at all (zsign is our signer); if licence review ever objects, the dependency can only be removed by patching isideload, so flag it to the licence check. It is **not** needed in Phase 1. |
| 32 | `rustls-platform-verifier` **0.7.1** (transitive, via reqwest's rustls stack) | **Yes (verify on device — Q5)** | Deps: core-foundation, rustls-native-certs, security-framework **3.7.0**. On Apple targets it verifies via the **Security framework** (`SecTrust`). Needs `-framework Security -framework CoreFoundation` at link time. Risk: isideload's own `Cargo.toml` comment says this crate has a bug that rejects Apple's root cert ("invalid certificate error with apple's root cert… fixed already but I am waiting for a new release"); isideload works around it on Windows with native-tls. On iOS there is no native-tls fallback — the first on-device TLS handshake to `gsa.apple.com` is the test. |
| 33 | `ring` **0.17.14** (transitive, via rustls + rcgen + idevice) | **Yes** | **Native C + assembly — the one native-code dependency in the tree.** Verified iOS-safe from ring's own `build.rs` (docs.rs source): `AsmTarget { oss: APPLE_ABI, arch: AARCH64, perlasm_format: "ios64" }` and a `[target.'cfg(all(aarch64, target_vendor = "apple", any(target_os = "ios", …)))]` dependency on `libc`. Ring's C is built by the `cc` crate with the Xcode clang; the `x86_64-apple-ios-sim` slice uses the `macosx` perlasm format. Requires a C compiler + perl at build time (present on the macOS runner). No `-lc++` needed. |
| 34 | `getrandom` 0.2.17 / 0.3.4 (transitive) | **Yes** | getrandom's supported-target table: **iOS `*-apple-ios` → `SecRandomCopyBytes`** (docs.rs). Needs `-framework Security` at link time. |
| 35 | `encoding_rs` 0.8.42, `h2` 0.4.20, `hyper` 1.12.0, `hyper-rustls` 0.27.10, `hyper-util` 0.1.21, `tokio-rustls` 0.26, `rustls-webpki` 0.103.16, `webpki-roots`, `mio` 1.2.4, `socket2` 0.6.5, `libc` 0.2.191, `memchr`, `itoa`, `ryu`, `once_cell`, `log`, `pin-project-lite`, `bytes`, `slab` (all transitive) | Yes | Pure Rust, or (mio/socket2/libc) OS abstractions with iOS support. `encoding_rs` ships aarch64 SIMD paths that compile for iOS. |

**Not in the tree (deliberately):** `ws_stream_wasm` (wasm feature,
off), `getrandom_02/04` js shims (wasm only), `openssl` (idevice
feature, off), `aws-lc-rs` (idevice default, off via
`default-features = false`), `dbus-secret-service` /
`linux-keyutils` / `windows-sys` (keyring, off).

### Findings

- **F1 — `install` / `idevice` is mandatory, not optional.**
  `src/lib.rs:1` (`use idevice::IdeviceError;`) and the
  `SideloadError::IdeviceError` variant have no `cfg` gate;
  `src/util/device.rs` and `src/sideload/sideloader.rs` use
  idevice unconditionally; only `src/sideload/install.rs` is
  `#[cfg(feature = "install")]`. A consumer that sets
  `default-features = false` without `install` fails to compile
  isideload 0.5.2. Consequence: our crate enables `install`
  (idevice 0.1.68, features `ring, afc, installation_proxy,
  remote_pairing, rsd`, `default-features = false`) and accepts
  the dead code in Phase 1. If idevice ever fails the iOS build,
  the fallback is a fork patch that gates the idevice uses —
  do not attempt that pre-emptively.
- **F2 — Two hardcoded values the Oct/Nov fixes change.**
  `Content-Type: text/x-xml-plist` and `X-Xcode-Version: 27.0
  (27A5218g)` are hardcoded in `GrandSlam::base_headers`
  (`src/auth/grandslam.rs`). The Apparition `text/xml` fix is
  **not** in 0.5.2. The FFI cannot change these without a fork
  patch (§9 Q1).
- **F3 — One claim for the whole sign-in.** `GrandSlam.client_info`
  is fixed at construction (from the anisette server's
  `/v3/client_info`, or `set_client_info_override`). There is no
  per-call claim switch in 0.5.2, so the Mac-claim-for-apptokens
  rule is only satisfied when the sign-in claim is already a Mac
  claim — which is true for the jkcoxson servers (they return a
  Mac claim, §3). The FFI adds an apptokens claim override
  (§5, `get_app_token`) so the two variants can still be tested
  independently.
- **F4 — No timeouts on GSA requests.** Only the provisioning
  WebSocket has a timeout (30 s). A hung GSA connection blocks
  the calling thread until the OS kills it. Swift must impose
  its own timeout and call `cancel` (§9 Q11).
- **F5 — `serial_number` is unused by remote-v3.** Stored,
  never read. Pass `"0"`.

## 3. Client-info / claimed platform — the two variants

isideload uses the anisette server's `/v3/client_info` verbatim
unless overridden. The three concrete claims the FFI must support:

| Preset | `X-Mme-Client-Info` | `User-Agent` | Source |
|---|---|---|---|
| `server` (default) | Whatever the anisette server returns. Live 2026-11-26 from `mac-ani.jkcoxson.com` / `ani.jkcoxson.com` / `ani2.stikstore.app` / `new.ani.sidestore.io`: `<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` | `akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0` | Phase 0 report (live probe) |
| `apparition` (variant a) | `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` | `akd/1.0 CFNetwork/808.1.4` | RealRefresh-Research §3; spike harness `VARIANTS["a"]` |
| `sideinstaller` (variant b) | `<MacBookPro16,1> <Mac OS X;10.15.7;19H2> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` | `akd/1.0 CFNetwork/1121.1.2 Darwin/19.7.0` | SideInstaller v2.1.1; AltStore PR #1875 (live curl 2026-11-19: any `X-Mme-Client-Info` containing `<macOS;…>` gets a 190-byte HTTP 503 at the GSA edge; the same string with `<Mac OS X;…>` reaches GSA); spike harness `VARIANTS["b"]` |

Rules (from the research doc, all still current):
- **Never** put `com.apple.dt.Xcode` in `X-Mme-Client-Info` —
  the edge drops such requests with HTTP 503 before any
  credential is checked. isideload reports `com.apple.akd/1.0`
  (PR #11) — keep it.
- Sign-in (`init`/`complete`) and the URL-bag fetch use the
  **sign-in claim** (server / variant b). `apptokens`
  (`com.apple.gs.xcode.auth`) and all developer-services
  requests must claim a **Mac** (else `-80046`).
- The `server` claim already *is* a Mac claim
  (`Mac OS X;10.12.6`), so the default path needs no switch.
  The override exists so the spike can test variant (a) for
  sign-in and either variant for apptokens independently.
- `custom` preset: caller supplies both strings verbatim; the
  FFI validates they are non-empty and contain no NUL/CR/LF
  (header-injection guard), nothing more.

The FFI takes the sign-in claim at `session_new` (config JSON)
and the apptokens claim per `get_app_token` call (NULL = reuse
the sign-in claim via isideload's own `get_app_token`).

## 4. Error-code mapping

How a failure is produced: isideload returns a
`rootcause::Report`; our crate walks the chain with
`iter_reports()` and (in order) looks for (1) a
`SideloadError::AuthWithMessage(ec, em)` or
`DeveloperError(ec, em)` (via
`downcast_current_context::<SideloadError>()` — the pattern
already used in `apple_account.rs` `verify_trusted_device_2fa`),
(2) a `reqwest::Error` (HTTP status, timeout, TLS), (3)
substring matches for anisette codes. The FFI always returns
the error JSON of §7 — `apple_ec` is the raw Apple code, `code`
is our stable string, `message` is human-readable (never
contains a password, token, or full SPD).

| Apple / transport signal | Where it surfaces in isideload 0.5.2 | FFI `code` | `apple_ec` | Swift action (Phase 1 UI) |
|---|---|---|---|---|
| GrandSlam `Status.ec = -22410`, `em` "This action could not be completed" (at `init`; S2Arm reports the same code after the 2FA code) | `check_grandslam_error` → `AuthWithMessage(-22410, em)`, context *"GrandSlam error during initial login request"* (`apple_account.rs`, the `apple_account.rs:786` / `grandslam.rs:282` stack in iloader #1228) | `apple_auth` | -22410 | Show "Apple is rejecting sign-in right now (−22410)" + offer to try the other client-info variant once. Do **not** retry the password. This is the Phase 0 go/no-go signal. |
| GrandSlam `Status.ec = -22411` (at `apptokens`) | Same path, context *"GrandSlam error during app token request"* | `apple_auth` | -22411 | Same as -22410, at the token step. |
| GrandSlam `Status.ec = -80045` (sign-in claim / anisette mismatch, 12 Oct change) | Same path, init/complete | `apple_auth` | -80045 | Switch anisette server / claim variant; do not retry the same combination. |
| GrandSlam `Status.ec = -80046` (non-Mac claim at `apptokens`, 22 Oct change) | Same path, apptokens | `apple_auth` | -80046 | Retry apptokens with a Mac claim (the FFI's claim override). |
| GrandSlam `Status.ec = -20209` (account locked) | Same path, any step | `account_locked` | -20209 | Remove password from Keychain, pause sign-ins for this Apple ID, tell the user to unlock at iforgot.apple.com. Never retry. |
| Wrong password | **Unknown ec — not identifiable in the isideload source.** There is no password-specific branch; a rejected password arrives as a generic `AuthWithMessage(ec, em)`. | `apple_auth` until the ec is captured live (§9 Q2) | (live value) | Once the ec is known (one deliberate wrong-password attempt with the throwaway account during the spike), map it to `wrong_password`: remove password from Keychain; second rejection in a row → pause sign-ins 15 min (AltLoad rule). |
| 2FA code wrong | `AuthWithMessage(-21669, …)` inside `verify_trusted_device_2fa` / `verify_sms_2fa` — **handled inside isideload**: returns to the `Needs*Verification` state and re-prompts with `last_error` set | — (never leaves the FFI as an error) | -21669 | The prompt JSON carries `last_error`; Swift shows "wrong code, try again". No session teardown. |
| 2FA required (expected path) | `LoginState::NeedsDevice2FA` / `NeedsSMS2FA` — handled inside `login()` via the callback; the FFI `login` call stays blocked until Swift answers | — (not an error) | — | Swift shows the 2FA sheet from the polled prompt. |
| SMS send refused | `-28248` → `NeedsUnknown2FA` (offer the other method); `-22979` / `-22981` → `NeedsSMS2FAVerification` (last code still valid, do not re-send) | — (handled inside) | as shown | Swift offers device/SMS choice, or the code entry directly. |
| HTTP 429 from GSA | `plist_request` retries up to `err_429_retries` (default 10); exhausted → `bail!("Received 429 Too Many Requests, no retries left")` | `too_many_requests` | — (HTTP 429 in `http_status`) | Pause sign-ins for this Apple ID **without** removing the password (AltLoad rule). Do not hammer. |
| HTTP 503 from the GSA edge (e.g. `com.apple.dt.Xcode` in the claim, or a `<macOS;…>` claim since 20 Nov) | `error_for_status()` fails **before** plist parsing → Report with context *"Received error response from grandslam"* + reqwest status 503. Note: the body is 190-byte HTML, never a plist — a plist-parse error with HTML attached means the same thing one layer down. | `server_503` | — | Switch claim variant (the `<macOS;…>` → `<Mac OS X;…>` change); never retry the same claim. |
| Network / TLS / DNS failure reaching Apple | `reqwest::Error` in the chain (connect, timeout, TLS handshake, `RemoteDisconnected`, …) | `network` (or `tls` when the source is a TLS error) | — | Show a connectivity message; safe to retry. |
| Anisette server unreachable / `/v3/client_info` non-200 | `get_client_info` context *"Failed to request /v3/client_info…"* / *"anisette server returned an error…"* | `anisette_unavailable` | — | Rotate to the next server (Swift picks from the server list; Rust tries at most 2 per sign-in — AltLoad rule). |
| Anisette provisioning failure (WebSocket closed, timeout, `Start/EndProvisioningError`, `InvalidIdentifier`) | `provision()` bails with those messages | `anisette_provision` | — | Rotate server; offer "Reset Anisette Data" if it repeats. |
| `-45061` (identity expired / not provisioned) | `GetHeadersError` message contains `-45061` → `IncorrectlyProvisioned` → **auto re-provision**, up to 3 attempts in `get_data_or_provision` | — (handled inside; only surfaces as `anisette_provision` if all 3 attempts fail) | -45061 | Rotate/reset only if it keeps failing. |
| `-45063` (pending ADI session, stuck state) | **Not present in isideload 0.5.2 source at all** (SideStore #1752/#1761 workaround only) | `anisette_provision` (matched by substring `"-45063"` in the message, if it ever appears) | -45063 (if matched) | Offer "Reset Anisette Data" (`reset_anisette` — deletes the stored state, forces fresh provisioning). Unverified — §9 Q3. |
| `hsc == 434` (anisette resync demanded) | `resync_sim()` in `login_inner`: extracts `X-Apple-I-MD-DATA`, calls `resync(&sim)`, retries init once | — (handled inside) | — | Nothing. |
| Cancelled by the user (abort at a 2FA prompt, or `cancel`) | `TwoFactorCallbackResponse::Abort` → `login()` bails *"No 2FA code provided, aborting"* | `cancelled` | — | Dismiss the flow; session stays usable for a fresh login. |
| Any other `Report` (plist missing key, SRP proof mismatch, GCM decrypt failure, …) | Message text preserved verbatim in `error.message` | `internal` | — | Log (no secrets) and report as a bug with the step name. |

Notes:
- `apple_ec` is only populated when a `SideloadError` was found
  in the chain; `http_status` only when a `reqwest::Error` with a
  status was found. Both may be present (rare).
- The password is never part of any error string. isideload's
  own `SensitivePlistAttachment` redacts the SPD unless
  `DEBUG_SENSITIVE` is set — our crate never sets it.
- `-22410` vs `-22411`: same code family, different step
  (`init` vs `apptokens`); the FFI `step` field tells them
  apart.

## 5. FFI design

### 5.1 Decisions

1. **Opaque session handle.** `typedef struct
   AppleRefreshSession AppleRefreshSession;` — a heap-allocated
   Rust `Session` boxed across the boundary. `session_new`
   creates it, `session_free` destroys it. One session = one
   Apple ID + one anisette server + one claim set. Sessions are
   independent; Phase 1 supports one live login at a time
   (Swift serialises logins).
2. **Blocking calls; Swift owns the threads.** Every function
   that touches the network blocks the calling thread until it
   returns. Swift calls them from a background thread
   (`Task.detached` / global queue) — never the main thread.
   `poll_prompt`, `respond_2fa`, `cancel`, `session_info`,
   `sign_in_claims`, `version`, `string_free` are non-blocking
   and thread-safe. Rationale: isideload is `async` (tokio);
   blocking FFI over a runtime is the standard Rust→Swift
   shape (AltLoad does the same: "Every call but
   `altload_debug_stop` blocks; use one thread per session").
3. **Uniform JSON envelope, not out-param structs.** Every
   function returns `int32_t` (0 = success, non-zero =
   failure, matching `ZsignBridge.h`) **and** writes a JSON
   string to `char **out_json` on both success and failure:
   `{"ok": true, …payload}` or `{"ok": false, "error": {…}}`.
   The caller frees it with `apple_refresh_string_free`.
   Justification: one Swift decode path; error detail
   (`apple_ec`, `step`, stable `code`) cannot fit in an int;
   adding a field is a JSON key, not an ABI break (AltLoad's
   `altload_account_session_run` uses the same 0 + `out_json`
   pattern; `ZsignBridge.h`'s bare ints are fine for zsign
   because zsign's failures carry no structured detail — ours
   do). The single exception is `apple_refresh_version`, which
   returns a static string needing no free.
4. **2FA is poll-based, not callback-based.** `login` blocks
   inside isideload's `login()`, whose `TwoFactorCallback` is
   a Rust closure. The closure (a) stores the prompt JSON in
   the session, (b) creates a fresh `tokio::sync::oneshot`
   pair, stores the `Sender` in the session, (c) awaits the
   `Receiver` — fully async, no thread blocked. Swift polls
   `apple_refresh_poll_prompt` (non-blocking), shows the sheet,
   and answers with `apple_refresh_respond_2fa` (which sends
   on the stored `Sender`). This avoids calling into Swift
   from arbitrary Rust runtime threads (AltLoad's
   `AltLoadPromptCb` does that; our codebase has no precedent
   for C→Swift callbacks and no need to add one).
5. **Passwords are never logged or persisted by Rust.** The
   password arrives as `const char *`, is copied into a
   `zeroize::Zeroizing<Vec<u8>>` (zeroed on drop), and is
   never written to disk, never put in any JSON, never logged.
   isideload itself never logs it. Swift must hold the
   password only for the duration of the call (from the
   Keychain / SecureField) and clear its buffer afterwards.
6. **The Xcode token value never crosses to Swift in Phase 1.**
   `get_app_token` returns `duration`, `expiry`,
   `token_length` and `has_token: true` — not the token
   string. Rationale: Phase 2's `DeveloperSession` runs
   inside Rust on the same handle, so Swift never needs the
   bearer token; returning it would only widen the leak
   surface (AltLoad: "Developer tokens aren't saved between
   runs"). If a later phase needs Swift-side token use, add
   an explicit opt-in — do not change this silently.
7. **Stepwise, but honest about the seam.** The FFI exposes
   the steps the public isideload API actually supports:
   `provision_anisette` (public `AnisetteDataGenerator::
   get_anisette_data`, which provisions on demand) →
   `login` (monolithic `AppleAccount::login`; init/complete
   are private and cannot be split without reimplementing SRP
   in our crate — deliberately **not** done) → `get_app_token`
   (public, plus our override-claim path). The task asked for
   stepwise init/complete/complete-2fa; the design records
   why that exact split is impossible on the public API and
   what replaces it (§5.4).
8. **Panics never cross the boundary.** Every `extern "C"`
   function wraps its body in `std::panic::catch_unwind`
   and returns `{"ok": false, "error": {"code": "internal",
   …}}` on panic. The crate sets `panic = "abort"` in the
   release profile as a second line of defence (a panic in a
   spawned tokio task cannot be caught at the FFI boundary).
9. **One global tokio runtime.** A `OnceLock<tokio::runtime::
   Runtime>` (multi-thread, built once) serves all sessions.
   FFI functions use `runtime.block_on(...)`. They must never
   be called from inside a runtime worker thread (they are
   called from Swift threads, so this holds). `isideload::init()`
   and the rustls ring-provider install run once, under
   `std::sync::Once`, inside `session_new`.

### 5.2 The C header (complete — `RustCore/apple_refresh/include/AppleRefreshBridge.h`)

```c
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
```

### 5.3 Claim presets (exact strings — also in the header's docs)

```json
"apparition": {
  "client_info": "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
  "user_agent": "akd/1.0 CFNetwork/808.1.4"
},
"sideinstaller": {
  "client_info": "<MacBookPro16,1> <Mac OS X;10.15.7;19H2> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
  "user_agent": "akd/1.0 CFNetwork/1121.1.2 Darwin/19.7.0"
}
```

`server` = the anisette server's `/v3/client_info` response,
fetched live at `session_new` (2026-11-26 live value from
jkcoxson servers: `<MacBookPro13,3> <Mac OS X;10.12.6;16G29>
<com.apple.AuthKit/1 (com.apple.akd/1.0)>` /
`akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0`).

### 5.4 What the FFI does not expose (and why)

- **Separate `init` / `complete` calls.** `login_inner`,
  `send_init_request`, `decrypt_cbc` are private in isideload.
  Splitting them would mean reimplementing SRP-6a + SPD
  decryption in our crate (~200 lines duplicated from
  isideload, plus the `srp` 0.7.0-rc.3 API). Not worth it:
  the observable seam that matters for the spike is the
  **claim per call** and the **2FA prompt**, both of which
  the design covers. If a future fix needs a different SRP
  parameter (e.g. a new `ps` protocol), it lands in isideload
  or a fork patch — not in our FFI.
- **A raw `get_headers` call.** Anisette headers are an
  isideload-internal, 60-second-lived value. Swift never
  needs them directly; `provision_anisette` proves the
  anisette path works and returns the server claim.
- **The token value, the `pet`, the SPD, the password.**
  All stay inside Rust (see §5.1.5–6).
- **Developer-services calls.** Phase 2, on this handle.

### 5.5 Swift-side call sequence (happy path)

```
version()                                  // no network; smoke test
session_new(config)                        // BLOCKING: client_info + URL bag
provision_anisette(force_reset: false)     // BLOCKING: WS provisioning
login(email, password)                     // BLOCKING, background thread
   ├─ while blocked: poll_prompt() every ~250 ms
   │     └─ prompt pending → show 2FA sheet → respond_2fa(...)
   └─ returns {"ok": true, email, first_name, last_name, adsid}
get_app_token("com.apple.gs.xcode.auth", nil) // BLOCKING
session_info()                             // confirm logged_in
// Phase 1 done: session + Xcode token proven. Keep the handle
// alive for Phase 2; session_free() when the user signs out.
```

Failure branches: any call returning `{"ok": false, …}` —
Swift reads `error.code` / `apple_ec` from §4 and follows the
"Swift action" column. `cancel()` + fresh `session_new` is the
recovery for a stuck login.

## 6. Rust crate layout

```
RustCore/
  apple_refresh/                  # our crate (new; in git)
    Cargo.toml
    Cargo.lock                    # COMMIT — pins isideload rev + all transitive versions
    rust-toolchain.toml           # pins the toolchain (see §8)
    include/
      AppleRefreshBridge.h        # the C header from §5.2 (source of truth;
                                  # also copied into the XCFramework via -headers)
    src/
      lib.rs                      # crate-type staticlib; #[no_mangle] extern "C" fns
      session.rs                  # Session struct: runtime, AppleAccount, 2FA state
      ffi.rs                      # JSON envelope helpers, C-string handling, catch_unwind
      errors.rs                   # Report-chain walker → stable error JSON (§4)
      storage.rs                  # FileStorage: SideloadingStorage over one dir
      claims.rs                   # presets from §5.3 + validation
      apptokens.rs                # override-claim apptokens (public-API path, §1)
  AppleRefresh.xcframework/       # BUILT by CI, NOT committed (see .gitignore)
```

### 6.1 `Cargo.toml` (crate)

```toml
[package]
name = "apple_refresh"
version = "0.1.0"
edition = "2021"
description = "Ksign Next Apple ID sign-in core (isideload FFI)"
license = "MIT"

[lib]
name = "apple_refresh"
crate-type = ["staticlib"]

[dependencies]
isideload = { git = "https://github.com/nab138/isideload",
              rev = "326e56229d0727cb6e7b34c8cf03e37e2cd3e17d",
              default-features = false,
              features = ["install", "tokio-mt"] }
tokio = { version = "1", features = ["rt-multi-thread"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
hmac = "0.13"
sha2 = "0.11"
aes-gcm = "0.11"
plist = "1"
reqwest = { version = "0.13", default-features = false,
            features = ["rustls-no-provider"] }
reqwest-middleware = "0.5"
rustls = { version = "0.23", default-features = false,
           features = ["ring", "tls12", "std"] }
zeroize = "1"

[profile.release]
panic = "abort"
```

Notes:
- `edition = "2021"` for our crate (no need for 2024; the
  toolchain must still be ≥ 1.85 because isideload is edition
  2024 — record the exact toolchain in `rust-toolchain.toml`,
  §8).
- Direct deps on `hmac`/`sha2`/`aes-gcm`/`plist`/`reqwest(-middleware)`
  exist only for the override-claim `apptokens` path (§1) and
  for reading the SPD; their versions are unified with
  isideload's by Cargo and pinned by our `Cargo.lock`.
- `panic = "abort"`: a panic must never unwind across the FFI
  boundary. All `extern "C"` bodies additionally use
  `catch_unwind` (§5.1.8).
- No `keyring`, no `idevice` direct dependency (both come
  transitively through isideload), no `openssl`, no `aws-lc`.

### 6.2 Runtime / session internals (sketch for the builders)

```rust
// session.rs (sketch — names are guidance, not API)
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static INIT_ONCE: Once = Once::new();

pub struct Session {
    account: Mutex<Option<AppleAccount>>, // None until session_new builds it
    prompt: Mutex<Option<PromptState>>,   // last 2FA prompt JSON (for polling)
    responder: Mutex<Option<oneshot::Sender<TwoFactorCallbackResponse>>>,
    cancelled: AtomicBool,
    config: SessionConfig,                // server url, storage dir, claims
}

struct PromptState { json: String /* TwoFactorCallbackParams as JSON */ }
```

- `session_new`: `INIT_ONCE` runs `isideload::init()` +
  `rustls::crypto::ring::default_provider().install_default()`
  (both must succeed or the call fails with `internal`); builds
  the global multi-thread runtime if absent; builds
  `RemoteV3AnisetteProvider::new(url, Box::new(FileStorage::
  new(storage_dir.join(server_slug))), "0")`, applies
  `set_client_info_override` when the preset is not `server`,
  and wraps it in an `AnisetteDataGenerator`. The generator is
  email-independent, so it is built here; the `AppleAccount`
  itself is built in `login` (so a wrong email doesn't poison
  the session) via `AppleAccount::new(email, generator, false,
  None, Some(10))`. `session_new` also fetches
  `/v3/client_info` and the GSA URL bag (the latter happens
  inside `AppleAccount::new` → `GrandSlam::new` at login time;
  to fail fast, `session_new` performs an explicit
  `get_client_info()` + URL-bag fetch via a throwaway
  `GrandSlam::new` and reports `anisette_unavailable` /
  `network` immediately).
- `login`: `runtime.block_on(account.login(password, callback))`
  where `callback` is a closure capturing `Arc<SessionInner>`:
  on each invocation it serialises the params to the prompt
  JSON, stores a fresh oneshot `Sender`, stores the prompt,
  and awaits the `Receiver`. `Abort` maps from
  `{"action":"abort"}`; `SendSms(id)` / `SendToDevices` /
  `ResendCode` / `SubmitCode(code)` map from the other
  actions. If `cancelled` is set while waiting, the closure
  returns `Abort`.
- `provision_anisette`: `runtime.block_on(account_or_generator
  .get_anisette_data(grandslam_client.clone()))` — provisions
  on demand; `force_reset` first deletes the stored state and
  calls `provision(gs, true)` explicitly.
- `get_app_token` with a claim override: build the request
  exactly as `AppleAccount::get_app_token` does (§1) but with
  headers built from the override `AnisetteClientInfo`,
  posting through `account.grandslam_client.client` with
  `GrandSlam::get_url("gsService")`; decrypt `et` with
  AES-256-GCM (`"XYZ"` prefix, 16-byte IV, AAD `"XYZ"`, key
  `spd.sk`); parse `status-code` / `t[app]` / `token` /
  `duration` / `expiry`. Return metadata only (§5.1.6).
  With NULL claim, call `account.get_app_token(app)` directly.
- `storage.rs` (`FileStorage`): implements isideload's
  `SideloadingStorage` (`store`/`retrieve`/`delete`, base64
  for `store_data` — the trait provides the `_data` defaults):
  one file per key under
  `<storage_dir>/<server-slug>/`, e.g. `anisette_state`
  (plist bytes). One folder per anisette server (AltLoad
  pattern). The stored state is a device identity blob, not a
  secret — but it must still live in Application Support, not
  in a shared container, and never be logged.
- `errors.rs`: walk `report.iter_reports()`; first
  `downcast_current_context::<SideloadError>()` wins
  (`AuthWithMessage` → `apple_ec`/`apple_em`, `DeveloperError`
  → same); else look for `reqwest::Error` (`.status()`,
  `.is_connect()`/`.is_timeout()`); else substring-scan the
  display string for `-45061` / `-45063` / `429`. Map to the
  table in §4. The walker must never include the SPD or a
  token in the message (isideload's attachments already
  redact; our walker takes only the top context line + the
  matched code).

## 7. JSON result shapes (consolidated)

Envelope (every `out_json`): success `{"ok": true, …}` or
failure `{"ok": false, "error": {…}}`. Field order is not
significant. All strings are UTF-8; `null` where noted.

```jsonc
// error object (always present when ok == false)
{"code": "apple_auth",            // stable string, §4
 "step": "login",                 // which FFI call produced it
 "apple_ec": -22410,              // integer or null
 "apple_em": "This action could not be completed", // string or null
 "http_status": null,             // integer or null
 "message": "GrandSlam error during initial login request: Auth error -22410: …"}

// session_new success
{"ok": true, "server": "https://mac-ani.jkcoxson.com",
 "client_info": "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
 "user_agent": "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0"}

// provision_anisette success
{"ok": true, "provisioned": true, "server": "https://…",
 "client_info": "…", "user_agent": "…"}

// login success
{"ok": true, "email": "user@example.com", "first_name": "…",
 "last_name": "…", "adsid": "…"}

// poll_prompt — no prompt
{"pending": false}
// poll_prompt — prompt pending
{"pending": true, "prompt": {
  "unknown": false, "sms": false, "last_error": null,
  "numbers": [{"id": 1, "number_with_dial_code": "+1 ••• ••• 12",
               "last_two_digits": "12", "push_mode": "…"}],
  "selected_number_id": null}}

// respond_2fa success
{"ok": true, "accepted": true}
// respond_2fa with no prompt pending
{"ok": false, "error": {"code": "no_prompt_pending", "step": "respond_2fa",
  "apple_ec": null, "apple_em": null, "http_status": null,
  "message": "No 2FA prompt is pending on this session"}}

// get_app_token success (NO token value — §5.1.6)
{"ok": true, "app": "com.apple.gs.xcode.auth",
 "duration": 0, "expiry": 0, "token_length": 0, "has_token": true}

// session_info
{"ok": true, "email": "…", "first_name": null, "last_name": null,
 "adsid": null, "logged_in": false, "server": "https://…",
 "sign_in_claim": "<…>"}

// sign_in_claims
{"ok": true, "server_client_info": "…", "server_user_agent": "…",
 "presets": {"apparition": {"client_info": "…", "user_agent": "…"},
             "sideinstaller": {"client_info": "…", "user_agent": "…"}}}

// cancel / reset_anisette
{"ok": true, "cancelled": true}
{"ok": true, "reset": true}
```

Stable `code` values: `ok` (unused — success is `ok: true`),
`invalid_argument`, `session_invalid`, `network`, `tls`,
`timeout`, `anisette_unavailable`, `anisette_provision`,
`apple_auth`, `wrong_password` (once the ec is known, §9 Q2),
`two_factor_aborted`, `too_many_requests`, `account_locked`,
`server_503`, `no_prompt_pending`, `cancelled`, `internal`.

## 8. CI build commands + Xcode integration

### 8.1 Toolchain

- Runner: the existing `macos-15-intel` job in
  `.github/workflows/build-ipa.yml` (Xcode 26.2 via
  `maxim-lobanov/setup-xcode@v1`). The Rust step runs on the
  **same runner** — the Linux VM cannot build iOS targets.
- Toolchain: `rustup` is preinstalled on GitHub macOS
  runners. Pin it in `RustCore/apple_refresh/rust-toolchain.toml`:
  ```toml
  [toolchain]
  channel = "stable"
  targets = ["aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios-sim"]
  ```
  Builders: on the first green run, record `rustc --version`
  and pin the exact version (e.g. `channel = "1.9x.y"`) in
  that file. Floor: Rust ≥ 1.85 (isideload is edition 2024).
- The three targets are all needed: `aarch64-apple-ios`
  (device / archive), `aarch64-apple-ios-sim` (Apple Silicon
  simulator), `x86_64-apple-ios-sim` (the Intel runner's
  simulator tests — the workflow tests on `iPhone 17`
  simulator on `macos-15-intel`).

### 8.2 Build commands (new workflow step, before "Regenerate Xcode project")

```yaml
      - name: Build Rust Apple-refresh core (XCFramework)
        run: |
          set -o pipefail
          rustup toolchain install stable
          rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios-sim
          rustc --version; cargo --version
          cd RustCore/apple_refresh
          cargo build --release --locked --target aarch64-apple-ios
          cargo build --release --locked --target aarch64-apple-ios-sim
          cargo build --release --locked --target x86_64-apple-ios-sim
          cd ../..
          xcodebuild -create-xcframework \
            -library RustCore/apple_refresh/target/aarch64-apple-ios/release/libapple_refresh.a \
            -headers RustCore/apple_refresh/include \
            -library RustCore/apple_refresh/target/aarch64-apple-ios-sim/release/libapple_refresh.a \
            -headers RustCore/apple_refresh/include \
            -library RustCore/apple_refresh/target/x86_64-apple-ios-sim/release/libapple_refresh.a \
            -headers RustCore/apple_refresh/include \
            -output RustCore/AppleRefresh.xcframework
          ls -R RustCore/AppleRefresh.xcframework
```

Notes:
- `--locked` fails the build if `Cargo.lock` is out of date —
  intentional: the lock is the pin.
- `xcodebuild -create-xcframework` accepts two `-library`
  entries for the simulator platform; it merges them into one
  simulator slice (arm64 + x86_64 fat binary).
- The XCFramework lands at
  `RustCore/AppleRefresh.xcframework`. It is **built, not
  committed**: add `RustCore/AppleRefresh.xcframework/` and
  `RustCore/apple_refresh/target/` to `.gitignore`.
- The step must run **before** "Regenerate Xcode project",
  because the generator verifies the file list on disk.
- If `ring`'s build script cannot find the iOS SDK (it needs
  the Xcode clang + SDK), the fallback is to export
  `SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)` for the
  device build and `SDKROOT=$(xcrun --sdk iphonesimulator
  --show-sdk-path)` for the simulator builds. Do not add this
  pre-emptively — only if the plain build fails.
- First-run cost: a clean `cargo build` of this tree on the
  runner is several minutes (ring compiles C/assembly, `srp`
  + `idevice` + `reqwest` are large). Cache
  `~/.cargo/registry` + `RustCore/apple_refresh/target` with
  `actions/cache` keyed on `Cargo.lock` (standard
  `Swatinem/rust-cache` action is the usual choice).

### 8.3 Xcode project integration (`Scripts/generate_project.py`)

1. Add `RustCore/AppleRefresh.xcframework` as a linked
   framework of the app target (same mechanism the generator
   uses for other files — the builder must wire it into the
   generator's file list, not by hand-editing the pbxproj,
   because the workflow regenerates the project).
2. `HEADER_SEARCH_PATHS`: add
   `"$(SRCROOT)/RustCore/apple_refresh/include"` (the repo
   copy of the header is the source of truth; the XCFramework
   copy is for portability).
3. `OTHER_LDFLAGS`: add `"$(inherited) -framework Security
   -framework SystemConfiguration -framework CoreFoundation"`.
   Who needs what: `Security` — `getrandom`
   (`SecRandomCopyBytes`) + `security-framework` (rustls
   platform verifier + TLS); `SystemConfiguration` —
   reqwest `system-proxy`; `CoreFoundation` —
   `security-framework` / `core-foundation` bindings. No
   `-lc++` is needed for the Rust static library itself
   (pure Rust + C from ring); the app already links libc++
   for zsign.
4. Bridging header: `SWIFT_OBJC_BRIDGING_HEADER` is currently
   the single file `Engines/SigningEngine/ZsignBridge.h`
   (generator line 412). Do not edit that file's purpose:
   create a new umbrella header, e.g.
   `KsignNext-Bridging-Header.h` at the repo root (or under
   `SupportingFiles/`), containing:
   ```objc
   #import "ZsignBridge.h"
   #import "AppleRefreshBridge.h"
   ```
   and point `SWIFT_OBJC_BRIDGING_HEADER` at it (with the
   `HEADER_SEARCH_PATHS` from (2) so the second import
   resolves).
5. Swift wrapper: a new `AppleRefreshAdapter.swift` next to
   `ZsignAdapter.swift`, mirroring its style (thin `extern`
   declarations are automatic via the bridging header; the
   adapter owns the background-thread discipline, the
   poll loop, the 2FA sheet wiring, and the JSON decoding).
   It must call the BLOCKING functions only from a background
   thread and must never log the password or the token.
6. `THIRD_PARTY_NOTICES.md`: add an isideload entry (MIT,
   Copyright (c) 2025 nab138, repo URL, pinned commit) in the
   existing table style, plus the transitive licences that
   ship in the binary (ring: ISC-style "ring" licence;
   `apple-codesign-quick`: LGPL-2.1 — see §2 #31).
7. The existing `xcodebuild test` step (simulator) will link
   the simulator slices — that is the first CI proof the
   XCFramework links. The device slice is proven by the
   archive step.

## 9. Open questions for the builders

- **Q1 — Content-Type `text/xml` vs `text/x-xml-plist`.**
  isideload 0.5.2 hardcodes `text/x-xml-plist`
  (`grandslam.rs`). The Apparition finding (30 Oct) says
  Apple blocks `text/x-xml-plist` on `gsd.apple.com` (403)
  and `application/x-xml-plist` on `gsa.apple.com` (403),
  and `text/xml` works on both — but iloader demonstrably
  works with `text/x-xml-plist`, so the rule is either stale
  or path-specific. The spike harness already supports
  `--content-type text/xml`. **Decide on-device:** if the
  FFI sign-in fails at provisioning/URL-bag with a 403 while
  the Python harness with `text/xml` succeeds, apply a
  one-line fork patch to `GrandSlam::base_headers` (change
  both `Content-Type` and `Accept` to `text/xml`), point
  our `Cargo.toml` at the fork commit, and record it in
  `THIRD_PARTY_NOTICES.md`. No FFI change needed.
- **Q2 — Wrong-password Apple code.** Not identifiable in
  the isideload source. During the spike, submit one
  deliberately wrong password with the throwaway account,
  record the exact `Status.ec`/`em`, and add the
  `wrong_password` mapping to §4 (plus the AltLoad rule:
  remove from Keychain; second consecutive rejection →
  15-minute pause).
- **Q3 — `-22410` status, and `-45063`.** Phase 0 could not
  answer either from the VM. The on-device sign-in test
  (throwaway account, both claim variants, from the phone's
  network) is the decider. If both variants fail with
  `-22410`, Phase 1 stops — the only known fix (S2Arm
  v0.6.4) is closed-source and its mechanism unpublished.
  `-45063` has no isideload handling at all; the
  substring-match in §4 is a guess — confirm live or drop it.
- **Q4 — Does `apptokens` need a different claim than
  sign-in?** The FFI supports the override either way.
  Test matrix on-device: sign-in (a) + apptokens (a);
  sign-in (b) + apptokens (b); sign-in (b) + apptokens (a);
  sign-in (server) + apptokens (server). Record which
  combinations reach `et`.
- **Q5 — rustls-platform-verifier + Apple's root cert on
  iOS.** isideload adds `APPLE_ROOT` via
  `add_root_certificate`, but its own `Cargo.toml` comment
  says `rustls-platform-verifier` had a bug rejecting Apple's
  root cert (worked around on Windows with native-tls; no
  such fallback on iOS). If the first on-device TLS
  handshake to `gsa.apple.com` fails with a certificate
  error, the fallback is a custom `rustls` verifier that
  trusts the webpki roots + `APPLE_ROOT` — which changes the
  TLS security posture and needs an explicit decision, not a
  silent patch.
- **Q6 — Exact Rust toolchain version.** Record `rustc
  --version` from the first green CI run and pin it in
  `rust-toolchain.toml` (§8.1). Floor is 1.85.
- **Q7 — Should the Xcode token value ever cross to Swift?**
  Design says no (§5.1.6). Confirm with the Phase 2 plan:
  `DeveloperSession` stays in Rust on the same handle.
- **Q8 — UDID (Phase 2, noted for context).** The user asked
  2026-11-26 (12:31/12:32) for the app to extract the UDID
  directly, on-device, working over cellular as well as
  Wi-Fi (LocalDevVPN + RPPairing), with manual paste as
  fallback. Phase 1 is unaffected, but Phase 2 must verify
  whether free provisioning can carry the Network Extension
  entitlement and on which iOS versions RPPairing host mode
  works.
- **Q9 — Anisette storage location.** The design uses
  `<Application Support>/KsignNext/AppleRefresh/<server-slug>/`
  (AltLoad pattern). Confirm against the app's existing
  storage conventions before building.
- **Q10 — Server rotation policy.** Swift owns the server
  list (built-in list + `https://servers.sidestore.io/servers.json`
  + custom URL, AltLoad model); Rust tries at most 2 servers
  per sign-in and never retries wrong passwords / 2FA
  failures. Confirm the built-in list and whether the
  default stays `mac-ani.jkcoxson.com` (Windows-ADI servers
  first per AltLoad, since Apple refuses most others since
  12 Oct 2026 — but our default is a Mac-ADI server because
  the sign-in claim must be a Mac claim for apptokens; test
  both).
- **Q11 — No GSA request timeout.** isideload sets none.
  Swift must impose its own timeout around `login` /
  `get_app_token` and call `cancel`; a login stuck in a bare
  socket read will only return on the OS TCP timeout. A
  future fork patch could add `.timeout(...)` to
  `GrandSlam::build_reqwest_client` — do not do it in
  Phase 1.
- **Q12 — `srp` 0.7.0-rc.3 and `p12-keystore` 0.3.0-rc4 are
  pre-release.** Pinned by `Cargo.lock`; acceptable. Revisit
  if stable versions ship before Phase 2.

## Sources

- isideload 0.5.2 source at the pinned commit — `src/auth/
  apple_account.rs`, `src/auth/grandslam.rs`,
  `src/auth/builder.rs`, `src/anisette/mod.rs`,
  `src/anisette/remote_v3/mod.rs`,
  `src/anisette/remote_v3/state.rs`,
  `src/anisette/remote_v3/websocket.rs`, `src/dev/
  developer_session.rs`, `src/dev/device_type.rs`,
  `src/dev/certificates.rs`, `src/dev/app_ids.rs`,
  `src/dev/devices.rs`, `src/dev/teams.rs`, `src/lib.rs`,
  `src/util/storage.rs`, `src/util/callbacks.rs`,
  `src/util/plist.rs`, `src/sideload/cert_identity.rs`,
  `isideload/Cargo.toml`, `Cargo.lock` — read from the
  `nab138/isideload` repo at commit `326e5622…` (MIT).
- crates.io API, `isideload` 0.5.2 metadata + `idevice`
  0.1.68 + `ring` 0.17.14 + `getrandom` supported-target
  table (docs.rs) + tokio supported platforms (docs.rs).
- AltLoad `docs/HOW-IT-WORKS.md` and `core/include/altload.h`
  (mirazbakis/AltLoad, HEAD, 2026-11-26) — FFI pattern
  reference only (session/run/respond/cancel/free,
  prompt callback kinds, server rotation, pause rules).
  No AltLoad code copied.
- Ksign Next repo: `Engines/SigningEngine/ZsignBridge.h`,
  `Engines/SigningEngine/zsign/zsign_bridge.cpp`,
  `.github/workflows/build-ipa.yml`,
  `Scripts/generate_project.py`, `THIRD_PARTY_NOTICES.md`.
- Phase 0: `Documentation/Phase0-Spike/REPORT-2026-11-26.md`
  and `spike_gsa.py` (live anisette server responses,
  claim variants, safety rules).
- RealRefresh-Research.md §3/§4/§11 and its 2026-11-26
  update (AltStore PR #1875 503 finding, SideInstaller
  v2.1.1, S2Arm v0.6.4).

## Licence hygiene (restated)

isideload is MIT — vendoring as a library (git pin) is fine
with attribution. Nothing AGPL was read for copying: AltStore /
AltSign / SideStore / AnisetteKit are pattern references only;
Dadoum's anisette-v3-server is unlicensed (protocol only, as
documented in AltStore PR #1834 / GSAPortOSS / isideload);
Apple's `.so` binaries are never bundled. `apple-codesign-quick`
(LGPL-2.1) ships inside isideload's tree — flagged in §2 #31
for the licence check; it is not used by Phase 1.

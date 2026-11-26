# Real Refresh — Research Plan (2026-11-25)

Goal: fetch a FRESH provisioning profile from Apple's servers with the user's
own free Apple ID, so a re-signed app gets a new 7-day window. On-device,
no companion computer, no server of our own. Research only — no code yet.

## 1. Executive verdict

**Feasible — and already proven on-device by others.** The exact flow has
been shipped inside sandboxed iOS apps: AltLoad (isideload 0.4.6 + idevice,
Rust static library via C FFI) and Madeira (isideload 0.4.4 + idevice, static
library, `AppleSignIn.swift` + `SigningRefresh.swift`), and Apparition (an
on-device sideloader that refreshes apps on its own). The proven
architecture is: **a small Rust core built on the MIT-licensed `isideload`
library, compiled to a static library / XCFramework, driven from Swift
through a C FFI** — plus our own Swift UI, Keychain storage and refresh
scheduling. A pure-Swift rewrite of the whole protocol stack is possible
in principle but is the hard road (SRP-6a, anisette-v3 client, QH client,
CSR/cert handling) for no benefit.

**Two hard blockers to decide up front:**

1. **Sign-in is broken right now in the reference implementation.**
   Apple's 21 Nov 2026 change makes GrandSlam return `-22410` at the
   login step; `isideload` 0.5.2 still hits it as of 22–23 Nov 2026
   (iloader issues #1228, #1247, #1249, #1230). S2Arm fixed it in v0.6.4
   but the fix is closed-source and the mechanism is unpublished. Any
   build must start with a spike: reproduce sign-in with a throwaway
   account and confirm the current status before building the rest.
2. **Anisette is the only part that needs an outside server** (unless we
   accept AnisetteKit's AGPL-3.0). The plan below uses public anisette-v3
   servers (user-selectable, with rotation and a self-host option).

**Maintenance warning:** Apple changed something in this flow roughly
once a month in late 2026 (31 Aug connection limit, Sep Xcode-client
block, 12 Oct Android rejection, 22 Oct -80046, 29 Oct Content-Type
firewall, 21 Nov -22410). This feature will need ongoing maintenance;
it is not build-once-and-forget.

## 2. The end-to-end flow (what a real refresh does)

1. **Anisette.** Get machine-identity headers (`X-Apple-I-MD`,
   `X-Apple-I-MD-M`, `X-Apple-I-MD-RINFO`) from an anisette-v3 server
   (see §4). The server provisions a dedicated identity on first use;
   the identity is stored on-device and reused.
2. **URL bag.** `GET https://gsa.apple.com/grandslam/GsService2/lookup`
   — fetch it with the *sign-in's own* client claim, not a Mac claim.
3. **GrandSlam SRP-6a login** to `POST
   https://gsa.apple.com/grandslam/GsService2` (plist body, three
   operations, each on its own fresh connection):
   - `o=init` — SRP init (username, anisette headers).
   - `o=complete` — SRP proof with the password (never sent in
     plaintext). If 2FA is required the response challenges with
     `hsc=409`/`au=secondaryAuth`; the user enters the 6-digit code
     from a trusted device (or SMS) and a second `complete` carries it.
   - `o=apptokens` — request app tokens, including
     `com.apple.gs.xcode.auth` — the **Xcode token** used for all
     developer-services calls. This request must claim a **Mac** (see §3).
4. **Developer session.** With the Xcode token, talk to
   `https://developerservices2.apple.com` (QH protocol, see §5):
   list teams → pick team (first team for free accounts) → ensure the
   device is registered (needs the UDID — see §6) → reuse or create
   the development certificate (CSR → Apple issues cert → download →
   package as .p12 with the private key) → register the App ID for the
   app's bundle ID (plus extensions) → download a fresh provisioning
   profile for that App ID (`downloadTeamProvisioningProfile.action`).
5. **Re-sign.** Replace `embedded.mobileprovision` in the .app bundle
   with the fresh profile and re-sign with zsign using the .p12 (our
   existing pipeline already does this; see §7).
6. **Reinstall.** Loopback itms-services install (already built).
   iOS treats it as an update (same bundle ID + same team), so the
   app's data and login survive.

## 3. GrandSlam sign-in — exact rules (Oct–Nov 2026)

Endpoint: `POST https://gsa.apple.com/grandslam/GsService2`, plist body.
URL bag: `.../GsService2/lookup`. Related host: `gsd.apple.com`
(machine provisioning, `startMachineProvisioning`).

Headers that matter:
- `X-Apple-I-MD`, `X-Apple-I-MD-M`, `X-Apple-I-MD-RINFO` — anisette.
- `X-MMe-Client-Info` — `<model> <OS;version;build>
  <com.apple.AuthKit/1 (client/version)>`. **Never** put
  `com.apple.dt.Xcode` in it: Apple's edge drops such requests with
  HTTP 503 HTML before any credential is checked (AltStore PR #1790;
  isideload PR #11). Report the client as `com.apple.akd/1.0`.
- `User-Agent: akd/1.0 CFNetwork/808.1.4`.
- `Content-Type: text/xml` on **every** GrandSlam request. Apple's edge
  blocks `text/x-xml-plist` on `gsd.apple.com` (403) and
  `application/x-xml-plist` on `gsa.apple.com` (403); `text/xml` works
  on both (Apparition blog, 30 Oct update; Apparition 0.4.3).
- **One fresh connection per GSA request** (ephemeral URLSession per
  request). Since ~31 Aug 2026 the `gsa.apple.com` edge serves at most
  two requests per connection, then answers 503 HTML, which clients
  mis-parse as plist error 3840 (AltSign PR #52). `init` → `complete`
  → `apptokens` must each be first on a fresh connection.

Client-identity rules (the subtle part):
- **Sign-in (`init`/`complete`)**: the claim must match the anisette
  origin. With Android anisette, claim Android (Pixel 7 client info)
  or Apple returns `-80045` (12 Oct 2026 change). BUT the triple must
  be internally coherent for HSA2 trust: a stale Xcode 11.2 (2019) on
  macOS 13.1 makes Apple accept the 2FA code (HTTP 200) then challenge
  again forever (`hsc=409` / `au=secondaryAuth`) — AltStore issue
  #1772. isideload pins a coherent triple in
  `src/anisette/remote_v3/mod.rs`.
- **`apptokens` (`com.apple.gs.xcode.auth`) and all developer-services
  requests after it: claim a Mac**, e.g.
  `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1
  (com.apple.akd/1.0)>` + UA `akd/1.0 CFNetwork/808.1.4`. Claiming
  Android here returns `-80046` (22 Oct 2026 change) because an Xcode
  token for an Android phone makes no sense to Apple (Apparition blog;
  verified by probe: same session, only the claim changed). No Mac
  anisette server is needed for this — only the header changes.
  (Alternative route used by xtool/iloader: switch to Mac anisette
  from `mac-ani.jkcoxson.com`. Both routes exist.)
- Fetch the URL bag with the sign-in's own claim: fetching it claiming
  a Mac while signing in as Android makes GrandSlam answer the first
  password request with HTTP 503 (Apparition blog).

2FA: trusted-device push or SMS. The code is entered in-app; a second
`complete` carries it. AltLoad's failure rules (worth copying):
rejected password → remove it from Keychain; second rejection in a row
→ pause sign-ins for that Apple ID 15 minutes; locked account → remove
password + pause immediately; "too many requests" → pause without
removing. Pause state persisted on disk so it survives relaunch.
**App-specific passwords do NOT work** for this flow — sideloading
needs the real password plus a 2FA code (altserver-linux README).
Developer tokens are not saved between runs (AltLoad): the password
lives in Keychain and each refresh re-authenticates.

Tokens: the confirmed token is the **Xcode token**
(`com.apple.gs.xcode.auth`) from `apptokens`. The GSA session also
yields a persistent token used for re-authentication; the exact field
names (`pet`, `idmsa`, …) were **not verified from a source in this
research** — confirm from `isideload/src/auth/apple_account.rs`
during the build.

The 21 Nov 2026 `-22410` wave: GrandSlam returns
`-22410 "This action could not be completed"` at the login step.
isideload reports it at the *initial login request*
(`apple_account.rs:786`, `grandslam.rs:282`); S2Arm's changelog says
it fires *after entering the verification code*. Whether these are
two manifestations of one change or two separate triggers is
**unverified**. S2Arm v0.6.4 fixed it; the mechanism is unpublished.
isideload 0.5.2 still hits it (issues dated 21–23 Nov 2026).

## 4. Anisette / ADI — what it is and the on-device options

Anisette is the machine-identity proof Apple requires on auth
requests: headers `X-Apple-I-MD` (machine ID), `X-Apple-I-MD-M`
(one-time password), `X-Apple-I-MD-RINFO` (routing info), derived
from a provisioned ADI blob (`adi.pb`). Apple issues the ADI on first
contact (`startMachineProvisioning` on `gsd.apple.com`); the identity
is then stored and reused. The ADI can only be produced by Apple's
proprietary CoreADI code — there is no clean-room reimplementation.
Sources of that code: macOS (AOSKit/CoreADI.framework), Windows
(iTunes ADI), Android (Apple Music APK: `libCoreADI.so` +
`libstoreservicescore.so`).

Options for a sandboxed iOS app:

**A. Remote anisette-v3 server (RECOMMENDED, phase 1).**
Protocol (Dadoum/anisette-v3-server; documented in AltStore PR
#1834, GSAPortOSS, isideload):
- `GET /v3/client_info` → returns `client_info` + `user_agent`.
  **Use exactly these values** on the GSA requests; only accept
  servers whose `client_info` matches the platform you need
  (Windows or Mac currently; Android is fragile since Oct 2026).
- `WebSocket /v3/provisioning_session` → provisions a dedicated
  identity; store it client-side (e.g. `identity.json`) and reuse.
- `/v3/get_headers` → `X-Apple-I-MD`, `X-Apple-I-MD-M`
  (+ `X-Apple-I-MD-RINFO`).
- Re-provision once on `-45061` (identity expired); resync on
  `hsc 434` / `X-Apple-I-MD-DATA`.
- The server **never** sees the Apple ID, password, or 2FA code —
  only the device identity. (kisnner26 README.)
- Public servers (Nov 2026): `ani.jkcoxson.com` (Windows ADI),
  `mac-ani.jkcoxson.com` (Mac ADI), `ani2.stikstore.app`,
  `new.ani.sidestore.io`, `ani.sidestore.zip`, `ani.iloader.app`.
  Server list: `https://servers.sidestore.io/servers.json`.
  Rotate across 2–4 servers; try at most 2 per sign-in; never retry
  wrong passwords / 2FA failures (AltLoad). Offer a custom URL and a
  self-host option. Note the single-point-of-failure risk: most tools
  depend on one person's server (jkcoxson).

**B. On-device anisette via AnisetteKit (NOT recommended for phase 1).**
`mahee96/AnisetteKit` runs Apple's Android `.so` files in-process
inside a Unicorn Engine CPU emulator (TCI backend, no JIT) — full
on-device, no server. SideStore pins it (`db8b410`). BUT:
- Licence **AGPL-3.0** with an explicit "App Store Distribution
  Prohibited" clause and strong copyleft: any app linking it must be
  fully open-sourced under AGPLv3.
- It needs Apple's `.so` binaries: they may **not** be bundled or
  redistributed (Apple's binaries, no licence) — they must be
  downloaded at runtime from Apple's CDN and never redistributed.
- It produces **Android-identity** anisette — the identity Apple has
  been rejecting intermittently since 12 Oct 2026 (though the 30 Oct
  Content-Type finding shows Android anisette itself is accepted once
  the header is fixed; the situation is unstable).
- Immature: single maintainer, ~5 weeks old at Sep 2026.
- Unicorn Engine itself is **GPL-2.0** (verified).

**C. On-device ADI any other way: impossible.** iOS has no public API
for CoreADI, and `system()`/dynamic loading of foreign binaries is
unavailable in the sandbox. Do not plan a pure-Swift anisette
implementation.

Known anisette failure modes: `-45063` pending ADI session (stuck
state; fix: Reset `adi.pb`, turn OFF On-Device Anisette, remote
server sync Fetch + Save as Overrides — SideStore #1752/#1761);
`-45061` (re-provision); `-45025` unknown session (v3 provisioning
failure); `-45070` (AOSKit returns nothing, macOS 27);
`-80045` (platform/anisette mismatch); `-80046` (Android claim at
apptokens); `-20209` account locked (see §9).

## 5. Developer portal — free provisioning flow

**Use the private Xcode developer-services API, not the public
App Store Connect API.** The public ASC API needs a paid team API
key and cannot do free provisioning.

- Host: `https://developerservices2.apple.com`
- Protocol: QH (Quartz HTTP), plist request/response, pattern
  `/QH65B2/{action}.action`. Authenticated with the Xcode token from
  `apptokens` (exact header name — **verify from
  `isideload/src/dev/` during build**).
- Actions confirmed (PlumeImpactor DeepWiki; AltSign/isideload
  usage): `listTeams.action`, `listAppIds.action`,
  `addAppId.action`, `updateAppId.action`, `listDevices.action`,
  `addDevice.action`, `downloadTeamProvisioningProfile.action`.
  Certificate actions (fetch/create) exist in AltSign/isideload but
  their exact action names were **not verified in this research** —
  confirm from source during build.

Flow (AltLoad HOW-IT-WORKS §4; AltSign usage):
1. `listTeams` → pick team (`TeamSelection::First` for free accounts).
2. `ensure_device_registered(team, name, UDID)` — list devices, add
   if missing (see §6 for the UDID problem).
3. Certificate: reuse the stored development certificate (named e.g.
   `SideStore - <machine>`; the name is how the app finds the cert
   it already has — renaming orphans it) or create one (CSR → Apple
   → download cert → package as .p12 with the private key). At the
   certificate limit, prompt the user to pick certificates to revoke.
4. Register the App ID per bundle ID (and per extension), with the
   needed capabilities; register the app group if the app uses one.
5. Download the provisioning profile per App ID
   (`downloadTeamProvisioningProfile.action`). The response is a
   `.mobileprovision` file (CMS-signed plist) — our existing
   `ProvisioningEngine` already parses it.
6. Sign with zsign using the .p12 + the downloaded profile (§7).

## 6. The UDID problem (design decision required)

Device registration needs the device UDID. There is no public iOS API
for it (`identifierForVendor` is not the UDID). Options:

- **(a) User pastes the UDID** (from Finder, iTunes, 3uTools,
  udid.io). Friction, but works today with zero new infrastructure.
  Recommended for phase 1.
- **(b) LocalDevVPN + remote pairing** (the AltLoad/Madeira path):
  NEPacketTunnelProvider reflector + RPPairing host mode (iOS 27+;
  user pairs in Settings) + RSD handshake reads `UniqueDeviceID`.
  Big sub-project; needs the `idevice` Rust stack (MIT) and a VPN
  tunnel provider target. Phase 2.
- **(c) Import a pairing file** made on a computer (AltLoad's iOS
  18–26 fallback). Phase 2 alternative.

## 7. Plugging the fresh profile into our existing signing

Almost nothing new is needed here — this is the smallest part:
- The fresh `.mobileprovision` replaces `embedded.mobileprovision`
  in the .app bundle before zsign. Our zsign shim already takes the
  profile path (`provisionPath`) and `SignFolder` signs nested
  bundles with the same asset; our `SigningEngine` already passes
  the profile and validates it.
- The team ID comes from the profile (our `ProvisioningEngine`
  parses it; the signing engine's provisioning resolver re-parses
  `.mobileprovision` files in the Certificates folder).
- Entitlements: the profile Apple issues carries the entitlements;
  the signature must use the profile's entitlements (AltLoad:
  `enable_capabilities` registers the App ID with the capabilities
  first, then the issued profile carries them). Our engine already
  refuses unsupported entitlements — that validation stays.
- **New sub-component: on-device certificate creation.** The .p12
  must be generated on-device: create a key pair, build a CSR, submit
  it to Apple, download the issued certificate, package key+cert as
  .p12. AltSign does this with OpenSSL; isideload uses `rcgen` +
  `apple-codesign-quick`. We already bundle OpenSSL (SPM) + have
  KeychainService + CryptoKit — the building blocks exist. Store the
  private key in the Keychain, never in a file.

## 8. Free-account limits (confirmed, multiple sources)

| Resource | Limit |
|---|---|
| Installed sideloaded apps | **3 per device** |
| App IDs | **10** (per 7 days, per AltLoad; openv2: 10 registered App IDs) |
| Registered devices | **3**, expiring after 7 days |
| Provisioning profiles | **Expire 7 days after issuance** |
| Certificates | Development cert; exact lifetime **not verified** in this research (commonly ~1 year — confirm) |

Consequences: refresh must reuse App IDs (one per bundle ID) and
profiles (download fresh, don't re-register); the 3-app cap means
refresh has to handle "which 3 are active" (AltStore removes free
profiles before an install and restores the active ones after, to
stay under the cap — AltLoad HOW-IT-WORKS, On-device AltServer).
Background refresh cannot prompt for 2FA — AltLoad declines prompts
in background and notifies the user instead.

## 9. Risks (ranked)

1. **Sign-in is broken today (`-22410`, 21 Nov 2026).** isideload
   0.5.2 fails at the login step; S2Arm's fix is unpublished.
   Mitigation: spike first with a throwaway account; track isideload
   releases; apply the Apparition fixes (Content-Type `text/xml`,
   Mac claim for apptokens, one connection per GSA request, akd
   client id) and test each step in isolation.
2. **Apple changes the private APIs without notice.** Roughly one
   breaking change per month in late 2026 (§3). The feature needs a
   maintenance budget and a "sign-in health" check with clear errors.
3. **Account lockout (`-20209`).** Apple locks accounts that retry
   logins through public anisette servers; unlock via
   iforgot.apple.com. Mitigation: AltLoad's pause/backoff rules,
   never hammer retries, warn the user to use a **secondary Apple
   ID** (Dadoum/Provision README warns the same).
4. **Single-person anisette servers.** Most public servers are run by
   individuals; they go down or get blocked. Mitigation: rotation
   across servers, custom URL, self-host option.
5. **UDID acquisition** (§6) — user friction in phase 1, or a large
   phase-2 build (LocalDevVPN + RPPairing).
6. **2FA friction.** Every fresh sign-in needs a code; background
   refresh can't prompt. Design the UX around foreground refresh
   with a code prompt, plus expiry reminders.
7. **Trust: the app asks for the real Apple ID password.** It must go
   to Apple only, live in the Keychain, and the UI must say so
   plainly. App-specific passwords do not work.
8. **Rust FFI build complexity.** cargo → static library →
   XCFramework must be built on the macOS CI runner (the Linux VM
   cannot build it); adds CI time and a new failure surface.
9. **Licence hygiene.** See §10 — the wrong dependency (AnisetteKit,
   Dadoum code) would force AGPL on the whole app or be legally
   unusable.

## 10. Licence notes (per component — verify before use)

| Component | Licence | Notes |
|---|---|---|
| isideload (nab138) | **MIT** (Copyright © 2025 nab138) | The reference implementation to vendor as a library. Current GitHub API: MIT. (An old docs.rs page for 0.1.9 says MPL-2.0 — licence changed; trust the repo.) |
| idevice (jkcoxson) | **MIT** | Device protocols; needed only for the phase-2 tunnel path. |
| AltStore (altstoreio) | **AGPL-3.0** | Do NOT copy code. Riley Testut's README explicitly permits use/modify/distribute of *his original code* without restriction; dependencies keep their licences. Use as pattern reference only. |
| AltSign (rileytestut) | **AGPL-3.0** | Per poki README attribution ("AltSign (AGPL-3.0)"). Do NOT copy code; pattern reference only. |
| SideStore | **AGPL-3.0** | Correction to the brief (which said GPL-3.0): README + GitHub metadata say AGPLv3. Do NOT copy code. |
| SideSign (SideStore) | **GPL-3.0 per one source; AGPL-3.0 per another** (Odysseus README cites SideSign/LICENSE as AGPL-3.0; Mask notices say GPL-3.0) | **Conflict — verify from the repo before any use.** |
| AnisetteKit (mahee96) | **AGPL-3.0** + explicit "App Store Distribution Prohibited" | Linking it makes the whole app AGPL. Not for phase 1. |
| Unicorn Engine | **GPL-2.0** (verified) | Only relevant if AnisetteKit is used. |
| Dadoum/anisette-v3-server | **NO licence** (`license: null` in GitHub API) | All rights reserved by default — **do not copy its code**. Use only the protocol (documented in AltStore PR #1834, GSAPortOSS, isideload). |
| Dadoum/Provision | **Not verified** | Flag; do not copy without checking. |
| AltLoad (mirazbakis) | Custom MIT-based | Read/change/build for yourself; reuse parts in **non-commercial** projects with credit "Based on AltLoad by mirazbakis"; builds distributable only via official repo/website. Its HOW-IT-WORKS.md is the best architecture doc — patterns only. |
| GSAPortOSS | **MIT** | Anisette-v3 client reference. |
| apple-codesign-quick (Dadoum/apple-crates) | **LGPL-2.1** | isideload's signer — NOT needed; we already have zsign. |
| Apple .so libraries (`libCoreADI.so`, `libstoreservicescore.so`) | **Apple's, no redistribution licence** | Never bundle; if ever needed, download at runtime from Apple's CDN only. |
| Apparition (illixion) | Open source (licence not checked in this research) | Its blog is the best writeup of the Oct 2026 changes; its `claimed_platform.rs` + probe approach are the model for our spike. |

## 11. Build order

- **Phase 0 — Spike (before anything else).** Throwaway Apple ID.
  Reproduce the GSA sign-in with the Apparition fixes (Content-Type
  `text/xml`; akd client id; one connection per request; Android
  claim for sign-in, Mac claim for apptokens) and determine the
  current `-22410` status. If sign-in cannot be made to work, stop
  and report — the rest is pointless. Deliverable: a go/no-go note
  with the exact failing step and Apple error code.
- **Phase 1 — Rust core + sign-in.** Vendor `isideload` (pinned
  commit) as a Rust static library → XCFramework + thin C FFI
  (model: AltLoad `core/` + `altload.h`; Madeira's
  `libmadeira_rppairing.a`). Swift wrapper: anisette-v3 remote
  client (server list, rotation, custom URL), GSA login, 2FA sheet,
  Keychain storage for password + identity, AltLoad-style
  backoff/pauses. No developer-services calls yet. Prove: sign-in
  succeeds and returns a session + Xcode token.
- **Phase 2 — Developer services + certificate.** `DeveloperSession`:
  teams → device registration (UDID pasted by the user in phase 1)
  → CSR + cert creation + .p12 packaging (Keychain-held key) →
  App ID registration → profile download. Store profile + cert in
  our existing Certificates store. Prove: a fresh `.mobileprovision`
  downloads for a test bundle ID.
- **Phase 3 — Wire into Refresh.** Fresh profile → existing
  `RefreshApplicationUseCase` (replace the embedded profile) →
  zsign → loopback install. Expiry display already exists. Add:
  foreground refresh with 2FA prompt, expiry reminders (24 h
  before), background refresh task that declines prompts and
  notifies (AltLoad model).
- **Phase 4 — Hardening.** Server rotation + self-host field;
  cert-revocation detection (daily cert list check; re-sign when the
  profile names a revoked cert — AltLoad model); 3-app cap handling
  (remove/restore free profiles around installs); error mapping for
  every Apple code in §3–§4 with plain-language messages; "use a
  secondary Apple ID" warning.
- **Phase 5 (optional, later).** LocalDevVPN + RPPairing for UDID
  (phase-2 alternative to pasting); evaluate AnisetteKit for
  server-free anisette (AGPL decision needed first).

## 12. Open verification items (confirm from isideload source during build)

1. Exact header name carrying the Xcode token on
   `developerservices2` requests.
2. Exact certificate QH action names (fetch/create/download).
3. Exact GSA token field names (`pet`, `idmsa`, …) in the
   `apptokens` response and how session refresh works.
4. Exact anisette-v3 JSON shapes (client_info response, get_headers
   response, provisioning_session messages) — from
   `isideload/src/anisette/remote_v3/mod.rs` + AltStore PR #1834.
5. Whether `-22410` is fixed in the isideload version current at
   build time (check iloader issues + isideload releases first).
6. Development certificate lifetime for free accounts.
7. SideSign licence (GPL-3.0 vs AGPL-3.0) — only if SideSign is ever
   considered.

## 13. Sources

- AltSign PR #52 (sshane, Sep 2026) — one connection per GSA request;
  2-request limit; `init → complete → apptokens`.
  https://github.com/rileytestut/AltSign/pull/52
- AltStore PR #1790 (catdkny, Sep 2026) — edge 503 on
  `com.apple.dt.Xcode` in `X-MMe-Client-Info`; fix: `com.apple.akd/1.0`.
  https://github.com/altstoreio/AltStore/pull/1790
- AltStore PR #1834 (kisnner26, Oct 2026) — Windows anisette-v3
  servers; `/v3/client_info`, `/v3/provisioning_session`,
  `/v3/get_headers`; `ani.jkcoxson.com`.
  https://github.com/altstoreio/AltStore/pull/1834
- AltStore issue #1772 (sshane, Aug 2026) — HSA2 trust needs a
  coherent client-info triple; `hsc=409`/`au=secondaryAuth` loop.
  https://github.com/altstoreio/AltStore/issues/1772
- isideload PR #11 (AnInteger, Sep 2026) — same Xcode-client 503 fix
  in isideload; `client_info`/`user_agent` values.
  https://github.com/nab138/isideload/pull/11
- isideload repo (nab138) — MIT; README credits; module paths
  `src/auth/apple_account.rs`, `src/auth/grandslam.rs`,
  `src/dev/developer_session.rs`, `src/anisette/remote_v3/mod.rs`.
  https://github.com/nab138/isideload
- AltLoad HOW-IT-WORKS.md (mirazbakis) — the complete on-device
  architecture: FFI, anisette-v3 client, GSA, DeveloperSession,
  refresh + background refresh, failure/backoff rules, limits.
  https://github.com/mirazbakis/AltLoad/blob/HEAD/docs/HOW-IT-WORKS.md
- Apparition blog, "iOS sideloading error -80046" (Oct 2026) —
  `-80046` mechanism (Mac claim for `apptokens`
  `com.apple.gs.xcode.auth`); Content-Type `text/xml` fix; `gsd`
  vs `gsa` hosts; 403/DNS fallback.
  https://blog.illixion.com/2026/10/sideloading-error-80046/
- SideStore issues #1752, #1761 (Nov 2026) — `-45063` / 503
  workarounds: Reset `adi.pb`, On-Device Anisette off, remote sync
  Fetch + Save as Overrides, `new.ani.sidestore.io` / `mac-ani.jkcoxson.com`.
  https://github.com/SideStore/SideStore/issues/1752
  https://github.com/SideStore/SideStore/issues/1761
- S2Arm news (Nov 2026) — v0.6.4 fixes `-22410` after the 2FA code
  (Apple change from 21 Nov); mechanism unpublished.
  https://s2arm.com/en/news
- iloader issues #1228, #1247, #1249, #1230, #406, #1176, #673
  (Nov 2026) — `-22410` at initial login request
  (`grandslam.rs:282`); `-22411` at app-token request;
  URL-bag lookup `.../GsService2/lookup`.
  https://github.com/nab138/iloader/issues/1228
- Dadoum/Provision README — libprovision registers the device,
  ADI in `~/.adi/adi.pb`; needs Apple Music APK libs
  (`libstoreservicescore.so`, `libCoreADI.so`); "don't use your main
  Apple account".
  https://github.com/Dadoum/Provision
- AnisetteKit (mahee96) — on-device ADI via Unicorn-TCI emulation
  of the Android `.so` files; AGPL-3.0 + App Store distribution
  prohibited. https://github.com/mahee96/AnisetteKit
- Unicorn Engine — GPL-2.0 (verified).
  https://github.com/unicorn-engine/unicorn
- Madeira THIRD-PARTY-NOTICES.md (willfaust) — on-device
  pairing/signing-refresh/Apple-ID sign-in via isideload 0.4.4
  (MIT) + idevice (MIT); `AppleSignIn.swift`,
  `SigningRefresh.swift`.
  https://github.com/willfaust/Madeira/blob/HEAD/THIRD-PARTY-NOTICES.md
- PlumeImpactor DeepWiki, "Developer Portal APIs" — QH pattern
  `/QH65B2/{action}.action`; listTeams/listAppIds/addAppId/
  updateAppId/downloadTeamProvisioningProfile/listDevices/addDevice.
  https://deepwiki.com/khcrysalis/PlumeImpactor/4.2-developer-portal-apis
- OpenV2 docs, "Apple account limits" — 3 apps, 10 App IDs,
  3 devices, 7-day profiles.
  https://openv2.dev/docs/building/apple-account-limits
- altserver-linux README (Ben-Diehlci) — app-specific passwords do
  NOT work; real password + 2FA required; secondary Apple ID warning.
  https://github.com/Ben-Diehlci/altserver-linux/blob/HEAD/README.md
- onejailbreak, "Apple Locks Apple IDs … -20209" (Oct 2026) —
  account locks after public-server login retries; unlock via iForgot.
  https://onejailbreak.com/blog/apple-locks-apple-ids-on-sideload-login-with-20209/
- GSAPortOSS (kreato) — MIT anisette-v3 client reference
  (`/v3/client_info`, `/v3/provisioning_session`,
  `/v3/get_headers`).
- SideStore repo — AGPL-3.0 (README + GitHub metadata).
  https://github.com/SideStore/SideStore
- AltStore repo/README — AGPLv3 + Riley Testut's permission note.
  https://github.com/altstoreio/AltStore
- poki README (JosssphZhou) — "AltSign (AGPL-3.0)".
  https://github.com/JosssphZhou/poki/blob/main/desktop/README.md
- Odysseus README (mirazbakis) — SideSign AGPL-3.0 claim.
  https://github.com/mirazbakis/Odysseus

## Update 2026-11-26 — is -22410 fixed upstream? NO

Checked 2026-11-26 (research subagent, read-only):

- **isideload is still 0.5.2** (crates.io, published 2026-10-28). No newer version, and **zero commits on git main since 28 Oct 2026** — no -22410 fix exists, even unreleased. isideload ships via crates.io only (no GitHub releases).
  - https://crates.io/crates/isideload/versions
  - https://github.com/nab138/isideload/commits/main
- **iloader issues still failing on 0.5.2 / iloader v2.4.2** with the identical stack (`grandslam.rs:282`, `apple_account.rs:786`, "GrandSlam error during initial login request"): #1228 (21 Nov, still open, no maintainer comment), #1230, #1247, #1249, #1240, #1246, #1248, #1280, #1294, #1295 (latest report 23 Nov 2026).
- **S2Arm v0.6.4** fixed it closed-source ("Fixes Apple ID sign-in failing with '-22410 …' after entering the verification code (an Apple change from Nov 21)"). Mechanism unpublished, cannot be reused. https://s2arm.com/en/news

**New lead for the Phase 0 spike (hypothesis, not a confirmed fix):** SideInstaller v2.1.1 (21 Nov 2026) — "Since 20 November Apple has answered sign-ins through every Mac anisette server with HTTP 503, turning away any client that calls its system 'macOS'. SideInstaller now signs in as a Mac on **macOS 10.15.7, the newest that still calls itself 'Mac OS X'**, which Apple lets through."
  - https://newreleases.io/project/github/FrizzleM/SideInstaller/release/v2.1.1
  - Implication: the Apparition fix in this doc says claim a Mac as `<Mac15,7> <macOS;27.0;26A5378j>` for `apptokens`. That literal `"macOS"` string may now be exactly what Apple rejects. **The spike should test the 10.15.7 / "Mac OS X" client-info variant alongside the Apparition variant.** Caveat: SideInstaller reports HTTP 503, not -22410 — these may be two faces of the same 20–21 Nov change, or separate triggers; treat as a hypothesis to probe.

**Bottom line:** Phase 0 still runs as a go/no-go spike with the throwaway Apple ID — there is no isideload version to upgrade to. If the Apparition fixes alone don't clear -22410, try the SideInstaller-style macOS 10.15.7 ("Mac OS X") claim next; if that also fails, the only known working implementation (S2Arm) is closed-source, and the project would need its own reverse-engineering of whatever Apple changed on 21 Nov.

## Update 2026-11-26 — UDID feasibility gate: NO-GO on both questions

Checked 2026-11-26 (UDID workstream, research + build of the fallback only).
Per the task, the gate had two questions; either NO means no tunnel
target and no Wi-Fi-only flow. Both are NO.

### Q1 — Can a free Apple ID profile carry the Packet Tunnel entitlement? NO

- SideStore issue #1050 (maintainer reply, closed as won't-do): "Apps
  sideloaded with a free account can't get the vpn entitlement, period
  (this isn't possible)."
  https://github.com/SideStore/SideStore/issues/1050
- SideStore README (EM Proxy): the loopback tunnel comes from "a
  custom-built App Store app with additional entitlements (LocalDevVPN)
  ... without requiring a paid developer account" — i.e. the sideloaded
  app itself cannot hold the entitlement, so the tunnel is delegated to
  a separate App Store app.
- SideStore docs (JIT page): "you can't sideload apps with VPNs on a
  free account."
- iphone-use-app README: "Paid team: the app uses its own built-in VPN
  (needs the Network Extension entitlement). Free Apple ID: build with
  BUILTIN_VPN=NO and install LocalDevVPN."
  https://github.com/EliotAndres/iphone-use-app
- SogenIOS README: the `com.apple.developer.networking.networkextension`
  entitlement is one "which Apple does not grant to free personal-team
  accounts" — built-in tunnel needs "a paid Apple Developer Program
  account with Network Extensions approved".
  https://github.com/JackTYM/SogenIOS
- Apple, "Supported capabilities (iOS)": "The capabilities available
  to an iOS provisioning profile depend on your program membership",
  listing "Network extensions" and "Personal VPN" among the gated
  capabilities.
  https://developer.apple.com/help/account/reference/supported-capabilities-ios/
- One dissenting secondary claim exists (BirdoVPN docs: "Personal teams
  can use the packet-tunnel-provider capability in development") but it
  is contradicted by the SideStore maintainer statement and by every
  independent sideloading project above, and it concerns Xcode GUI
  development signing — not the QH `downloadTeamProvisioningProfile`
  flow this refresh uses. Not relied on.

Consequence: no Network Extension target was added, no entitlements
file for a tunnel was created, and the refresh flow's free profile
cannot authorize one. A built-in tunnel would need a paid team.

### Q2 — Can the LocalDevVPN + RPPairing flow run with Wi-Fi off (loopback only)? NO

The tunnel transport itself is local, but the flow as shipped by every
reference implementation requires Wi-Fi at two steps:

- **Tunnel addressing is Wi-Fi-subnet-derived.** LocalDevVPN setup
  requires "two different unused IPv4 addresses in the same subnet as
  the current Wi-Fi connection" and "When the Wi-Fi subnet changes,
  update both addresses before refreshing" (sidestore-auto-refresh
  README). With Wi-Fi off there is no Wi-Fi subnet to derive them
  from. Nuvio Z / SideStore guide: "Active Wi-Fi connection required
  on your iPhone (cellular alone is not sufficient for SideStore
  loopback)".
- **Pairing discovery is Bonjour/mDNS over the local network.**
  AltLoad HOW-IT-WORKS §1: the host advertises
  `_remotepairing-pairable-host._tcp` via `NetService` / mDNSResponder
  with the Local Network permission, and the user pairs in Settings.
  AltLoad's own failure text: "This iPhone's pairing service didn't
  show up on the network. Make sure Wi-Fi is on and Developer Mode is
  enabled." altload.org troubleshooting: "Developer Mode has to be on,
  rootshell needs Local Network access, and both must be on Wi-Fi."
- **SideStore enforces it in-app.** Error 1414: "SideStore cannot
  refresh or install applications without Wi-Fi and LocalDevVPN, ensure
  both are connected." Guides state it flatly: "Wi-Fi (mobile data
  does not work for installing or refreshing)" and "cellular-only
  refresh is not a supported promise."

This is NOT the same as the app's loopback install (itms-services to
127.0.0.1), which genuinely needs no Wi-Fi: that path uses a fixed
loopback address and no Bonjour discovery, while pairing discovery
needs the local network and the tunnel needs Wi-Fi-subnet addresses.
The "same principle as loopback install" premise does not transfer.

### Decision (2026-11-26)

- Phase 5 (LocalDevVPN + RPPairing in-app UDID) is **closed** for a
  free Apple ID and for a cellular-only requirement. Reopen only if
  the user accepts a paid Apple Developer Program team (Q1) AND
  Wi-Fi for pairing (Q2).
- The fallback is the shipped path: manual UDID paste
  (`DeviceUDIDStore` + `DeviceUDIDSection`, wired into
  InstallationView; 40-char hex, either case, stored in UserDefaults).
- Later option, unverified: pairing-file import (AltLoad's iOS 18–26
  path) — it still needs a computer once to make the file, and whether
  the UDID is extractable from the pairing record alone (without the
  tunnel + RSD handshake) was NOT verified; do not build on the guess.
- LocalDevVPN remains a possible *external* helper the user installs
  from the App Store (as SideStore/AltLoad use it) if the Wi-Fi
  constraint is ever relaxed — it is not bundled and not required by
  the paste fallback.

## Implementation status — 2026-11-26 (Phase 2 + 3 built)

- Rust core (`RustCore/apple_refresh/src/dev.rs`, v0.2.0): 9 new FFI
  functions on the same session handle — listTeams, listDevices,
  ensureDevice, listAppIDs, addAppID, listCertificates,
  createCertificate (isideload `CertificateIdentity::retrieve` +
  p12 packaging, private key file-backed under
  `<storage_dir>/certs/<sha256(email)>/key`, password random per
  p12), revokeCertificate, downloadProfile (raw .mobileprovision,
  base64). DeveloperSession cached 30 min, rebuilt via
  `from_account`; token never leaves Rust. `DeveloperError` now
  maps to code `developer_error` with `apple_ec` (was `internal`).
  8 Rust unit tests pass; clippy clean (also fixed the 1.100
  `not_unsafe_ptr_arg_deref` deny on all extern fns by marking
  them `unsafe extern "C" fn`, and the `Nonce::from_slice`
  deprecation in apptokens.rs).
- Swift: `AppleRefreshClientProtocol` + client extended with the 9
  dev calls; new `DeveloperServiceModels` (team/device/App ID/
  cert/created-cert/profile); `DeveloperServiceUseCase`;
  `RealRefreshUseCase` (sign-in silent with saved creds → team →
  ensure device → cert reuse/create + importP12 + repository save
  → App ID reuse/add → fresh profile download + import →
  `planWithFreshProfile` → sign → install). The sign-in use case
  now RETAINS the live client after success (previously closed);
  the container shares ONE sign-in use case instance so Settings
  sign-in and Installation refresh use the same live handle.
  `RefreshApplicationUseCase.planWithFreshProfile` added
  (record lookup factored into `findRecord`).
- UI: Installation Refresh now runs the REAL refresh when signed
  in (works on an expired profile — the button stays enabled when
  signed in) and falls back to the legacy same-profile re-sign
  when not signed in; 2FA sheet shared via `TwoFactorAnswering`
  protocol. Certificates tab lists the account's dev certificates
  with create/revoke. 14 new EN+AR strings (337 = 337).
- Live proof still pending on device: full login + app-token proof
  (IPA #6, 2FA fix), then a real refresh end to end.

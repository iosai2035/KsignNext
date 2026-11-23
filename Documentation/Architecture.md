# Ksign Next — Architecture (Phase 1 draft, 2026-11-23)

Source of requirements: the full master prompt in `workspace/user/files/51.txt`
(read in full, sections 1-30). No code has been copied from any reference
project. This document is the Phase 1 output; it will be revised after the
user supplies the Ksign app file and after the reference repos are inspected
(with the user's go-ahead — see Readiness Report).

## 1. Product
- Name: Ksign Next. iOS 16.0+, iPhone + iPad, Swift + SwiftUI, arm64.
- Purpose: import / analyse / sign / manage IPA files, certificates
  (P12 + mobileprovision), entitlements, tweaks (dylib / DEB / framework /
  bundle), sources, downloads, local install server, SideStore export.
- No jailbreak required for the supported functions. Anything that cannot
  run on stock iOS must be shown as unsupported, never as working.
- Identity is independent from Ksign; do not copy its UI verbatim.

## 2. Architecture (modular, per prompt §4)
- UI (Modules/*, SwiftUI) — never owns signing or Mach-O parsing.
- Domain (Models / Protocols / UseCases / Validation) — pure types + rules.
- Data (Repositories / Persistence / DTOs) — Core Data or SwiftData
  (decision deferred: evaluate SwiftData vs Core Data on iOS 16;
  SwiftData needs iOS 17, so Core Data is the likely choice for a 16.0 floor).
- Engines (Engines/*) — one independent, testable engine per concern:
  IPA, Archive, Mach-O, Signing, Certificate, Provisioning, Entitlements,
  Injection, Installation, Download, Verification.
- Core (Architecture / Concurrency / Networking / Security / Storage /
  Logging / FileSystem / Localization / ErrorHandling / Utilities).
- Cross-cutting: Swift Concurrency (async/await, Actors), Dependency
  Injection, Protocol-Oriented Design, Repository Pattern, Service Layer,
  typed errors (no empty catch, no force-unwrap on user files), structured
  logging with Operation ID, no secrets in logs.
- SigningEngine talks to Zsign only through an independent Adapter layer;
  verify the real headers / Swift bindings / build config before writing
  any call — do not assume a function name from the prompt.

## 3. Reference inventory (verified live 2026-11-23, see Readiness Report)
| Reference | Status found | Licence |
|---|---|---|
| Nyasami/Ksign (main) | exists, Swift, ~42 MB | GPL-3.0 |
| claration/feather (was khcrysalis/Feather) | moved/renamed | GPL-3.0 |
| claration/zsign (was khcrysalis/Zsign-Package) | moved/renamed, branch master | MIT |
| claration/idevicekit (was khcrysalis/IDeviceKit) | moved/renamed | MIT |
| khcrysalis/AltSourceKit | 404 — original gone; only forks remain | to verify |
| apple/swift-nio (main) | exists | Apache-2.0 |
| apple/swift-crypto | exists | Apache-2.0 (verify) |
| weichsel/ZIPFoundation (main) | exists | MIT |
| tsolomko/SWCompression (develop) | exists | MIT |
| openssl/openssl | exists | Apache-2.0 (verify) |

Licence consequence: Ksign and Feather are GPL-3.0. Any GPL code reused
would make the whole app GPL-3.0 and require source disclosure on
distribution. The prompt's rule stands: use them as a functional reference
only; write our own code, record every dependency in
THIRD_PARTY_NOTICES.md, and do not copy source, licences, keys or
certificates from the reference app.

## 4. Engines — responsibilities (prompt §5-14, summary)
- IPAEngine: import (Files / picker / share sheet), ZIP validation
  (corrupt ZIP, Zip Bomb, path traversal, unsafe symlink, size/count
  limits), Payload/.app discovery, Info.plist metadata, icons, extensions,
  frameworks, plug-ins, watch apps, inspection report.
- MachOEngine: magic numbers, CPU type/subtype, load commands
  (LC_LOAD_DYLIB / WEAK / RPATH / ID / CODE_SIGNATURE / BUILD_VERSION),
  UUID, segments/sections, dependencies, fat binaries. Bounds-checked
  reads only; no text search as a substitute for load-command parsing.
- CertificateEngine: P12/PFX, PEM/DER, mobileprovision; subject/issuer/
  serial/fingerprint/validity; Keychain storage only, never plaintext
  passwords; status valid/expired/revoked/invalid/mismatched/unknown
  (revoked only after a reliable check).
- ProvisioningEngine: CMS envelope -> inner plist, Team ID, App ID,
  entitlements, expiry, provisioned devices, bundle/team/app-ID matching.
- SigningEngine: P12+provisioning, ad-hoc where the environment allows,
  entitlements, bundle-ID change, bulk, extensions/frameworks first in
  Apple signing order, verify-after-sign, real IPA output only — no
  success message before signing + verification + a real file exist.
- EntitlementsEngine: XML/JSON view, compare, conflict report; never
  grant entitlements the certificate/provisioning do not allow.
- InjectionEngine: dylib/DEB/framework/bundle import, DEB control +
  data.tar, dependency/arch/conflict/duplicate detection, injection
  plan shown before execution; clearly label what cannot run on stock iOS
  (ElleKit/Substrate/jailbreak-only tweaks).
- InstallationEngine: local server (SwiftNIO/Vapor) + manifest + HTTPS,
  IDeviceKit adapter (pairing/AFC/install — verify what is actually
  usable from a normal iOS app), SideStore as the primary trial-install
  path (export a valid signed IPA + docs, no Apple-system bypass).
- DownloadEngine: URLSession (+ background where allowed), pause/resume/
  retry, concurrency limit, speed/ETA, hash check when the source provides
  one, no auto-execution of downloaded files.
- SourcesEngine: AltSource-style JSON sources only, HTTPS, parsing errors
  surfaced, no code execution from a source, no piracy sources.
- VerificationEngine: post-signing verification, archive structure check.

## 5. Data model (prompt §18)
ImportedApplication, SignedApplication, Certificate, Source,
DownloadTask, SigningOperation, Tweak, OperationLog — with migration,
relationships, indexing, no passwords / private keys stored.

## 6. Security (prompt §19)
Keychain + CryptoKit, no hardcoded private keys / TLS keys / certificates,
path-traversal + Zip-Bomb + symlink protection, safe extraction inside the
workspace only, atomic writes, HTTPS + certificate validation (never
disabled), no IPA/certificates uploaded to any server without explicit
user consent, Privacy Manifest.

## 7. UI (prompt §21)
11+ screens: Dashboard, Applications, Certificates, Signing Center
(12-step wizard), Tweaks, Downloads, Sources, File Manager, Mach-O
Inspector, Logs, Settings. Arabic + English with correct RTL, Dark/Light,
Dynamic Type, Accessibility. Every screen handles loading / empty /
success / error / offline / permission-denied. No mock data in the final
build, no dummy buttons.

## 8. Tests (prompt §24)
Unit (IPA/ZIP/plist/cert/provisioning/Mach-O/entitlements/validation/
repositories/download/signing state), Integration (import -> sign ->
verify -> export), Security (Zip Bomb, traversal, corrupt plist/Mach-O,
fake provisioning, wrong P12 password, insecure URLs, TLS, secret leakage
to logs), Performance (small/large IPA, many frameworks/extensions),
UI (import -> analyse -> certificate -> sign -> verify -> export).

## 9. Build / release (prompt §25-26)
macOS + Xcode + iOS SDK required for a real build. Scripts in Scripts/:
build.sh / package.sh / validate.sh / inspect_ipa.py. ExportOptions.plist
must match the user's real signing type/profile. No user certificates or
passwords in scripts or in Git. GitHub Actions: build, unit tests, static
analysis, dependency review, release — all without personal secrets.

## 10. Verified against the real Ksign 1.6 IPA (2026-11-23)
Full report: `Documentation/IPA-Comparison.md`. Verified: bundle
`nya.asami.ksign` v1.6, min OS 16.0, arm64 thin Mach-O, Core Data model
(entities CertificatePair/Signed/Imported/AltSource), 9 languages,
Vapor/NIOSSL local server, Zsign C++ engine, ElleKit DEB bundled.
Decisions taken from it: Core Data (not SwiftData, iOS 16 floor);
per-install generated TLS certificate, never a bundled private key
(the IPA bundles `server.pem` with a private key — do NOT copy);
own code and own identity only (GPL-3.0 reference).
Next: create `iosai2035/KsignNext`, push, build the IPA on a macOS
GitHub Actions runner (no Xcode on this Linux machine).

## 11. Open questions / blockers (to resolve with the user's Ksign file)
1. Which exact Ksign version / file is the reference? (file pending)
2. AltSourceKit original is gone — use a fork, re-implement, or drop it?
3. SwiftData vs Core Data on the iOS 16 floor.
4. Zsign integration shape (SPM package vs C library + adapter) — decide
   only after inspecting the real zsign headers.
5. Real build environment: this machine is Linux, no Xcode/Swift
   (see Readiness Report). A real IPA needs macOS + Xcode, or a
   GitHub Actions macOS runner.

## 12. Build status (coordinator, 2026-11-23)

Resolved since Phase 1:
- Reference file received and analysed: Ksign 1.6 IPA
  (`Documentation/IPA-Comparison.md`). Core Data confirmed (not
  SwiftData); AltSourceKit re-implemented from the public format
  (original repo is 404); Zsign integration = our own adapter +
  `ZsignBridge.h` over the MIT zsign library as a build-time
  dependency (not vendored).
- Full source project built: 105 Swift files, ~16,300 lines;
  Xcode project generated; CI workflow ready. Details, integration
  fixes, verification performed and remaining risks:
  `Documentation/Integration-Report.md`.
- **Not yet compiled** (no Xcode/Swift on this machine) and
  **signing is unavailable until zsign is linked** — see the
  Integration Report for the exact next steps.

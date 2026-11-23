# Ksign 1.6 IPA — Comparison Report (2026-11-23)

Reference file supplied by the user:
`workspace/user/files/Ksign_1_lpvu.ipa`
SHA-256: `57fbab135bdcd584faf095099f0913df634ce17081bc164ce82f3d91e3978483`
Size: 16 MB compressed, 30.9 MB uncompressed, 83 entries.

Method: read-only inspection of the ZIP in memory (listing, Info.plist,
Mach-O header/load commands, localisable strings). The binary was never
executed. Reference repos were inspected only by plain file reading,
after the user's explicit "نعم افحصها", and nothing was run, built or
copied from them.

## 1. Identity (verified from Info.plist)
- App: Ksign, bundle `nya.asami.ksign`, version 1.6 (build 1)
- MinimumOSVersion: 16.0 — matches the prompt's floor exactly
- Devices: iPhone + iPad (`UIDeviceFamily` 1, 2), arm64 only
- Built with: Xcode 2620 (17C52), SDK iphoneos 26.2, DTPlatformVersion 26.2
- URL scheme: `ksign`; document types: `.ipa` (Owner), `.tipa`
  (Alternate, TrollStore-friendly), `.ksign` certificate package (Owner)
- Background modes: `audio` (keeps the local install server alive);
  BGTask identifiers `nya.asami.ksign.userTask.*`
- File sharing on, document browser on, multiple scenes on
- Alternate icons: kana_ded / kana_love / kana_peek

## 2. Binary (verified from Mach-O)
- Thin 64-bit Mach-O, arm64 only (`cpu 0x0100000c`), filetype EXECUTE,
  74 load commands, UUID `a9f05266fd1f3057a45b5003cb97f55d`
- BUILD_VERSION: min OS 16.0.0, SDK 26.2.0
- LC_CODE_SIGNATURE present in the binary (offset 22484720, 193,936 B)
  but the IPA has **no `Payload/Ksign.app/_CodeSignature/` and no
  `embedded.mobileprovision`** — only the OpenSSL framework carries a
  `_CodeSignature/CodeResources`. So this file as supplied is not a
  normally App-Store-signed IPA; it is distributed for sideloading /
  TrollStore-style install. Do not treat its signature as a model.
- Main executable 21.63 MB; 42 linked dylibs including CoreData,
  CryptoKit, Security, SwiftUI/UIKit, WebKit, BackgroundTasks,
  UserNotifications, QuickLook, SafariServices, AVFoundation,
  `@rpath/OpenSSL.framework/OpenSSL` (the only bundled framework binary,
  4.22 MB).
- No other bundled frameworks — SwiftNIO/Vapor/ZIPFoundation/
  SWCompression/swift-crypto appear only as `.bundle` resource bundles
  (PrivacyInfo), i.e. they are statically linked SPM packages.

## 3. What is inside (83 entries)
- `Assets.car` 4.00 MB; `Feather.momd` Core Data model with entities
  CertificatePair, Signed, Imported, AltSource — **Core Data, not
  SwiftData**, which settles the prompt §18 choice for an iOS 16 floor.
- `ellekit.deb` 0.11 MB bundled in the app resources (injected when a
  tweak needs it).
- `server.crt` + `server.pem` bundled — **the .pem contains a private
  key** (`-----BEGIN PRIVATE KEY-----`), common name `*.backloop.dev`.
  This is exactly what prompt §19 forbids: no shared private TLS key
  in the IPA. Ksign Next must generate a per-install self-signed
  certificate at runtime instead, and must NOT copy this file.
- Languages (Localizable.strings): ar, cs, de, en, es, fr, ru, tr, vi
  — 9 languages. English has 253 keys, Arabic 299 keys (counts differ,
  so translations are not 1:1). The prompt asks for Arabic + English;
  we keep those two first and add the rest only if translated properly.
- `Settings.bundle` with an Acknowledgements child pane
  (`thewonderofyou.Feather`).

## 4. Reference source (plain reading, Ksign repo = Feather fork)
- Ksign repo: 189 Swift files. Top layout: `Ksign/Backend`
  (Observable / Server / Storage), `Extensions`, `Utilities`
  (Handlers, MachO, CertificateReader, ARDecompression), `Views`
  (Appstore, Download, Downloader, Files, Library, Settings,
  Signing, Sources, TabView).
- Key handlers found and their real shape:
  - `SigningHandler`: copy app to a unique temp dir
    (`FeatherSigning_<uuid>`), edit Info.plist (name/bundle/version/
    appearance/min-OS/file-sharing/ProMotion/GameMode/iPad fullscreen/
    remove devices/URL schemes/provisioning/watch placeholder/files),
    replace icon, remove `_CodeSignature` + `embedded.mobileprovision`,
    inject tweaks, disinject, sign (or ad-hoc, or only-modify), move
    result to `Documents/App/Signed/<uuid>`, record in Core Data.
    Note: it force-unwraps the Info.plist dictionary and calls
    `Zsign.sign` with a completion callback that only stores the error
    in `hadError` — Ksign Next must fix both (typed errors, real
    async completion, no force-unwrap on user files).
  - `ZsignHandler`: thin wrapper over `Zsign.sign(...)` with
    appPath / provisionPath / p12Path / p12Password / entitlements /
    custom id+name+version / adhoc flag; `disinject()` calls
    `Zsign.removeDylibs`.
  - `TweakHandler`: dylib / DEB / framework / bundle; DEB via AR
    extraction then `data.tar.*` (lzma/gz/xz/bz2); looks for
    `Library/Frameworks`, `Library/MobileSubstrate/DynamicLibraries`,
    `Library/Application Support` (incl. `var/jb/` variants); injects
    via `Zsign.injectDyLib` / `changeDylibPath` (rewrites
    CydiaSubstrate path to `@rpath/...`); optional ElleKit injection
    and injection into all extensions (PlugIns/Extensions, `.appex`).
  - `CertificateReader`: parses a mobileprovision by finding the
    `<?xml` range and decoding it as a plist `Certificate` model.
  - `ServerInstaller`: Vapor + NIOSSL local server, random port
    4000–8000, routes for manifest (plist), small/large icon,
    payload (streamed), `/install` HTML page; status via
    `InstallerStatusViewModel`.
  - `OptionsManager`: one Codable `Options` struct in UserDefaults
    (signing_options) — ppqProtection, dynamicProtection, identifiers/
    displayNames maps, injectionFiles, disInjectionFiles, removeFiles,
    file-sharing flags, removeProvisioning=true by default,
    removeSupportedDevices=true, doAdhocSigning, onlyModify,
    extractionLibrary Zip/ZIPFoundation, Liquid Glass experiments,
    replaceSubstrateWithEllekit, injectIntoExtensions=true,
    injectPath `@executable_path` / `@rpath`, injectFolder `/` /
    `/Frameworks/`.
  - Storage: Core Data (`Feather.xcdatamodeld`) split
    `Storage+Certificate/Imported/Shared/Signed/Sources`.
- Submodules were NOT in the shallow clone: `Ksign/Zsign`,
  `AltSourceKit`, `IDeviceKit`, `NimbleKit` are empty directories
  (git submodules, not fetched). The Swift `Zsign`/`ZsignSwift`
  bridge therefore still needs to be fetched from
  `claration/zsign` (separate clone, 94 MB, C++ in `src/`:
  `zsign.cpp` CLI + `signing.cpp`, `macho.cpp`, `bundle.cpp`,
  `openssl.cpp`, `certcheck.cpp`, `common/` archive/base64/sha/fs).
  Its CLI options confirm the feature set: `-k` pkey/p12, `-m`
  provision, `-p` password, `-b/-n/-r` bundle id/name/version,
  `-e` entitlements, `-l` inject dylib (repeatable), `-D` remove
  dylib, `-w` weak inject, `-a` adhoc, `-2` SHA256-only, `-C`
  check cert incl. OCSP, `-R` remove provision, `-E/-W/-U`
  remove extensions/watch/UISupportedDevices, `-M` min version,
  `-S` enable docs, `-o` output IPA, `-z` zip level, `-x` metadata.

## 5. Function → new engine map (prompt §3)
| Reference function | Ksign Next engine | Notes |
|---|---|---|
| SigningHandler copy/modify/move | SigningEngine | Rewrite: typed errors, AsyncStream progress, Actor state, verify-after-sign |
| ZsignHandler.sign / adhocSign / disinject | SigningEngine + Zsign Adapter | Adapter over claration/zsign; verify headers/bindings first |
| TweakHandler dylib/DEB/framework/bundle | InjectionEngine | Same DEB/AR/tar walk; add compatibility report + stock-iOS warning |
| CertificateReader + Storage+Certificate | CertificateEngine | P12 via Keychain; provision plist parsing; mismatch detection |
| ServerInstaller (Vapor/NIOSSL) | InstallationEngine | Per-install generated TLS cert — never bundle a private key |
| Storage (Core Data Feather model) | Data/Persistence | Core Data, entities Imported/Signed/CertificatePair/Source/DownloadTask/SigningOperation/Tweak/OperationLog |
| OptionsManager | Domain/Models SigningConfiguration | Same option set, plus SigningConfiguration from prompt §9 |
| DownloadManager / Sources (AltSourceKit) | DownloadEngine / SourcesEngine | AltSourceKit original is 404 — re-implement from its fork or from the AltStore source format; no code copied |
| Files / Hex / Plist editor ViewModels | Modules FileManager/HexEditor/PlistEditor | Prompt §15-17 |
| LogsManager | Core/Logging | LogLevel debug/info/warning/error/critical, Operation ID, export/filter |
| MachOUtils (.m/.h) + Zsign macho.cpp | MachOEngine | Bounds-checked parser, load commands, UUID, dylibs, RPATH |

## 6. Lessons / what NOT to copy
1. Do not bundle `server.pem` (private key) or any certificate.
2. Do not copy Ksign/Feather UI or code — GPL-3.0; write our own
   code and our own identity, use the reference only functionally.
3. Fix the reference's weak spots: force-unwrap of Info.plist,
   sign-completion error only stored in a property, no verification
   step before reporting success, passwords passed as plain strings
   through the call chain (ours go via Keychain + secure prompt).
4. Keep: iOS 16 floor, Core Data, ZIPFoundation option, Vapor/NIOSSL
   local server, ElleKit injection path, bulk signing, `.tipa` type.
5. The supplied IPA is unsigned for normal install — our final IPA
   must be built/exported with a real signing profile (or clearly
   documented as a SideStore/TrollStore build), and verified with
   `inspect_ipa.py` + SHA-256.

## 7. Open items before Phase 2 code
- Zsign Swift bridge (`ZsignSwift`) lives in the zsign submodule —
  fetch/verify its real Swift API before writing the Adapter.
- AltSourceKit: decide fork vs re-implementation.
- IDeviceKit: verify what is usable from a normal iOS app.
- GitHub repo for Ksign Next does not exist yet — create
  `iosai2035/KsignNext`, push, and build the IPA on a macOS
  GitHub Actions runner (no Xcode on this Linux machine).

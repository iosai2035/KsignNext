import SwiftUI
import UIKit

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "—"
    }

    /// The app icon, read from the bundle's icon files (the asset
    /// catalog's app icon set is not reachable as a named image, so the
    /// `CFBundleIcons` file names are resolved instead).
    private var appIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else {
            return UIImage(named: "AppIcon")
        }
        for name in files {
            if let image = UIImage(named: name) { return image }
        }
        return UIImage(named: "AppIcon")
    }

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("about.section.app", comment: "")).dsSectionHeader()) {
                HStack(alignment: .top, spacing: DS.Spacing.xl) {
                    if let icon = appIcon {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius))
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Text("Ksign Next").font(.title2.bold())
                        Text(String(format: NSLocalizedString("about.version", comment: ""), appVersion, buildNumber))
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("about.description", comment: ""))
                    }
                }
                .padding(.vertical, DS.Spacing.xs)
            }
            Section(header: Text(NSLocalizedString("about.section.links", comment: "")).dsSectionHeader()) {
                NavigationLink(NSLocalizedString("about.licences", comment: "")) {
                    LicencesView()
                }
                .accessibilityIdentifier("about.licences")
            }
            Section(header: Text(NSLocalizedString("about.section.info", comment: "")).dsSectionHeader()) {
                HStack { Text(NSLocalizedString("about.bundleid", comment: "")); Spacer(); Text(bundleIdentifier).font(.caption.monospaced()) }
                HStack { Text(NSLocalizedString("about.platform", comment: "")); Spacer(); Text("iOS 16.0+") }
                HStack { Text(NSLocalizedString("about.privacy", comment: "")); Spacer(); Text(NSLocalizedString("about.privacy.value", comment: "")) }
            }
        }
        .navigationTitle(NSLocalizedString("tab.about", comment: ""))
        .dsInlineTitle()
    }
}

/// In-app licences screen. Shows the repository's third-party notices
/// (`THIRD_PARTY_NOTICES.md`, embedded below as a string constant — the
/// project generator only bundles files under `Resources/`, so a
/// bundled text resource would need a project change). The
/// references-only section of that file is omitted here: it names other
/// apps, which must not appear in user-visible text.
private struct LicencesView: View {
    var body: some View {
        ScrollView {
            Text(thirdPartyNotices)
                .font(.body)
                .padding(DS.cardPadding)
        }
        .navigationTitle(NSLocalizedString("about.licences", comment: ""))
        .dsInlineTitle()
    }
}

// MARK: - Third-party notices (from THIRD_PARTY_NOTICES.md at the repo root)

private let thirdPartyNotices = #"""# Third-Party Notices — Ksign Next

## SPM dependencies (declared in KsignNext.xcodeproj, resolved by Xcode)

| Dependency | Repository | Licence | Version requirement | Used for |
|---|---|---|---|---|
| ZIPFoundation | weichsel/ZIPFoundation | MIT | upToNextMajor from 0.9.0 | ZIP handling (declared; the ArchiveEngine also has a pure-Swift ZIP implementation) |
| SWCompression | tsolomko/SWCompression | MIT | upToNextMajor from 4.8.0 | Compression formats (declared; DEB/tar detection is in ArchiveEngine) |
| SwiftNIO | apple/swift-nio | Apache-2.0 | upToNextMajor from 2.0.0 | Local install server (`NIOInstallationServer`) |
| swift-nio-ssl | apple/swift-nio-ssl | Apache-2.0 | upToNextMajor from 2.0.0 | TLS for the local install server |
| swift-crypto | apple/swift-crypto | Apache-2.0 | upToNextMajor from 3.0.0 | Crypto helpers |
| OpenSSL | krzyzanowskim/OpenSSL-Package | OpenSSL licence | upToNextMajor from 3.6.5000 | Prebuilt OpenSSL XCFramework (libcrypto/libssl + headers) for the vendored zsign C++ sources |

No dependency code is vendored in this repository, except the zsign
sources listed below, which are MIT-licensed and vendored with their
licence file; Xcode resolves the SPM entries from the URLs above at
build time. `Package.resolved` is git-ignored; the resolved versions
will be whatever Xcode picks within the stated ranges — record the
resolved versions here after the first macOS build.

## Zsign (MIT, vendored with its licence)

- Repository: claration/zsign, MIT — sources vendored in
  `Engines/SigningEngine/zsign/` (all of `src/` except the `zsign.cpp`
  command-line entry point, which is replaced by our own bridge) with
  the upstream licence at `Engines/SigningEngine/zsign/LICENSE-zsign`.
  Two deliberate trims versus upstream: the vendored zlib C sources
  are NOT included — only `zlib.h`/`zconf.h` are vendored and the
  implementation is the system libz (`-lz`, in the iOS SDK); and the
  Windows-only `iowin32.*` / `mztools.*` minizip files are omitted.
  One iOS adaptation: `ZUtil::SystemExecV` in `common/util.cpp` is
  stubbed to log and return false, because `system(3)` is unavailable
  in the iOS SDK and its only caller was the zsign command-line tool
  (`ideviceinstaller install ...`), which is not part of this build.
- Used through our own adapter only: `Engines/SigningEngine/ZsignAdapter.swift`
  (the `ZsignBridgeBackend`, which calls the C functions) and
  `Engines/SigningEngine/ZsignBridge.h` (our own C function names:
  `ksignnext_zsign_sign`, `ksignnext_zsign_remove_dylibs`,
  `ksignnext_zsign_inject_dylib`, `ksignnext_zsign_change_dylib_path`).
  The bridge implementation is our own code in
  `Engines/SigningEngine/zsign/zsign_bridge.cpp`; the `change_dylib_path`
  operation has no zsign equivalent and is implemented there from the
  Mach-O load-command layout.
- Signing now really runs: `SigningEngine` defaults to
  `ZsignBridgeBackend()`; `SigningError.zsignBackendUnavailable` is
  only thrown by the `UnavailableZsignBackend` stand-in, which is no
  longer the default.
- OpenSSL (above) is zsign's only external dependency: the CMS/PKCS#12
  signing in `openssl.cpp` uses full OpenSSL 3.x APIs that Apple's
  Security framework cannot replace on iOS (SecCMS is macOS-only).

## Apple refresh core (Rust, isideload 0.5.2)

- **isideload** — Repository: https://github.com/nab138/isideload, **MIT,
  Copyright (c) 2025 nab138**. Pinned by git rev
  `326e56229d0727cb6e7b34c8cf03e37e2cd3e17d` (the 0.5.2 release commit,
  2026-10-28) in `RustCore/apple_refresh/Cargo.toml`, with features
  `install` + `tokio-mt` (NOT `keyring-storage`); transitive versions
  pinned by the committed `Cargo.lock`. Used as a library only — no
  isideload code is vendored or modified. Our crate
  (`RustCore/apple_refresh/src/`) is our own code on top of isideload's
  public API, plus a small reimplementation of the apptokens request
  using only public fields, so a different client-info claim can be
  used for that one call (see `Documentation/Phase1-FFI-Design.md`
  §1/§5). The C interface is our own
  `RustCore/apple_refresh/include/AppleRefreshBridge.h`.
- **idevice** (transitive, via isideload's `install` feature) — MIT.
  Required because isideload 0.5.2 uses it unconditionally; unused by
  the Phase 1 sign-in flow.
- **ring** (transitive, via rustls / rcgen / idevice) — ISC-style
  "ring" licence (see the `ring` crate's LICENCE file). The one native
  C + assembly dependency in the tree; it has an explicit Apple-ABI
  `ios64` target.
- **apple-codesign-quick** (transitive, via isideload) — **LGPL-2.1**
  (Dadoum/apple-crates). Statically linked into the Rust core but
  **not used** by Phase 1 (zsign is our signer); it is only compiled
  because isideload depends on it. Flagged for licence review in the
  design doc (§2 #31): if LGPL-2.1 static linking ever objects, the
  dependency can only be removed by patching isideload.
- Content-Type note (design doc §9 Q1): isideload hardcodes
  `text/x-xml-plist`; internal testing found Apple blocks that
  value on `gsd.apple.com` (403) and `text/xml` works on both hosts.
  No fork patch is applied in Phase 1: the sign-in path keeps
  isideload's value, and our own apptokens-override path accepts a
  `content_type` config switch (default `text/x-xml-plist`) so the
  on-device spike can test `text/xml` without a fork. If the spike
  proves `text/xml` is required for sign-in, the fix is a one-line
  fork patch to isideload (MIT — allowed), recorded here at that time.

## Not included (deliberately)

- No `server.pem` / private TLS key (the reference IPA bundles one;
  prompt §19 forbids it). The install server generates a per-install
  certificate at runtime.
- No `ellekit.deb`, no kana icons, no assets from the reference IPA.
- No certificates, P12 files, provisioning profiles, passwords or
  private keys anywhere in the repository (`.gitignore` blocks them).

## This repository's own licence

MIT — see `LICENSE`. It covers the original code in this repository
only. Our code is written independently."""#

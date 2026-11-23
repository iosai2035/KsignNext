# Third-Party Notices — Ksign Next

## SPM dependencies (declared in KsignNext.xcodeproj, resolved by Xcode)

| Dependency | Repository | Licence | Version requirement | Used for |
|---|---|---|---|---|
| ZIPFoundation | weichsel/ZIPFoundation | MIT | upToNextMajor from 0.9.0 | ZIP handling (declared; the ArchiveEngine also has a pure-Swift ZIP implementation) |
| SWCompression | tsolomko/SWCompression | MIT | upToNextMajor from 4.8.0 | Compression formats (declared; DEB/tar detection is in ArchiveEngine) |
| SwiftNIO | apple/swift-nio | Apache-2.0 | upToNextMajor from 2.0.0 | Local install server (`NIOInstallationServer`) |
| swift-nio-ssl | apple/swift-nio-ssl | Apache-2.0 | upToNextMajor from 2.0.0 | TLS for the local install server |
| swift-crypto | apple/swift-crypto | Apache-2.0 | upToNextMajor from 3.0.0 | Crypto helpers |

No dependency code is vendored in this repository; Xcode resolves
them from the URLs above at build time. `Package.resolved` is
git-ignored; the resolved versions will be whatever Xcode picks
within the stated ranges — record the resolved versions here after
the first macOS build.

## Zsign (build-time C++ dependency, not vendored)

- Repository: claration/zsign (was khcrysalis/Zsign-Package), MIT.
- Used through our own adapter only: `Engines/SigningEngine/ZsignAdapter.swift`
  and `Engines/SigningEngine/ZsignBridge.h` (our own C function names:
  `ksignnext_zsign_sign`, `ksignnext_zsign_remove_dylibs`,
  `ksignnext_zsign_inject_dylib`, `ksignnext_zsign_change_dylib_path`).
- No zsign source is included in this repository. Until the zsign
  sources are added as a build-time dependency, signing throws
  `SigningError.zsignBackendUnavailable`.

## References only (no code, no assets copied)

| Project | Licence | Note |
|---|---|---|
| Ksign (Nyasami/Ksign) | GPL-3.0 | Functional/architectural reference only |
| Feather (claration/feather) | GPL-3.0 | Functional/architectural reference only |
| IDeviceKit (claration/idevicekit) | MIT | Evaluated; USB install is not available from a stock-iOS app, so only an honest "unsupported" adapter is shipped |
| AltSourceKit (khcrysalis/AltSourceKit) | Unknown — original repo returns 404 | Not used. The AltStore source format was re-implemented from the public format in `Engines/SourcesEngine/`; no AltSourceKit code is included |

## Not included (deliberately)

- No `server.pem` / private TLS key (the reference IPA bundles one;
  prompt §19 forbids it). The install server generates a per-install
  certificate at runtime.
- No `ellekit.deb`, no kana icons, no assets from the reference IPA.
- No certificates, P12 files, provisioning profiles, passwords or
  private keys anywhere in the repository (`.gitignore` blocks them).

## This repository's own licence

MIT — see `LICENSE`. It covers the original code in this repository
only. GPL-3.0 note: reusing GPL-3.0 code from Ksign/Feather would
make the distributed app GPL-3.0 and require corresponding source
disclosure. Our code is written independently; those projects are
references only.

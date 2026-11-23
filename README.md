# Ksign Next

iOS app (iOS 16+, Swift + SwiftUI, arm64, bundle id `com.ksignnext.app`)
to import, analyse, sign and manage IPA files, certificates,
entitlements, tweaks, sources and downloads — with SideStore export
for trial installs. No jailbreak required for the supported functions.

Status: **complete source project, ready to push and build on macOS.**
All Swift source is written (105 files, ~16,300 lines), the Xcode
project is generated, and a GitHub Actions workflow builds and exports
the IPA. It has **not** been compiled yet — there is no Xcode/Swift on
the machine where it was written (Linux). The first real build must
happen on a macOS runner (see below). Never treat this README as a
claim that a build succeeded.

## Push to GitHub (user step — needs their explicit permission)

```bash
cd KsignNext
git init
git add .
git commit -m "Ksign Next 1.0: complete source project"
git branch -M main
git remote add origin https://github.com/iosai2035/KsignNext.git
git push -u origin main
```

Create the repo `iosai2035/KsignNext` first (on github.com, or with
`gh repo create iosai2035/KsignNext --public`). Do **not** push any
`.p12`, `.mobileprovision`, `.pem` or `.key` file — `.gitignore`
already blocks them.

## Build the IPA (GitHub Actions)

Pushing to `main` runs `.github/workflows/build-ipa.yml` on
`macos-26` with Xcode 17: it regenerates the project, resolves SPM,
runs the unit/integration/security tests, archives in Release, exports
the IPA, validates it with `Scripts/inspect_ipa.py`, computes its
SHA-256, and uploads `KsignNext-ipa` as an artifact.

**Signing:** `ExportOptions.plist` uses method `development` with a
placeholder provisioning-profile name. For a real signed IPA you must
either set the `APPLE_TEAM_ID` secret and a matching development
profile, or change the method/profile in `ExportOptions.plist` to
your own. Until signing is configured, the archive step fails on
code signing (the workflow reports this separately from test
failures). Local build (macOS + Xcode):

```bash
python3 Scripts/generate_project.py   # regenerate KsignNext.xcodeproj
./Scripts/build.sh                    # archive + export (needs signing)
```

## Project layout

- `App/` — app entry, coordinator, state, DI container
  (`DependencyContainer` wires all real engines by default)
- `Core/` — errors, logging, Keychain, Core Data stack, file system,
  networking, concurrency, utilities, localisation
- `Domain/` — models, protocols, use cases, validation
- `Data/` — Core Data model + repositories, DTOs
- `Engines/` — IPA, Archive, Mach-O, Signing (+ Zsign adapter),
  Certificate, Provisioning, Entitlements, Injection, Installation,
  Download, Sources, Verification
- `Modules/` — Dashboard, Applications, Certificates, Signing Center
  (12-step wizard), Tweaks, Downloads, Sources, File Manager,
  HexEditor, PlistEditor, MachOInspector, Logs, Settings, About
- `Tests/` — unit, integration, security, UI tests
- `Scripts/` — `generate_project.py` (builds the .xcodeproj from the
  source tree), `build.sh`, `package.sh`, `validate.sh`,
  `inspect_ipa.py`

## Known limits (honest)

- **Zsign backend is not linked yet.** Signing is implemented end to
  end, but the actual cryptographic signing goes through
  `ZsignAdapter` / `ZsignBridge.h`, whose C++ implementation is
  supplied by the MIT-licensed zsign library (claration/zsign) as a
  build-time dependency. Until it is linked, signing throws
  `SigningError.zsignBackendUnavailable` with a clear message — it
  never fakes success. Linking zsign is the single biggest remaining
  build task (see `Documentation/Integration-Report.md`).
- **No AppIcon PNGs yet** — the icon set JSON exists; supply real
  1024×1024 artwork before release.
- **IDevice (USB install) is honestly unsupported** from a stock-iOS
  app; the adapter throws a clear error. SideStore export + the
  local install server are the supported install paths.
- **Tweaks depending on ElleKit/Substrate are not guaranteed on
  stock iOS** — the app says so in the plan, the result and the UI.
- The UI view models are local to each module; wiring every screen
  to the DI container's engines is a follow-up (the container and
  use cases are ready).
- Full docs: `Documentation/Architecture.md`,
  `Documentation/IPA-Comparison.md`,
  `Documentation/Integration-Report.md`.

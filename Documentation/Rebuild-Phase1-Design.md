# Ksign Next — Rebuild Phase 1: Design Contract (Wave 1)

**Date:** 2026-11-28 · **Phase:** 1 — Structure + Certificate Core (blueprint §7)
**Author:** Wave 1 design agent (no repo source code written — design documents only).
**Binding source:** `Documentation/Rebuild-2026-11-28.md` (blueprint, §1–§10 + build log).
The blueprint wins over any Gemini suggestion that contradicts it; every such
conflict is logged in §E.
**Gemini passes:** 5, model `gemini-3.5-flash-lite` (`gemini-2.5-flash` is
quota-blocked with 429 until ~20h). Prompts + raw answers saved as:
`Documentation/Gemini-Rebuild-P1-{Core,Domain-Data,Engines,UI-Navigation,Tests}-Prompt-2026-11-28.txt`
and `...-Answer-2026-11-28.txt`. No secrets, keys, certificates, passwords or
tokens were sent to Gemini. No reference (Ksign/SideStore/Feather) code was
pasted — mechanisms were described in the agent's own words.
**Verification method:** every Gemini suggestion was checked against the
verified old code (live tree at task start, then the reference snapshot
`~/workspace/ksign-next-rebuild-reference/` once the parallel surgery agent
deleted `Domain/Protocols/`, `Domain/UseCases/` and most of
`Data/Repositories/` from the live tree mid-task) and against the blueprint
and the verified deep-dive (`Documentation/Gemini-Deep-Dive-2026-11-28.md`,
60 findings). Adopted ideas are marked **[VERIFIED]** with the source;
rejected ideas are listed in §E with the reason.
**Visible-string rule (binding):** no other app or tool name in any
user-facing string in this design. The signing backend is referred to
generically as "the signing backend", never by its library name.

## 0. Sources verified (grounding)

| Source | What was taken from it |
|---|---|
| Blueprint §1–§10 | Layering, 14 entities, rewrite/reuse table, deletion list, manual renewal UX, TLS identity, phase order, test plan, navigation + §10.9 corrections + §10.10 binding rule |
| `Engines/CertificateEngine/CertificateEngine.swift` | P12 parse/import, DER walk, OID bug site (R-M1), Keychain account `p12-password-<uuid>`, 10 MiB limit, status() never `.revoked` |
| `Engines/ProvisioningEngine/ProvisioningEngine.swift` | CMS `<?xml…</plist>` extraction, RawProfile keys, kind heuristic, 5 MiB limit, id-from-UUID, `allows`/`deviceIsProvisioned` |
| `Domain/Models/CertificateModel.swift`, `ProvisioningModel.swift` | Existing struct fields, `isExpired`, `daysUntilExpiration`, `allows(bundleID:)` semantics |
| `Core/ErrorHandling/AppError.swift` | All existing error cases (kept verbatim — see §B.1) |
| `Core/Security/KeychainService.swift` | Existing API (kept verbatim — see §B.4) |
| `Core/Logging/LogsManager.swift` | Actor logger, caps 1000/10000, redaction list (basis for AppLogger) |
| `Core/FileSystem/SecureFileManager.swift` | Workspace confinement, atomic write, temp dirs (basis for FileSystemManager) |
| `Core/Networking/HTTPClient.swift` | 30s/300s timeouts, HTTPS-only, redirect cap (kept verbatim) |
| `App/AppCoordinator.swift`, `App/DependencyContainer.swift` | Open-In routing (W-1 fix), throwing-resolver requirement (W-5), UDID store |
| `Modules/Certificates/CertificatesView.swift` (L150–260), `CertificateDetailView.swift` | Import/register flow, password-sheet lifecycle, delete flow, CMS-note |
| `Modules/Installation/DeviceUDIDStore.swift` | UDID in UserDefaults key `ksign.deviceUDID`, 40-hex validation, uppercase normalisation |
| `Domain/Protocols/RepositoryProtocols.swift` | Repository shapes (kept — see §B.7) |
| `Data/Repositories/CoreDataCertificateRepository.swift` (reference snapshot) | save = upsert by id, returns Void; delete-missing throws `StorageError.notFound`; fetch-missing returns nil |
| Deep-dive (60 findings) | R-M1, W-2, W-3, W-4, W-5, W-6, W-7, W-8, M3, M5, R-L1, B-J1, B-J2 |

---

## A. File manifest — every file Wave 2 must create

Paths are relative to `~/workspace/ksign-next/`. `(NEW)` = create;
`(REWRITE)` = delete old content, write new; `(KEEP)` = keep file, Phase 1
does not touch it. No file outside this list is in Phase 1 scope; Wave 2
must not create files ad hoc — anything missing from this list needs
coordinator approval (§E).

### Core/ (NEW — fresh files, semantics carried over from verified old code)

| Path | Purpose |
|---|---|
| `Core/ErrorHandling/AppError.swift` (REWRITE) | Single unified throwable error type; existing cases verbatim + §B.1 additions |
| `Core/Logging/AppLogger.swift` (NEW) | The ONE log source (actor); replaces LogsManager; caps, redaction, persistence |
| `Core/Logging/LogEntry.swift` (NEW) | `LogEntry` + `LogLevel` value types (extracted so views can use them without the actor) |
| `Core/FileSystem/FileSystemManager.swift` (NEW) | Renamed SecureFileManager: workspace confinement, atomic writes, managed temp dirs, directory listing |
| `Core/Security/KeychainService.swift` (REWRITE) | Existing API verbatim; all failures throw, never swallowed |
| `Core/Networking/HTTPClient.swift` (REWRITE) | Existing API verbatim; 30s request / 300s resource; injectable session |
| `Core/Concurrency/TaskRegistry.swift` (NEW) | Registry of active tasks feeding the global progress HUD (§C.7) |

### Domain/Protocols/ (NEW)

| Path | Purpose |
|---|---|
| `Domain/Protocols/CertificateEngineProtocol.swift` (NEW) | CertificateEngine contract (§B.8) |
| `Domain/Protocols/ProvisioningEngineProtocol.swift` (NEW) | ProvisioningEngine contract (§B.9) |
| `Domain/Protocols/RepositoryProtocols.swift` (NEW) | Certificate + ProvisioningProfile repository contracts (§B.7) |

### Domain/Models/ + Domain/Entities/ (NEW)

| Path | Purpose |
|---|---|
| `Domain/Models/CertificateModel.swift` (NEW) | Certificate domain struct — existing fields + `isStoredInKeychain` (§B.6) |
| `Domain/Models/ProvisioningModel.swift` (NEW) | Profile domain struct — existing fields + `bundleIdentifierPrefixes`, `platform`, `dataHash` (§B.6) |
| `Domain/Models/CertificateStatus.swift` (NEW) | `CertificateStatus` + `CertificateKind` enums (moved out of the model file) |
| `Domain/Models/ProvisioningKind.swift` (NEW) | `ProvisioningKind` enum |
| `Domain/Models/ExpiryState.swift` (NEW) | Shared expiry computation: `daysUntilExpiration`, `ExpiryBand` (green/amber/red/expired) |

### Domain/UseCases/ (NEW)

| Path | Purpose |
|---|---|
| `Domain/UseCases/ImportCertificateUseCase.swift` (NEW) | P12 import orchestration with rollback (§B.10) |
| `Domain/UseCases/ImportProvisioningProfileUseCase.swift` (NEW) | Profile import orchestration with rollback (§B.10) |
| `Domain/UseCases/DeleteCertificateUseCase.swift` (NEW) | Delete file + record + Keychain item, per-step errors (W-6) |
| `Domain/UseCases/DeleteProvisioningProfileUseCase.swift` (NEW) | Delete profile file + record, per-step errors (W-6) |
| `Domain/UseCases/FetchExpiringProfilesUseCase.swift` (NEW) | Dashboard expiry list via ProvisioningEngine (W-2 fix) |

### Domain/Validation/ (NEW)

| Path | Purpose |
|---|---|
| `Domain/Validation/DeviceUDIDValidator.swift` (NEW) | 40-hex UDID validation + normalisation (carried over) |
| `Domain/Validation/DeviceUDIDStore.swift` (NEW) | Pasted UDID in UserDefaults, key `ksign.deviceUDID` (carried over) |

### Data/ (NEW)

| Path | Purpose |
|---|---|
| `Data/Persistence/KsignNext.xcdatamodeld/` (NEW version) | Model file keeps its name; new model version `v2` with Certificate + ProvisioningProfile entities (§B.6) |
| `Data/Persistence/PersistenceController.swift` (NEW) | Core Data stack; `performBackground`, `load()`, manual-migration detection |
| `Data/Repositories/CoreDataCertificateRepository.swift` (NEW) | Certificate repository; upsert by id; maps Core Data errors to `AppError.storage` |
| `Data/Repositories/CoreDataProvisioningProfileRepository.swift` (NEW) | Profile repository; upsert by id/uuid |
| `Data/Mappers/CertificateMapper.swift` (NEW) | Managed-object ↔ `CertificateModel` mapping (lives in Data, not Domain) |
| `Data/Mappers/ProvisioningProfileMapper.swift` (NEW) | Managed-object ↔ `ProvisioningModel` mapping |

### Engines/ (NEW)

| Path | Purpose |
|---|---|
| `Engines/CertificateEngine/CertificateEngine.swift` (NEW) | P12 parse/import, DER walk with UInt64 OID fix (R-M1), status() |
| `Engines/ProvisioningEngine/ProvisioningEngine.swift` (NEW) | CMS profile parse/import, validatePair, coverage checks |
| `Engines/ArchiveEngine/ArchiveEngine.swift` (NEW — Wave 2, deflate fix) | ZIP reader: EOCD/central-directory/local-header parsing, method 0 + method 8 (raw inflate via vendored zlib, `inflateInit2(-15)` — the fake-wrapper decoder is deleted), CRC-32 verification, §B.3 caps, R-H2 negative-size guards, ZIP64 rejected, symlink safety (M11), tar + gunzip (same fix) |

### Modules/ + App/ (NEW)

| Path | Purpose |
|---|---|
| `App/KsignNextApp.swift` (NEW) | App entry; owns AppCoordinator; calls stale-temp cleanup at launch (W-18) |
| `App/AppCoordinator.swift` (NEW) | Single central router: 6 tabs + side menu, sheets/covers, `ksignnext://`, Open-In (§C.6) |
| `App/DependencyContainer.swift` (NEW) | DI wiring; throwing resolvers only (W-5); no login/session objects |
| `Modules/Common/DesignSystem.swift` (NEW) | Spacing/cards/buttons/accent/titles (existing tokens kept verbatim) |
| `Modules/Common/GlobalProgressHUD.swift` (NEW) | HUD capsule + drawer bound to TaskRegistry (§C.7) |
| `Modules/Dashboard/DashboardView.swift` (NEW) | Expiry overview + activity from AppLogger + counts (§C.2) |
| `Modules/Dashboard/DashboardViewModel.swift` (NEW) | Dashboard state; expiry via FetchExpiringProfilesUseCase; errors surfaced (W-4 dead alert removed) |
| `Modules/Applications/ApplicationsView.swift` (NEW) | Honest Phase 1 empty state, one line, no buttons (§C.1 exception) |
| `Modules/Sources/SourcesView.swift` (NEW) | Honest Phase 1 empty state, one line, no buttons (§C.1 exception) |
| `Modules/Downloads/DownloadsView.swift` (NEW) | Honest Phase 1 empty state, one line, no buttons (§C.1 exception) |
| `Modules/SideMenu/SideMenuView.swift` (NEW) | Side menu: active signing identity card + Certificates entry + import shortcuts (§10.3أ) |
| `Modules/Files/FilesView.swift` (NEW) | Sandbox browser: navigate/share/delete/rename; per-extension tap rules (§C.4) |
| `Modules/Files/FilesViewModel.swift` (NEW) | Files state via FileSystemManager; read errors surfaced, never `?? []` (W-11) |
| `Modules/Certificates/CertificatesView.swift` (NEW) | Manager: two sections, import, delete (§C.3) |
| `Modules/Certificates/CertificatesViewModel.swift` (NEW) | Import/delete state; password cleared once consumed; errors surfaced |
| `Modules/Certificates/CertificateDetailView.swift` (NEW) | Detail per kind + expiry countdown + UDID coverage (§C.3) |
| `Modules/Settings/SettingsView.swift` (NEW) | Settings root: Storage, Diagnostics, About (§C.5) — no Certificates entry (side menu, §10.3أ) |
| `Modules/Settings/StorageView.swift` (NEW) | Live storage bytes + purge temp action |
| `Modules/Settings/DiagnosticsView.swift` (NEW) | Live AppLogger stream + export + clear |
| `Modules/Settings/AboutView.swift` (NEW) | Version/build + copy diagnostics summary; app info only |
| `Resources/Localizations/en.lproj/Localizable.strings` (REWRITE) | Phase 1 strings, English |
| `Resources/Localizations/ar.lproj/Localizable.strings` (REWRITE) | Phase 1 strings, Arabic — key-count parity with English, enforced (§C.8) |

### Tests/ (NEW)

| Path | Purpose |
|---|---|
| `Tests/UnitTests/Core/AppLoggerTests.swift` | §D (10 tests) |
| `Tests/UnitTests/Core/AppErrorTests.swift` | §D (6 tests) |
| `Tests/UnitTests/Core/FileSystemManagerTests.swift` | §D (8 tests) |
| `Tests/UnitTests/Core/KeychainServiceTests.swift` | §D (8 tests) |
| `Tests/UnitTests/Core/HTTPClientTests.swift` | §D (4 tests) |
| `Tests/UnitTests/Engines/CertificateEngineTests.swift` | §D (12 tests) |
| `Tests/UnitTests/Engines/ProvisioningEngineTests.swift` | §D (15 tests) |
| `Tests/UnitTests/Engines/ArchiveEngineTests.swift` | §D (20 tests — Wave 2, deflate-fix regression suite, M10 fix) |
| `Tests/Fixtures/Archive/minimal-ipa-method8.zip` + `README.md` | Minimal compressed-IPA fixture (method-8 Info.plist + stored control entry) for ArchiveEngineTests |
| `Tests/UnitTests/Repositories/CertificateRepositoryTests.swift` | §D (6 tests) |
| `Tests/UnitTests/Repositories/ProvisioningProfileRepositoryTests.swift` | §D (6 tests) |
| `Tests/UnitTests/UseCases/ImportCertificateUseCaseTests.swift` | §D (5 tests) |
| `Tests/UnitTests/UseCases/ImportProvisioningProfileUseCaseTests.swift` | §D (5 tests) |
| `Tests/UnitTests/ViewModels/DashboardViewModelTests.swift` | §D (4 tests) |
| `Tests/UnitTests/ViewModels/CertificatesViewModelTests.swift` | §D (6 tests) |
| `Tests/Fixtures/` (NEW dir) | Test fixtures incl. generated P12/profile files + `Fixtures/README.md` (§D.6) |
| `Tests/Support/FixtureBuilder.swift` (NEW) | Synthetic DER/CMS/profile builders; in-memory Core Data stack; fake engines; Keychain test service |

### Explicitly NOT in Phase 1 (do not create)

`Engines/SigningEngine`, `Engines/InstallationEngine`, `Engines/SourcesEngine`,
`Engines/DownloadEngine`, `Engines/EntitlementsEngine`,
`Engines/IPAEngine`, `Engines/MachOEngine`, `Engines/InjectionEngine`,
`Engines/VerificationEngine`, `Engines/TLSIdentityService`, any
`Modules/AdvancedTools/`, `Modules/Locker/`, `Modules/Signing/`,
`Modules/Installation/`, `Modules/Sources/`, `Modules/Downloads/`,
`Modules/*Editor*`, `SignApplicationUseCase`, `ReSignApplicationUseCase`,
`ManageDigitalLockerUseCase`, `LogsManagerLogRepository` (deleted per
blueprint §4 — `LogRepository` protocol is NOT carried into Phase 1; log
reads go through `AppLogger` only), any Rust/Apple ID/login file.

---

## B. Public contracts — exact Swift interfaces Wave 2 must implement

Conventions for this section: `throws` means plain (untyped) `throws`
throwing `AppError` unless stated. No `try?` to `nil` at any call site
(W-5/M5). No force-unwraps, no `as!`, no `try!`. All public types are
`Sendable` or actors. Error messages never contain secrets (no password,
no private-key material, no file bytes).

### B.1 AppError — keep existing shape verbatim [VERIFIED]

**[VERIFIED]** Existing `Core/ErrorHandling/AppError.swift` (all cases
listed below, read verbatim from source). Gemini's rewritten nested enums
were rejected (§E): they dropped `.signing`, `.cancelled`,
`.unknown(underlying:)`, dropped payloads from `notYetValid` and
`unsupportedType`, and invented `StorageError`/`NetworkError` shapes that
contradict the verified file. Wave 2 keeps this file's cases exactly and
adds only the two cases marked ADD.

```swift
public enum AppError: LocalizedError, Equatable {
    case signing(SigningError)
    case certificate(CertificateError)
    case ipa(IPAError)
    case download(DownloadError)
    case network(NetworkError)
    case storage(StorageError)
    case validation(ValidationError)
    case cancelled
    case unknown(underlying: String)
}
```

`CertificateError` — keep verbatim: `invalidFormat(reason:)`,
`wrongPassword`, `expired(expirationDate:)`, `notYetValid(notBefore:)`,
`revoked`, `missingPrivateKey`, `keychainFailure(reason:)`,
`provisioningInvalid(reason:)`, `provisioningExpired(expirationDate:)`,
`provisioningMismatch(reason:)`, `unsupportedType(String)`.
ADD (Phase 1, both **[VERIFIED]** as needed-by-design, not from Gemini):
`certificateNotListedInProfile` is NOT added — the existing
`provisioningMismatch(reason:)` covers it (verified `validatePair`).
No ADD needed for R-M1: the OID fix returns `nil` from the DER helper
(see §B.8), it does not throw. No ADD needed for profile-expired-at-import:
existing `provisioningExpired(expirationDate:)` covers it.
**Result: zero new `CertificateError` cases in Phase 1.**
`SigningError`, `IPAError`, `DownloadError`, `NetworkError`,
`StorageError`, `ValidationError` — keep verbatim from the existing file
(incl. `StorageError.notFound(id:)`, `.saveFailed`, `.loadFailed`,
`.deleteFailed`, `.migrationFailed`, `.unavailable`; `NetworkError.offline`,
`.timeout`, `.invalidResponse`, `.httpStatus`, `.tlsFailure`,
`.underlying`; `ValidationError.invalidDeviceUDID` — the UDID message
stating the 40-character rule is kept).
**Binding normalisation (resolves a verified inconsistency):** the old
`CoreDataCertificateRepository` threw bare `StorageError` while its
protocol doc claimed `AppError.storage`. In Phase 1 every repository
method throws `AppError` (storage cases); the concrete implementation
maps Core Data errors to `AppError.storage(...)` at its boundary.
`FileSystemManager.validatedURL` throws
`AppError.ipa(.pathTraversalAttempt(entry:))` (old code threw bare
`IPAError`; normalised to `AppError` per the same rule).

### B.2 AppLogger — the single log source (W-4, W-20) [VERIFIED]

Replaces `LogsManager`. Same caps, same redaction list, one source.
**[VERIFIED]** Caps 1000 in-memory / 10000 persisted lines and the
`secretKeys` set are read verbatim from `Core/Logging/LogsManager.swift`.
The one-shot persist-retry flag is adopted from deep-dive W-20 (not from
Gemini — Gemini also suggested it, and the deep-dive already required it).

```swift
public actor AppLogger {
    public static let shared = AppLogger()
    public static let maxInMemoryEntries = 1_000
    public static let maxPersistedEntries = 10_000
    public static let secretKeys: Set<String> = [
        "password", "passphrase", "privatekey", "private_key",
        "token", "accesstoken", "access_token", "secret",
        "apikey", "api_key", "authorization", "bearer",
        "p12password", "p12_password", "certificatepassword"]

    public init(fileURL: URL? = nil)   // default: Application Support/KsignNext/logs.jsonl
    public func log(_ level: LogLevel, _ message: String,
                    operationID: UUID? = nil, metadata: [String: String] = [:])
    public func debug(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:])
    public func info(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:])
    public func warning(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:])
    public func error(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:])
    public func critical(_ message: String, operationID: UUID? = nil, metadata: [String: String] = [:])
    public func logError(_ error: Error, operationID: UUID? = nil, context: String = "")
    public func allEntries() -> [LogEntry]
    public func entries(matchingLevel minimum: LogLevel) -> [LogEntry]
    public func entries(forOperation operationID: UUID) -> [LogEntry]
    public func search(_ query: String) -> [LogEntry]
    public func clear() throws   // W-19: removal failure is thrown, not swallowed; caller surfaces it
    public func exportJSON() throws -> Data
    public func exportText() -> String
    public func loadPersistedEntries()
    public static func redact(_ text: String) -> String
    public static func redactMetadata(_ metadata: [String: String]) -> [String: String]
}
```

Rules: Dashboard, Diagnostics view and every use case read via
`AppLogger.shared.allEntries()` / `search` / `entries(...)` — never by
reading the log file from disk (W-4). `clear()` throws on file-removal
failure (W-19) and the caller must surface it in the UI; `persist`
failures set a one-shot flag so the next successful persist retries the
trim (W-20). Logging never crashes the app and never logs a secret;
`redact` is a safety net, not permission to pass secrets.

```swift
public struct LogEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID; public let timestamp: Date; public let level: LogLevel
    public let message: String; public let operationID: UUID?
    public let metadata: [String: String]
}
public enum LogLevel: String, Codable, Sendable, Comparable {
    case debug, info, warning, error, critical
}
```

### B.3 FileSystemManager — atomic writes + managed temp dirs (M3, M12, W-18)

Renamed from `SecureFileManager`; semantics carried over verbatim.
**[VERIFIED]** Workspace root `Documents/KsignNext`, symlink-resolved
confinement, `.atomic` write, temp-dir API and 24h stale cleanup are
read verbatim from `Core/FileSystem/SecureFileManager.swift`.
Rejected Gemini deviations (§E): workspace root `KsignWorkspace`,
string-`hasPrefix` path check (weaker than symlink resolution),
`.completeFileProtection` added to writes, system-`temporaryDirectory`
for managed temp dirs, throwing `freeSpaceBytes`.

```swift
public final class FileSystemManager: @unchecked Sendable {
    public static let shared = FileSystemManager()
    public static let maxIPABytes: Int64 = 2_147_483_648
    public static let maxArchiveEntries = 50_000
    public static let maxDecompressedBytes: Int64 = 8_589_934_592
    public static let maxSingleFileBytes: Int64 = 1_073_741_824
    public static let maxDecompressionRatio: Double = 100.0
    public let workspaceRoot: URL
    public init(workspaceRoot: URL? = nil)

    public enum WorkspaceFolder: String {
        case imported = "Imported"; case signed = "Signed"
        case certificates = "Certificates"; case downloads = "Downloads"
        case temp = "Temp"; case tweaks = "Tweaks"; case inbox = "Inbox"
    }
    public func folder(_ folder: WorkspaceFolder) throws -> URL
    public func ensureWorkspaceExists() throws
    public func validatedURL(forRelativePath relativePath: String) throws -> URL
    public func validatedURL(_ url: URL) throws -> URL   // symlink-resolved; throws AppError.ipa(.pathTraversalAttempt)
    public static func isPath(_ url: URL, inside directory: URL) -> Bool

    public func writeAtomically(_ data: Data, to url: URL) throws   // Data.write(.atomic); M3
    public func readData(at url: URL) throws -> Data
    public func fileSize(at url: URL) throws -> Int64
    public func delete(at url: URL) throws
    public func move(from source: URL, to destination: URL) throws

    public struct FileEntry: Sendable, Equatable {
        public let url: URL; public let name: String; public let isDirectory: Bool
        public let size: Int64?; public let modificationDate: Date?
    }
    public func listDirectory(at url: URL) throws -> [FileEntry]   // NEW for Files tab; read errors throw, never `?? []` (W-11)

    public func createTempDirectory(named name: String? = nil) throws -> URL  // inside workspace Temp; caller owns cleanup
    public func cleanupTempDirectory(_ url: URL)              // best-effort, non-throwing (validated inside)
    public func cleanupStaleTempDirectories(maxAge: TimeInterval = 86_400)   // W-18: called at app launch
    public func freeSpaceBytes() -> Int64?                    // nil = unknown; never throws
}
```

### B.4 KeychainService — throw, never swallow (M5) [VERIFIED]

Existing API kept verbatim from `Core/Security/KeychainService.swift`.
Rejected Gemini's rewritten API (§E): it made `read` throw on
not-found (breaks the verified nil contract), did an unconditional
`SecItemDelete` before every save, and referenced the nonexistent type
`AppError.CertificateError`.

```swift
public final class KeychainService: @unchecked Sendable {
    public static let shared = KeychainService()
    public init(service: String = "com.ksignnext.app")
    public func savePassword(_ password: String, account: String) throws
    public func readPassword(account: String) throws -> String?   // nil = no item; throws on genuine failure
    public func save(_ data: Data, account: String) throws        // duplicate → SecItemUpdate
    public func read(account: String) throws -> Data?             // nil = errSecItemNotFound
    public func delete(account: String) throws                    // errSecItemNotFound = success
    public func exists(account: String) -> Bool
}
```

Invariants: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on every
item; every failure throws `CertificateError.keychainFailure(reason:)`;
callers must surface the error, never `try?` it to `nil` (W-5/M5).
P12 passwords live under account `"p12-password-<certificate-uuid>"`
**[VERIFIED]** (`CertificateEngine.passwordAccount(for:)`, existing code).
The private key itself is NOT extracted into Keychain in Phase 1:
the verified design stores the P12 password in Keychain and the `.p12`
file on disk; the blueprint's `keychainReferenceID` (UUID) is satisfied
by the certificate UUID embedded in that account string — see §B.6.
(Gemini's claim that Phase 1 must move the SecKey into Keychain was
rejected: `SecPKCS12Import` gives an in-memory identity; persisting the
key as a Keychain item is a Phase 2 signing concern, and the verified
password+file design is what the old code proved.)

### B.5 HTTPClient — 30s request / 300s resource (R-L1) [VERIFIED]

Ships in Phase 1 (rejected Gemini's "defer to Phase 2" — blueprint §1
lists it in Core and this contract requires it). Existing API kept
verbatim from `Core/Networking/HTTPClient.swift`. Rejected Gemini's
snippet (§E): it contained a typo that does not compile, dropped the
HTTPS-only guard and the redirect cap, and ignored the injectable
`session` that already exists.

```swift
public final class HTTPClient {
    public static let shared = HTTPClient()
    public struct Configuration {
        public var requestTimeout: TimeInterval = 30
        public var resourceTimeout: TimeInterval = 300
        public var allowsCellularAccess: Bool = true
        public var maxRedirects: Int = 5
        public init() {}
    }
    public init(configuration: Configuration = Configuration(), session: URLSession? = nil)
    public struct Request { public var url: URL; public var method: String = "GET"
        public var headers: [String: String] = [:]; public var body: Data? = nil
        public var allowInsecureHTTP: Bool = false   // test servers only; never for remote sources
        public init(url: URL) }
    public struct Response { public let data: Data; public let statusCode: Int
        public let headers: [AnyHashable: Any]; public let url: URL? }
    public func send(_ request: Request) async throws -> Response   // throws AppError.network
    public func getJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T
    public func contentLength(for url: URL) async throws -> Int64?
}
```

Rules: HTTPS-only by default; certificate validation never disabled;
no custom delegate trusting arbitrary certificates; `URLError.timedOut`
→ `AppError.network(.timeout)`; redirect cap enforced by delegate.
Phase 1 has no network calls — the client ships tested and idle, ready
for Phase 3 sources/downloads (which must route through it, R-L1).

### B.6 Entities — Certificate + ProvisioningProfile (blueprint §2, Phase 1 subset)

Domain structs are plain `Codable, Equatable, Identifiable, Sendable`
structs; Core Data uses generic `NSManagedObject` + mapper functions in
`Data/` (the verified existing pattern — Gemini's generated-subclass
proposal rejected as churn, §E). Extensibility: the model file keeps its
name `KsignNext.xcdatamodeld`; Phase 1 adds model version `v2` with
exactly the two entities below; Phases 2–4 add the remaining 12 entities
as new model versions. Migration is manual per blueprint §2 (detect old
store → ask user to back up → fresh empty store → programmatic move
with transforms → explicit error reporting). No lightweight migration.

**Reconciliation table (blueprint field → Phase 1 field):**

| Blueprint §2 field | Phase 1 field | Note |
|---|---|---|
| Certificate.id | `id: UUID` | unchanged |
| issuerName / subjectName | `issuer: String?` (display string `CN=…, O=…`), `commonName: String?` (subject CN) | verified DER parsing; no separate subjectName stored |
| commonName | `commonName: String?` | |
| serialNumber | `serialNumber: String?` (hex) | |
| teamIdentifier | `teamIdentifier: String?` (subject OU 2.5.4.11) | |
| expirationDate / creationDate | `expirationDate: Date?`, `notBefore: Date?` | `creationDate` = `importedAt` (import time, not cert issue time) |
| isStoredInKeychain | `isStoredInKeychain: Bool` (NEW, stored) | true iff `keychainAccount != nil` |
| keychainReferenceID (UUID) | `keychainAccount: String?` (kept, verified) | account = `"p12-password-<id>"`; the UUID in it IS the reference — no second field |
| p12FileName | computed `fileURL?.lastPathComponent` | not stored separately |
| dataHash (SHA-256) | `fingerprint: String` (SHA-256 hex of DER) | alias documented; no duplicate field |
| signingOperations | — (OMITTED from model v2) | No relationship in model v2: a relationship whose destination entity does not exist is invalid and fails model load. Phase 2 model v3 adds `signingOperations` together with the `SigningOperation` entity. |
| (existing) `name`, `kind`, `status`, `fileURL`, `importedAt` | kept verbatim | `kind` from CN; `status` per §B.8 |
| ProvisioningProfile.id | `id: UUID` (derived from profile UUID when parseable) | verified stable-id rule |
| name / uuid / teamIdentifier | `name`, `uuid`, `teamIdentifier: String` (non-optional) | required, else `provisioningInvalid` |
| bundleIdentifierPrefixes | `bundleIdentifierPrefixes: [String]` (NEW, stored) | `[bundleIdentifier]` in Phase 1 (single App ID); extensible |
| platform | `platform: String?` (NEW, stored) | nil in Phase 1 — profiles carry no explicit platform field; filled by later phases |
| expirationDate / creationDate | `expirationDate: Date?`, `creationDate: Date?` | |
| dataHash | `dataHash: String` (NEW, stored) | SHA-256 hex of the raw file bytes, computed at import |
| provisionedDevices | `provisionedDevices: [String]` | UDIDs, verbatim |
| profileData (raw CMS bytes) | file on disk via `fileURL` (kept, verified) | REJECTED Gemini external-storage-in-Core-Data: it would duplicate the file, double storage, and hide the profile from the Files tab. `profileData` is available by reading `fileURL`. |
| signingOperations | — (OMITTED from model v2) | No relationship in model v2 — see the `signingOperations` row above. |
| (existing) `appIdentifier`, `teamName`, `kind`, `entitlements`, `certificates`, `fileURL`, `importedAt` | kept verbatim | `entitlements` flattened display strings; `certificates` base64 DER |

```swift
public struct CertificateModel: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var commonName: String?
    public var issuer: String?
    public var serialNumber: String?
    public var fingerprint: String              // SHA-256 hex of DER == dataHash
    public var teamIdentifier: String?
    public var kind: CertificateKind            // .development / .distribution / .unknown (CN-derived)
    public var status: CertificateStatus
    public var notBefore: Date?
    public var expirationDate: Date?
    public var fileURL: URL?
    public var keychainAccount: String?         // "p12-password-<id>"
    public var isStoredInKeychain: Bool         // NEW
    public var importedAt: Date
    public var isExpired: Bool { expirationDate.map { $0 < Date() } ?? false }
    public var daysUntilExpiration: Int?        // Calendar days from now; nil if no expiry
    public var p12FileName: String? { fileURL?.lastPathComponent }
}
public enum CertificateStatus: String, Codable, CaseIterable, Sendable {
    case valid, expired, revoked, invalid, mismatched, unknown
}
public enum CertificateKind: String, Codable, CaseIterable, Sendable {
    case developer, distribution, development, adhoc, unknown
}

public struct ProvisioningModel: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var uuid: String
    public var appIdentifier: String            // TEAMID.bundleID
    public var teamIdentifier: String
    public var teamName: String?
    public var kind: ProvisioningKind
    public var expirationDate: Date?
    public var creationDate: Date?
    public var bundleIdentifierPrefixes: [String]   // NEW; [bundleIdentifier] in Phase 1
    public var platform: String?                    // NEW; nil in Phase 1
    public var dataHash: String                     // NEW; SHA-256 hex of raw file bytes
    public var entitlements: [String: String]
    public var provisionedDevices: [String]
    public var certificates: [String]               // base64 DER
    public var fileURL: URL?
    public var importedAt: Date
    public var isExpired: Bool { expirationDate.map { $0 < Date() } ?? false }
    public var bundleIdentifier: String             // appIdentifier minus "TEAMID." prefix
    public func allows(bundleID: String) -> Bool    // VERIFIED semantics — see §B.9
}
public enum ProvisioningKind: String, Codable, CaseIterable, Sendable {
    case development, adhoc, appStore, enterprise, unknown
}

public enum ExpiryBand: Sendable { case healthy, warning, urgent, expired }
public func expiryBand(daysUntilExpiration: Int?) -> ExpiryBand
// nil → .healthy (no expiry known; UI shows "no expiry date", never a fake countdown)
// Binding (blueprint §5): >7 days → .healthy (green); 1–7 days → .warning (orange);
// expires within 24h → .urgent (red); past expiry → .expired (red).
// ≤3 days shows the persistent banner; ≤24h shows the urgent banner.
```

**Core Data model v2 (entities + indexed attributes):**
`CertificateEntity`: `id` UUID (indexed, unique), `name` String,
`commonName` String?, `issuer` String?, `serialNumber` String?,
`fingerprint` String (indexed, unique), `teamIdentifier` String?,
`kind` String, `status` String, `notBefore` Date?, `expirationDate`
Date? (indexed), `fileURL` String?, `keychainAccount` String?,
`isStoredInKeychain` Bool, `importedAt` Date.
`ProvisioningProfileEntity`: `id` UUID (indexed, unique), `name` String,
`uuid` String (indexed, unique), `appIdentifier` String,
`teamIdentifier` String, `teamName` String?, `kind` String,
`expirationDate` Date? (indexed), `creationDate` Date?,
`bundleIdentifierPrefixes` Transformable [String], `platform` String?,
`dataHash` String, `entitlements` Transformable [String:String],
`provisionedDevices` Transformable [String], `certificates`
Transformable [String], `fileURL` String?, `importedAt` Date.
Neither entity carries a `signingOperations` relationship in model v2
(corrected 2026-11-28, Wave 2 final integration): the earlier draft
reserved the slot, but a Core Data relationship must point at an
existing destination entity — `SigningOperation` does not exist until
Phase 2 — and a dangling relationship makes the model fail to load.
Phase 2 model v3 adds the to-many `signingOperations` relationship
together with the `SigningOperation` entity.

### B.7 Repository protocols [VERIFIED]

Keep the verified shapes from `Domain/Protocols/RepositoryProtocols.swift`
(`save` returns `Void` and is an upsert by id; `fetch` returns `nil` when
missing; `delete` throws when missing). Rejected Gemini's
`@discardableResult save() -> Model` (gratuitous change) and its invented
`StorageError` cases (§E). Binding normalisation: all methods throw
`AppError` (storage cases); the concrete Core Data implementation maps
its errors at the boundary.

```swift
public protocol CertificateRepository: AnyObject, Sendable {
    func fetchAll() async throws -> [CertificateModel]
    func fetch(id: UUID) async throws -> CertificateModel?
    func fetch(fingerprint: String) async throws -> CertificateModel?
    func save(_ certificate: CertificateModel) async throws   // upsert by id
    func delete(id: UUID) async throws   // throws AppError.storage(.notFound(id:)) when missing [VERIFIED]
}
public protocol ProvisioningProfileRepository: AnyObject, Sendable {   // NEW — no profile repo existed
    func fetchAll() async throws -> [ProvisioningModel]
    func fetch(id: UUID) async throws -> ProvisioningModel?
    func fetch(uuid: String) async throws -> ProvisioningModel?
    func save(_ profile: ProvisioningModel) async throws   // upsert by id
    func delete(id: UUID) async throws   // throws AppError.storage(.notFound(id:)) when missing
}
```

Rules: `fetchAll` sorted by `importedAt` descending (verified old
behaviour); `save` finds by `id` or inserts (verified upsert);
`fetch(fingerprint:)` / `fetch(uuid:)` are exact-match, fetch-limit 1;
no repository ever returns mock data; no repository touches the
Keychain or the filesystem — side-effect cleanup belongs to the use
cases (§B.10), not the repository (W-6). `LogRepository` is NOT in
Phase 1 (see §A).

### B.8 CertificateEngine — P12 parse/import, OID UInt64 (R-M1) [VERIFIED]

Keep the verified class shape: `public final class CertificateEngine:
CertificateEngineProtocol, @unchecked Sendable` with injected
`keychain` + `fileManager`. Rejected Gemini's actor protocol, typed
`throws(AppError)`, and invented `ParsedIdentity`/`StoredCertificate`
types (§E). Methods stay `async throws -> CertificateModel` /
`ProvisioningModel` (parsing reads files; `async` is kept so callers
never block the main actor on I/O).

```swift
public protocol CertificateEngineProtocol: AnyObject, Sendable {
    func parseP12(at url: URL, password: String) async throws -> CertificateModel
    func parseCertificate(at url: URL) async throws -> CertificateModel
    func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel  // delegates to ProvisioningEngine; ONE implementation (W-2)
    func importP12(at url: URL, password: String) async throws -> CertificateModel
    func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel
    func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws
    func status(of certificate: CertificateModel) async -> CertificateStatus
    func storedPassword(for certificate: CertificateModel) throws -> String?
    static func passwordAccount(for id: UUID) -> String   // "p12-password-<uuid>"
}
```

Verified behaviour carried over (do not change):
- Limits enforced inside the engine before parsing/saving: P12/cert
  10 MiB, profile 5 MiB → `AppError.certificate(.invalidFormat(reason:))`
  / `.provisioningInvalid(reason:)` when exceeded.
- `parseP12`: `SecPKCS12Import` with `kSecImportExportPassphrase`;
  `errSecAuthFailed` → `.wrongPassword`; empty items → `.invalidFormat`
  ("The P12 file is empty."); identity without private key →
  `.missingPrivateKey`. Multiple identities: take the first.
  Password-less P12 (`password == ""`) must succeed (W-3).
- `parseCertificate`: raw DER, or PEM (`-----BEGIN CERTIFICATE-----`).
- Model from `SecCertificateCopyData` + DER walk: serial INTEGER (hex),
  issuer DN display string (`CN=…, O=…`), validity UTCTime (0x17) /
  GeneralizedTime (0x18), subject CN (OID 2.5.4.3) + OU (2.5.4.11 =
  teamIdentifier). `kind`: CN contains "apple development" /
  "iphone developer" / "ios developer" → `.development`;
  "apple distribution" / "iphone distribution" / "ios distribution" /
  "developer id" → `.distribution`; else `.unknown`.
  `fingerprint` = SHA-256 hex of DER. `status()`: fingerprint empty or
  `notBefore` in future → `.invalid`; past `expirationDate` → `.expired`;
  no `expirationDate` → `.unknown`; else `.valid`. **`.revoked` is NEVER
  returned** (no OCSP/CRL check) — a test pins this (§D).
- `importP12`: parse → atomic copy to `Certificates/` as
  `<base>-<id>.p12` → save password in Keychain under
  `passwordAccount(for: model.id)` → on Keychain failure delete the
  copied file and throw `.keychainFailure` (no orphan file). Sets
  `model.fileURL`, `model.keychainAccount`, `model.isStoredInKeychain = true`,
  `model.status`. **Password-less P12s are registered too** (W-3 fix):
  the empty password is saved as `""` and the repository save happens
  unconditionally — the use case (§B.10) never skips registration.
- `validatePair` check order (verified, keep): (1) team mismatch
  (cert team non-empty and != profile team) → `.provisioningMismatch`;
  (2) profile expired → `.provisioningExpired`; (3) certificate expired
  → `.expired`; (4) profile lists certificates and none matches the
  certificate fingerprint (SHA-256) → `.provisioningMismatch`.
  A `nil` expiration date means "no expiry known" — it is NOT an error
  (rejected Gemini's nil-rejection, §E). Bundle-ID and device coverage
  are NOT part of `validatePair` (signing-time checks, Phase 2).

**R-M1 fix (binding, from the verified deep-dive — NOT Gemini's
variant):** in `derOIDString`, accumulate arcs in `UInt64` and reject
over-large arcs at arc end:

```swift
var value: UInt64 = 0
for byte in content.dropFirst() {
    value = (value << 7) | UInt64(byte & 0x7F)
    if byte & 0x80 == 0 {
        guard value <= UInt64(Int.max) else { return nil }
        arcs.append(Int(value))   // value <= Int.max, so this is safe
        value = 0
    }
}
```

Rejected Gemini R-M1 variant (§E): cap at `UInt32.max` (stricter than
the verified fix; could reject valid certificates), throwing instead of
returning `nil` (the helper returns `String?`; callers already skip a
`nil` OID), and a confused `leadingZeroBitCount` guard. DER audit
(Gemini correct here, verified against source): length accumulation is
safe (≤4 length bytes + `index + length <= data.count` guard);
first-arc `first / 40` is safe (first byte bounded by ASN.1 rules);
serial-hex conversion is safe (iterates a bounded slice).

### B.9 ProvisioningEngine — CMS parse + validation (W-2) [VERIFIED]

Keep the verified shape from `Engines/ProvisioningEngine/
ProvisioningEngine.swift`, including the `ProvisioningEngineProtocol`
defined in that file. `allows`/`deviceIsProvisioned` exist BOTH as
engine methods and as model methods — the model owns the pure logic,
the engine delegates to it (verified existing design; rejected
Gemini's "engine-only" rule, which would have deleted the tested
`ProvisioningModel.allows` used by `ProvisioningModelAllowsTests`).

```swift
public protocol ProvisioningEngineProtocol: AnyObject, Sendable {
    func parseProvisioningProfile(at url: URL) async throws -> ProvisioningModel
    func importProvisioningProfile(at url: URL) async throws -> ProvisioningModel
    func validatePair(certificate: CertificateModel, profile: ProvisioningModel) async throws
    func allows(bundleID: String, profile: ProvisioningModel) -> Bool
    func deviceIsProvisioned(_ deviceUDID: String, in profile: ProvisioningModel) -> Bool
}
```

Verified behaviour carried over (do not change):
- CMS extraction: a `.mobileprovision` is a PKCS#7/CMS envelope wrapping
  an XML plist. **Hardening change adopted (from Gemini, reasoned +
  test-pinned):** search the FIRST `<?xml` and the LAST `</plist>`
  (backwards search) instead of the first `</plist>` — a plist string
  value containing the literal `</plist>` must not truncate the document.
  The full DER/CMS ASN.1 walk is deferred (not Phase 1 scope); the
  scan stays, with the last-occurrence fix and a regression test (§D).
  No CMS signature verification is attempted — a parsed profile is
  structurally valid only, never presented as Apple-verified
  (`CMSDecoder` is macOS-only and unavailable on iOS).
- Required keys, else `.provisioningInvalid`: non-empty `Name`, `UUID`,
  `TeamIdentifier` (first element); `appIdentifier` =
  `Entitlements["application-identifier"]` ?? `"<first prefix>.*"`,
  non-empty. `id` = `UUID(uuidString: uuid) ?? UUID()` (stable id).
- `kind` heuristic: `ProvisionsAllDevices` → `.enterprise`; no devices
  → `.appStore`; `get-task-allow` true → `.development`; else `.adhoc`.
- `importProvisioningProfile`: parse → reject already-expired profile
  with `.provisioningExpired` BEFORE any file copy → atomic copy to
  `Certificates/` as `<base>-<id>.mobileprovision` → set `fileURL`,
  `dataHash` (SHA-256 of raw bytes). Parse alone does NOT reject expiry.
- `allows(bundleID:)` — **verified semantics, keep exactly** (rejected
  Gemini's `bundleID == basePrefix` addition): allowed = bundle part of
  App ID; `"*"` → true; `"com.example.*"` → true iff
  `bundleID.hasPrefix("com.example.")` (so `com.example.foo` matches
  but `com.exampleFoo` does NOT, and `com.example` itself does NOT);
  else exact equality. `deviceIsProvisioned` = exact `contains` on
  `provisionedDevices` — nothing else (rejected Gemini's
  App-Store-empty-list → `true` fallback: an App Store profile covers
  NO pasted UDID by list; its coverage is "all devices via the store",
  which Phase 1 reports as "no device list — covers any device" in the
  UI, not as a `true` from this function).

### B.10 Use cases — import + delete, throw never swallow (W-3, W-5, W-6, W-8)

```swift
public struct ImportCertificateUseCase: Sendable {
    public init(engine: CertificateEngineProtocol,
                repository: CertificateRepository,
                keychain: KeychainService,
                fileSystem: FileSystemManager,
                logger: AppLogger)
    public func execute(fileURL: URL, password: String) async throws -> CertificateModel
}
public struct ImportProvisioningProfileUseCase: Sendable {
    public init(engine: ProvisioningEngineProtocol,
                repository: ProvisioningProfileRepository,
                fileSystem: FileSystemManager,
                logger: AppLogger)
    public func execute(fileURL: URL) async throws -> ProvisioningModel
}
public struct DeleteCertificateUseCase: Sendable {
    public init(repository: CertificateRepository, keychain: KeychainService,
                fileSystem: FileSystemManager, logger: AppLogger)
    public func execute(id: UUID) async throws   // throws AppError listing which step(s) failed
}
public struct DeleteProvisioningProfileUseCase: Sendable {
    public init(repository: ProvisioningProfileRepository,
                fileSystem: FileSystemManager, logger: AppLogger)
    public func execute(id: UUID) async throws
}
public struct FetchExpiringProfilesUseCase: Sendable {
    public init(repository: ProvisioningProfileRepository,
                engine: ProvisioningEngineProtocol)
    public func execute() async throws -> [ProvisioningModel]  // sorted by expirationDate ascending, expired first
}
```

**Import transaction order (binding) — parse → validate → copy →
Keychain → save record; rollback in reverse on failure:**
1. Parse via engine (throws typed error; nothing written yet).
2. Validate: profile import rejects expired profiles here, before any
   copy. Certificate import has no expiry rejection at import (an
   expired certificate can be imported and is shown as expired — the
   verified old behaviour; signing refuses it later).
3. Copy file atomically into `Certificates/` (engine does this).
4. Keychain: save password under `passwordAccount(for: id)` — ALWAYS,
   even when `password == ""` (W-3 fix; rejected Gemini's "validate
   password non-empty before recording", which reintroduces W-3).
5. Save record in repository.
Rollback: Keychain-save failure → delete copied file (engine does this);
repository-save failure → delete Keychain item AND copied file (use
case does this); any failure → throw the original typed error, log via
AppLogger (no secret in the message). No orphan file, orphan Keychain
item, or orphan record may remain — pinned by tests (§D).

**Init-injection decision (coordinator, 2026-11-28 — Wave 2, recorded
by the final integration worker; supersedes the `(engine, repository,
logger)` shapes §B.10 originally listed):** the repository-save
rollback above is impossible without the handles that perform it, so
the import use cases inject them as required dependencies:
`ImportCertificateUseCase` takes `keychain` + `fileSystem` (it must
delete the Keychain item AND the copied file on rollback), and
`ImportProvisioningProfileUseCase` takes `fileSystem` (it must delete
the copied file on rollback). The pattern matches the delete use cases
already in this section (`DeleteCertificateUseCase` injects
`keychain` + `fileSystem`; `DeleteProvisioningProfileUseCase` injects
`fileSystem`), and the same handles are the ones `DependencyContainer`
already owns — no new construction, no hidden singleton. All test call
sites were updated to the new inits (Wave 2 final integration).
**Delete order (W-6):** delete repository record → delete file →
delete Keychain item; collect each step's failure; throw
`AppError.storage(.deleteFailed(reason:))` naming the failed step(s)
if any step fails; the UI dismisses / calls back ONLY when all steps
succeed. The old `try?`-and-dismiss behaviour is forbidden.
**UDID:** `DeviceUDIDValidator.validate(_:)` — exactly 40 hex chars
`[a-fA-F0-9]{40}`, either case; `normalized(_:)` uppercases.
`DeviceUDIDStore` (UserDefaults key `ksign.deviceUDID`, `@Published
savedUDID`) is carried over verbatim from the verified file. A missing
UDID is not an error — coverage UI shows "paste UDID to check coverage".

### B.11 Manual-renewal UX (§5) — countdown, banners, re-import

- Countdown: every certificate/profile row and detail shows
  `expirationDate` + `daysUntilExpiration` + `ExpiryBand` colour
  (green >7 days, orange 1–7 days, red ≤24h / expired). No expiry date
  → text "no expiry date", never a fake countdown.
- Banners (Dashboard, persistent while the condition holds): ≤3 days —
  "Profile [name] expires in N days — import a new one soon" → opens
  Certificates manager; ≤24h — "Expires today — import now" (urgent
  style); expired — "Expired — apps signed with it may stop working"
  → opens Certificates manager.
- Re-import (Phase 1 ships this): from a banner or from profile detail,
  "Import new profile" opens the document picker; the new profile is
  validated immediately (CMS valid? already expired? team matches the
  stored certificate? bundle-ID coverage? device coverage via pasted
  UDID?) and any failure stops the flow with the specific message.
- Re-sign itself is Phase 2/4 (`ReSignApplicationUseCase`): Phase 1
  does NOT ship a re-sign button that does nothing. The detail screen
  shows the stored profile and the re-import action only.
- Local notifications (7 days / 1 day / expiry day) are NOT Phase 1
  (no notification UI, no background-task registration for renewal).
- If a profile expires between validation and a later signing, the
  signing engine re-checks expiry immediately before signing and
  aborts with an explicit error (Phase 2 rule, recorded here so Wave 2
  does not design a Phase 1 flow that assumes otherwise).

---

## C. Navigation contract — 6 tabs + side menu + HUD + deep links + Open-In

> **CORRECTION 2026-11-28 15:00 + 15:01 (user orders, override the 5-tab design above):** 6 bottom tabs — Dashboard, Applications, Sources, Downloads, Files, Settings. Sources and Downloads are independent visible tabs (the "Store" tab is dissolved: source management → Sources, feed browsing + direct download → Applications, queue → Downloads). Certificates live in the **side menu** (§10.3أ), not in Settings. The tab list and the exception below are updated accordingly; everything else in §C stands.

### C.1 Screen inventory (§10.10 check per row)

`Engine` = the engine/use case that supplies the live data. A row that
fails the check is CUT, not shipped. Applications, Sources and Downloads
are the binding exceptions (below).

| Screen | Purpose | Actions (all work in Phase 1) | Live data (engine) | Next destination | §10.10 |
|---|---|---|---|---|---|
| Dashboard (tab root) | System health + expiry + recent activity | Refresh; tap banner → Certificates; tap activity row → Diagnostics; tap empty-state Import → picker | Expiry via FetchExpiringProfilesUseCase; activity via AppLogger; counts via repositories | Certificates manager; Diagnostics; import sheet | PASS |
| Applications (tab root) | **EXCEPTION — honest empty state** | None. Single line: "Your apps arrive in Phase 3 — direct downloads from sources — and the locker in Phase 4." No buttons, no fake actions | None (engines land Phases 3–4) | None | **DOCUMENTED EXCEPTION** to §10.10, to be closed in Phases 3–4 |
| Sources (tab root) | **EXCEPTION — honest empty state** | None. Single line: "Sources arrive in Phase 3 — repositories, feeds and direct downloads." No buttons, no fake actions | None (engines land Phase 3) | None | **DOCUMENTED EXCEPTION** to §10.10, to be closed in Phase 3 |
| Downloads (tab root) | **EXCEPTION — honest empty state** | None. Single line: "Downloads arrive in Phase 3 — the queue lives here." No buttons, no fake actions | None (engines land Phase 3) | None | **DOCUMENTED EXCEPTION** to §10.10, to be closed in Phase 3 |
| Files (tab root) | Browse the app sandbox | Navigate into subfolders; create folder; import file; share; rename; delete; tap file per §C.4 | FileSystemManager.listDirectory | Subfolder (same view, pushed); share sheet; side-menu Certificates import flow | PASS |
| Files subfolder | Same browser, one level deeper | Same as Files | FileSystemManager | Parent / deeper folder / share sheet | PASS |
| Settings (tab root) | Configure + diagnose | Tap row → sub-screen (all real, §C.5) | FileSystemManager (storage), AppLogger (diagnostics) | Storage, Diagnostics, About | PASS |
| Certificates manager (from the side menu — user order 2026-11-28 15:01) | Lifecycle of P12s + profiles | Import (.p12/.mobileprovision); tap row → detail; swipe delete | ImportCertificateUseCase, ImportProvisioningProfileUseCase, repositories | Certificate detail; document picker; password sheet | PASS |
| Certificate / profile detail | Inspect one identity/profile | Delete (with per-step errors); paste UDID + check coverage (profiles); re-import new profile (§B.11) | CertificateEngine / ProvisioningEngine; DeviceUDIDStore | Back to manager; document picker | PASS |
| P12 password sheet | Supply transient P12 password | Type password; Validate; Import; Cancel (clears password + pending URL) | CertificateEngine.parseP12 | Manager (on success) | PASS |
| Storage (from Settings) | Storage info + reclaim | Purge temp (cleanupStaleTempDirectories); refresh | FileSystemManager.freeSpaceBytes + folder sizes | — (refreshes in place) | PASS |
| Diagnostics (from Settings) | Live log stream | Search; export (text/JSON file via share sheet); clear (failure surfaced, W-19) | AppLogger (single source) | Share sheet | PASS |
| About (from Settings) | App info + diagnostics summary | Copy diagnostics summary | Bundle metadata + AppLogger counts | — | PASS |

CUT in Phase 1 (do not build): signing wizard, install-server control,
advanced-tools bench, locker views, sources/downloads views, plist/hex/
text editors, Quick Look preview, version-history screens. Any screen
proposed later must pass this same table first.
Depth note (user order 2026-11-28 14:40 — nothing superficial): the
Phase 1 depth comes from Files (unbounded folder recursion, as in the
reference) + Certificates (manager → detail → coverage/re-import) +
Dashboard (banner → manager → detail). No screen is a static
information page: About's only content is live metadata + an action;
Diagnostics is a live stream, not a log dump.

### C.2 Dashboard (Phase 1)

- **Expiry card:** profiles sorted by nearest expiry (expired first),
  each row: name, UUID (short), team, "expires in N days" in band
  colour. Tapping a row opens that profile's detail. Empty (no
  profiles): card shows "No profiles imported" + a real **Import**
  button opening the document picker.
- **Banners:** persistent while the condition holds (§B.11); tap →
  Certificates manager.
- **Recent activity:** last 10 entries from `AppLogger.allEntries()`
  (imports, parses, deletions, Keychain writes — never secrets).
  Tapping a row opens Diagnostics. A log-read failure is shown as an
  error row, never as an empty list (W-4/W-14).
- **Counts:** certificates count, profiles count, free-space bytes.
  Tapping counts opens Certificates manager / Storage respectively.
- Rejected Gemini element: a "primary active identity" health card —
  there is no active-identity concept in Phase 1 (no selection model);
  the expiry card above replaces it. Rejected Gemini destination
  "File Details" — no such screen exists in Phase 1.

### C.3 Certificates manager + detail (Phase 1)

- **Layout:** two sections — "Identities (.p12)" and "Profiles
  (.mobileprovision)". Row (identity): name, team, expiry countdown
  pill (band colour), status pill (valid/expired/stored). Row
  (profile): name, team, App ID bundle part, expiry countdown pill,
  UDID-coverage state (covered / not covered / "paste UDID to check").
- **Import flow:** `+` → document picker (`.p12`, `.mobileprovision`).
  P12 → password sheet (secure field; empty password allowed and
  means "password-less" — it still registers, W-3; Validate runs
  `parseP12` in-memory first; Import consumes the password, clears it
  from memory, then runs the use case). Profile → immediate engine
  validation; an already-expired profile is rejected at once with
  `provisioningExpired` and no file is copied. Any failure shows the
  specific typed message; the list refreshes on success.
- **Detail (identity):** issuer, subject CN, serial (hex), SHA-256
  fingerprint, team, kind, status, expiry + countdown, file name,
  Keychain state ("password stored in Keychain" / "no password
  stored"). Delete button.
- **Detail (profile):** name, UUID, team, App ID, kind, expiry +
  countdown, creation date, entitlements list (key = value, sorted),
  provisioned-devices count + list, embedded-certificate fingerprints,
  data hash, file name. **Device coverage section:** pasted-UDID field
  (via `DeviceUDIDStore`; 40-hex validation with the exact error
  message) + "Check coverage" → covered / not covered for THIS profile
  (exact `contains`); App Store profiles show "no device list — this
  profile type does not restrict devices" (not a fake `true`). No UDID
  pasted → "Paste a UDID to check coverage" (not an error).
  Re-import button ("Import new profile", §B.11). Delete button.
- **Delete flow:** confirmation alert → use case (§B.10) → on any
  step failure an alert names the failed step; the view dismisses
  only when all steps succeed (W-6). No `try?`-and-dismiss anywhere.

### C.4 Files browser (Phase 1)

- **Root:** workspace root `Documents/KsignNext`. Visible folders:
  `Imported`, `Signed`, `Certificates`, `Downloads`, `Temp`,
  `Tweaks`, `Inbox`. (Empty folders are shown — they are real
  workspace folders, not fake entries.)
- **Actions:** navigate into subfolders (recursive push, unbounded);
  create folder (name-entry dialog); import file (document picker →
  copy into current folder); share (system share sheet); rename
  (name-entry dialog); delete (confirmation; failure surfaced).
  A directory-read failure shows an error row, never an empty list
  (W-11).
- **Tap behaviour per extension (Phase 1 — no fake editors, no
  dead-end "unsupported" alerts, blueprint §10.9):**
  - `.p12` / `.mobileprovision` → Certificates import flow (§C.3),
    routed via the coordinator (same as Open-In).
  - `.ipa` / `.tipa` → action sheet: Share / Rename / Delete. No
    import action — the locker import path is a Phase 3 stub (§C.6).
    The file is NOT opened, NOT parsed, NOT previewed in Phase 1.
  - `.txt` / `.plist` / any other file → action sheet: Share / Rename
    / Delete. (Editors are Phase 3. Rejected Gemini's "tap opens the
    share sheet directly" — the sheet must offer Rename and Delete too,
    and the share sheet itself cannot rename, so a direct share-sheet
    tap would hide two working actions.)
  - Legacy/unknown formats (incl. the old certificate-container
    format): treated like any other file — Share / Rename / Delete.
    No "unsupported" alert, no migration tool (blueprint §10.9).
- **Open-In routing into Files:** files copied into `Inbox` appear
  here immediately (coordinator bumps a refresh token).

### C.5 Settings (Phase 1)

Every row is a real action. Deferred sections are **absent entirely**
— no disabled toggles, no ghost keys, no "coming soon" rows (the
reference's unrendered Library-row-style setting is the anti-pattern).

| Section / row | Action |
|---|---|
| Storage usage | → Storage view: per-folder bytes (live), free space, "Purge temp" (runs `cleanupStaleTempDirectories`, reports bytes freed or "nothing to purge") |
| Diagnostic logs | → Diagnostics view (§C.1) |
| About | → About view: app name, version, build, bundle ID; "Copy diagnostics summary" (version/build/counts/free space) |
| (deferred, absent) | Installation server control (Phase 2), advanced-tools bench (Phase 4), engine preferences (Phase 5), signing options (Phase 2) |

Rejected Gemini additions: Diagnostics export as `.zip` (old export is
a text/JSON file via share sheet — keep that); About "design system
specs" (not user-facing content — cut).

### C.6 AppCoordinator — single central router [VERIFIED]

Replaces the old coordinator (which had 11 tabs, the `ksign://`
scheme, and the W-1 Inbox dead end — all fixed here). The old
`pendingP12ImportURL` / `certificatesChangedToken` bridge pattern is
kept in spirit: the coordinator publishes import state and the
Certificates view observes it — but the routing itself is rewritten
to the 6-tab + side-menu design.

```swift
@MainActor
final class AppCoordinator: ObservableObject {
    enum AppTab: String, CaseIterable, Identifiable {
        case dashboard, applications, sources, downloads, files, settings
        var id: String { rawValue }
    }
    enum SheetDestination: Identifiable {
        case p12PasswordPrompt(URL)
        case diagnostics
        // (certificate detail is a push, not a sheet — see below)
    }
    let container: DependencyContainer
    init(container: DependencyContainer = DependencyContainer())
    @Published var selectedTab: AppTab = .dashboard
    @Published var sideMenuOpen = false          // side menu (§10.3أ) — owned here, openable from any tab
    @Published var path = NavigationPath()          // per-tab push state, owned here — not scattered in parents
    @Published var presentedSheet: SheetDestination?
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var pendingP12ImportURL: URL?
    @Published var certificatesChangedToken = UUID()
    @Published var filesChangedToken = UUID()

    func selectTab(_ tab: AppTab)
    func openSideMenu() / func closeSideMenu()
    func openCertificatesManager()   // opens side menu → Certificates manager
    func loadPersistence() async   // failure → error alert, never a crash
    func handleOpenURL(_ url: URL)
    func handleIncomingFile(_ url: URL)
    func importIncomingFile(_ item: IncomingFile)
}
```

- **Deep links (`ksignnext://` only):** `ksignnext://source/add?url=…`
  → select Sources tab (whose empty state honestly says sources
  arrive in Phase 3) + an alert stating repository adding arrives
  in Phase 3. `ksignnext://install/remote?url=…` → select Downloads
  tab + an alert stating downloads arrive in Phase 3.
  `ksignnext://certificates` → open side menu → Certificates
  manager. Unknown scheme/host, malformed URL, missing `url`
  parameter → error alert with the specific reason (never a silent
  drop — the old `guard … else { return }` pattern is forbidden).
  No `ksign://` handling (that scheme belongs to the reference app;
  using it would collide if both apps are installed).
- **Open-In routing (W-1 fix — the file must land somewhere real):**
  security-scoped access is started/stopped correctly; missing file →
  error alert. `.p12` → copy to `Certificates/`, publish
  `pendingP12ImportURL`, open side menu → Certificates manager,
  open the password sheet. `.mobileprovision` → run
  `ImportProvisioningProfileUseCase`, bump
  `certificatesChangedToken`, open side menu → Certificates manager.
  `.ipa` / `.tipa` → copy into workspace `Inbox/` (stub for the
  Phase 3 locker import path), bump `filesChangedToken`, select Files
  tab. Any other extension → copy into `Inbox/`, bump
  `filesChangedToken`, select Files tab (blueprint §10.9: unknown
  files are ordinary files — no "unsupported" alert). Every copy
  failure surfaces in the error alert; the sheet state is cleared in
  all cases.
- Rejected Gemini coordinator code (§E): it invented
  `ProvisioningEngine.shared`, `FileSystemManager.shared
  .stageIncomingBinary/from`, `importGenericFile`, and deep-link hosts
  (`certificates`, `files`) that contradict blueprint §10.7. None of
  those members exist in this contract.

### C.7 Global progress HUD (Phase 1)

Ship the HUD container in Phase 1, hidden until work exists (adopted
from Gemini — the structure is cheap and later phases reuse it).
State is driven by `TaskRegistry` (Core): tasks register with a label
and progress; the HUD shows the first active task (label + percentage
+ cancel) and a "+N more" counter; tapping expands a drawer listing
every task with per-task cancel; tapping task text navigates to the
task's screen without interrupting it. Phase 1 task types: certificate
and profile imports (fast; the HUD appears only while one is actually
running). No fake tasks, no simulated progress. `TaskRegistry` API:

```swift
public final class TaskRegistry: ObservableObject {
    public struct TaskItem: Identifiable, Sendable {
        public let id: UUID; public let label: String
        public var progress: Double?   // nil = indeterminate
        public let destination: TaskDestination
    }
    public enum TaskDestination: Sendable { case certificates, files, dashboard }
    @Published public private(set) var tasks: [TaskItem]
    public func register(label: String, destination: TaskDestination) -> UUID
    public func update(id: UUID, progress: Double?) 
    public func cancel(id: UUID)
    public func finish(id: UUID)
}
```

### C.8 Accessibility + localisation (Phase 1 rules)

- Every interactive control, status pill and countdown has an explicit
  `.accessibilityLabel` (+ `.accessibilityHint` where the action is not
  obvious). Countdowns announce semantic time ("Expires in 3 days"),
  never raw numbers. Dynamic Type: native SwiftUI fonts only; no
  fixed-size custom fonts. Minimum touch target 44pt.
- Every user-facing string exists in BOTH `en` and `ar` strings files.
  CI enforces key-count parity (a script fails the build if the two
  files' key counts differ). Fallback rule (adopted from Gemini): a
  missing key at runtime falls back to the English string and logs a
  warning to `AppLogger` — it never renders a raw key.
- No string mentions another app or tool. The signing backend is
  "the signing backend" in the one place Phase 1 needs to name it
  (an error message), never by library name.

---

## D. Test plan

### D.1 Count rule (binding, B-J1 corrected)

The strict judge parses the canonical `Executed N tests, with M failures`
summary, fails if no summary exists, and fails unless N equals the count
computed from source **excluding UITests** and M == 0. Count command
(verified from deep-dive B-J1 — Gemini's `Tests/UnitTests/`-only scope
was wrong because `Tests/` also holds Integration/Performance/Security
suites whose methods count):

```sh
N=$(grep -rh "func test" Tests/ --exclude-dir=UITests | wc -l)
```

Do NOT also require a `TEST SUCCEEDED` string (a run killed at teardown
after printing the summary would fail spuriously — B-J1). Keep
`-disable-concurrent-testing` (rejected Gemini's `-parallel-testing-enabled
YES` — the workflow deliberately disables concurrent testing for a
deterministic count). Rejected Gemini's `-test-timeouts-enabled YES` —
unverified flag, do not add without verifying it exists in the pinned
Xcode version. Simulator prep is its own step with its own timeout
(B-J2) so boot time cannot starve the test run.

**Phase 1 total: N = 115** (sum of the complete method lists below).
Wave 2 must implement every listed method; adding a test requires
updating this list in the same change (the count is computed from
source, so the doc and the code must agree).

### D.2 Test file list + methods (complete)

**`Tests/UnitTests/Core/AppLoggerTests.swift` (10)**
`testSingleSource_twoReadersSeeIdenticalEntries` (W-4 regression: two
readers, same entries and counts) · `testRingBuffer_capsAt1000` ·
`testRedactsPasswordKeyInMessage` · `testRedactsTokenInMetadata` ·
`testPersistAndLoad_roundTrip` · `testExportJSON_roundTrip` ·
`testExportText_containsEntries` · `testClear_removesMemoryAndFile` ·
`testEntriesFilteredByLevel` · `testEntriesForOperation`

**`Tests/UnitTests/Core/AppErrorTests.swift` (6)**
`testCertificate_wrongPasswordMessage` ·
`testCertificate_expiredMessageContainsDate` ·
`testStorage_notFoundMessage` · `testValidation_invalidUDIDMessage` ·
`testCancelledDescription` · `testUnknownPreservesUnderlying`

**`Tests/UnitTests/Core/FileSystemManagerTests.swift` (8)**
`testWriteAtomically_roundTrip` · `testWriteAtomically_rejectsPathTraversal`
· `testValidatedURL_rejectsEscapingSymlink` ·
`testListDirectory_throwsOnMissing` ·
`testCreateTempDirectory_insideWorkspaceTemp` ·
`testCleanupStaleTempDirectories_removesOldKeepsNew` ·
`testFreeSpaceBytes_returnsValueOrNil` · `testMove_replacesDestination`

**`Tests/UnitTests/Core/KeychainServiceTests.swift` (8)**
`testSaveReadDeletePassword_roundTrip` ·
`testReadPassword_missingReturnsNil` · `testDelete_missingSucceeds` ·
`testSave_overwritesExisting` · `testSaveReadDeleteData_roundTrip` ·
`testRead_missingDataReturnsNil` ·
`testExists_trueAfterSaveFalseAfterDelete` ·
`testIsolatedService_doesNotTouchProductionService` (separate service
name for tests — adopted from Gemini; tests never touch the production
Keychain namespace)

**`Tests/UnitTests/Core/HTTPClientTests.swift` (4)**
`testConfiguration_defaultsAre30And300` ·
`testSend_rejectsNonHTTPS` · `testSend_mapsTimeoutToNetworkTimeout`
(stub URLSession) · `testSend_rejectsNon2xxAsHTTPStatus`

**`Tests/UnitTests/Engines/CertificateEngineTests.swift` (12)**
`testParseP12_validReturnsModelWithFingerprintAndTeam` (fingerprint =
SHA-256 of DER; teamIdentifier = OU; kind from CN) ·
`testParseP12_wrongPasswordThrowsWrongPassword` (exact
`AppError.certificate(.wrongPassword)`) ·
`testParseP12_corruptThrowsInvalidFormat` ·
`testParseP12_passwordlessSucceedsAndRegisters` (W-3: `keychainAccount`
set, repository save succeeds) ·
`testParseP12_missingPrivateKeyThrows` (exact `.missingPrivateKey`) ·
`testParseP12_oversizedThrowsInvalidFormat` (>10 MiB) ·
`testParseCertificate_pemParses` ·
`testDerOID_largeArcDoesNotTrap` (R-M1: synthetic DER with an OID arc
> Int.max/128 continuation bytes; parses without trapping; the
oversized arc yields `nil` for that attribute, not a crash) ·
`testStatus_valid` · `testStatus_expired` ·
`testStatus_notYetValidReturnsInvalid` (future `notBefore` → `.invalid`,
NOT `.notYetValid` — this corrects Gemini, which asserted the wrong
case against the verified `status()`) ·
`testStatus_neverReturnsRevoked` (`.revoked` is never returned)

**`Tests/UnitTests/Engines/ProvisioningEngineTests.swift` (15)**
`testParse_validProfileReturnsAllFields` (name/uuid/team/appIdentifier/
kind/expiry/devices/entitlements/certificates) ·
`testParse_corruptCMSThrowsProvisioningInvalid` (no `<?xml` span) ·
`testParse_missingMandatoryFieldsThrows` (Name / UUID / TeamIdentifier
each missing, in sub-cases) ·
`testParse_expiredProfileSucceeds` (parse does NOT reject expiry —
only import does) ·
`testImport_expiredProfileThrowsProvisioningExpired` (exact case;
no file copied — asserted by the use-case test too) ·
`testValidatePair_teamMismatchThrowsProvisioningMismatch` ·
`testValidatePair_certNotListedThrowsProvisioningMismatch` ·
`testAllows_exactMatch` · `testAllows_wildcardMatch`
(`com.example.foo` vs `com.example.*` → true) ·
`testAllows_wildcardDoesNotMatchPrefixSibling` (`com.exampleFoo` →
false; `com.example` → false) · `testAllows_universalWildcard` (`*` →
true) · `testDeviceIsProvisioned_listedAndUnlisted` ·
`testKindHeuristic_matrix` (provisionsAllDevices → enterprise; no
devices → appStore; get-task-allow → development; else adhoc) ·
`testImport_oversizedThrowsProvisioningInvalid` (>5 MiB) ·
`testParse_plistStringContainingPlistEndTag` (regression for the §B.9
last-`</plist>` hardening: a string value containing `</plist>` must
not truncate the document)

**`Tests/UnitTests/Engines/ArchiveEngineTests.swift` (20 — Wave 2, deflate-fix regression suite, M10 fix)**
`testInflateRawDeflate_roundTripByteIdentical` (100,000 bytes — output
spans two 64 KiB chunks, so it catches a Z_FINISH-on-every-call bug) ·
`testInflateRawDeflate_emptyInputReturnsEmpty` ·
`testDeflateRaw_emptyProducesEmptyStoredBlock` ·
`testInflateRawDeflate_corruptInputThrowsCorruptZIP` (negative control:
flipped mid-stream bytes) ·
`testInflateRawDeflate_truncatedInputThrowsCorruptZIP` (negative control:
stream cut in half) ·
`testInflateRawDeflate_negativeExpectedSizeThrowsInvalidZIP` (R-H2, exact
case) · `testInflateRawDeflate_oversizedExpectedSizeThrowsSizeLimitExceeded`
(exact case) · `testZStreamLayoutIs112Bytes` (pins the `CZlib.ZStream`
C layout the `@_silgen_name` bridge depends on) ·
`testMinimalIPA_method8InfoPlistExtracts` (committed fixture, method 8,
byte-for-byte incl. CRC 0xd3d4f4f4) ·
`testMinimalIPA_storedEntryControl` (same fixture, method 0) ·
`testCreateArchive_deflatedRoundTrip` (in-memory create → read back) ·
`testStoredEntry_nonEmptyRoundTrip` ·
`testCRC32MismatchRejected` (valid deflate, wrong central-directory CRC) ·
`testOversizedEntryRejected` (declared size > 1 GiB cap, exact case) ·
`testZip64SentinelRejected` (0xFFFFFFFF sizes → exact
`.invalidZIP("ZIP64 archives are not supported.")`) ·
`testGunzip_roundTrip` (plain + FNAME-header variants) ·
`testGunzip_rejectsBadTrailerCRC` · `testGunzip_rejectsNonGzip` ·
`testEntryNameSafety` (unsafe names + `safeDestination`) ·
`testExtractAll_symlinkMaterialisedAsRegularFile` (M11: symlink entry
becomes a regular file holding the target string, no link created)

**`Tests/UnitTests/Repositories/CertificateRepositoryTests.swift` (6)**
`testSaveFetch_roundTrip` · `testFetch_missingReturnsNil` ·
`testFetchByFingerprint` · `testSave_upsertsById` ·
`testDelete_removesRecord` ·
`testDelete_missingThrowsNotFound` (exact
`AppError.storage(.notFound(id:))` — verified old behaviour)

**`Tests/UnitTests/Repositories/ProvisioningProfileRepositoryTests.swift` (6)**
Same six, with `testFetchByUUID` in place of `testFetchByFingerprint`.

**`Tests/UnitTests/UseCases/ImportCertificateUseCaseTests.swift` (5)**
`testExecute_successCopiesFileWritesKeychainSavesRecord` ·
`testExecute_wrongPasswordWritesNothing` (no file, no Keychain item,
no record) · `testExecute_keychainFailureRemovesCopiedFileAndRecord`
(rollback) · `testExecute_repositoryFailureRemovesKeychainAndFile`
(rollback) · `testExecute_passwordlessRegisters` (W-3 regression)

**`Tests/UnitTests/UseCases/ImportProvisioningProfileUseCaseTests.swift` (5)**
`testExecute_successCopiesFileAndSavesRecord` ·
`testExecute_expiredRejectsBeforeAnyCopy` ·
`testExecute_corruptWritesNothing` ·
`testExecute_repositoryFailureRemovesFile` ·
`testExecute_reimportSameUUIDUpserts` (same profile UUID → one record)

**`Tests/UnitTests/ViewModels/DashboardViewModelTests.swift` (4)**
`testExpiringProfiles_sortedNearestFirstViaEngine` (W-2 regression:
expiry comes from the engine, never raw plist) ·
`testActivity_readsFromAppLoggerSingleSource` (W-4 regression) ·
`testRefresh_surfacesReadError` (no dead alert — an error must be
observable) · `testEmptyState_reportsZeroCounts`

**`Tests/UnitTests/ViewModels/CertificatesViewModelTests.swift` (6)**
`testImportP12_successRefreshesList` ·
`testImportP12_passwordClearedAfterConsumption` ·
`testImportProfile_expiredShowsError` ·
`testDelete_successRemovesFileRecordAndKeychain` ·
`testDelete_keychainFailureSurfacesErrorAndKeepsRow` (W-6 regression) ·
`testRefresh_surfacesDirectoryReadError`

**Total: 10+6+8+8+4+12+15+20+6+6+5+5+4+6 = 115.**

### D.3 What is NOT tested in Phase 1 (deferred — blueprint §7 mapping)

- Phase 2: SigningEngine + VerificationEngine (incl. MachO, zsign
  adapter, cancellation R-M5, atomic writes M3, post-sign verification),
  InstallationEngine + TLSIdentityService (loopback HTTP + LAN HTTPS,
  Bouncer/BLK1), ReSignApplicationUseCase, live signing with the user's
  real certificate (BLK2).
- Phase 3: SourcesEngine (tolerant decoding SRC-1/2/3), DownloadEngine,
  Files editors (plist/hex/text), tweaks/injection, ImportIPAUseCase.
- Phase 4: DigitalLockerEntry + ManageDigitalLockerUseCase, the 5
  advanced tools (Manifest Maestro, Background Bouncer, Injection Lab,
  Entitlement Explorer, Configuration Blueprints).
- Phase 5: full accessibility audit, ar/en parity enforcement in CI,
  final polish.
(Gemini's deferred-phase mapping was wrong — it put the install server
in Phase 3 and sources in Phase 4; the mapping above is the blueprint's.)

### D.4 Test infrastructure Wave 2 must create (Phase 1, reusable)

- `Tests/Support/FixtureBuilder.swift`: synthetic DER builder (incl.
  the R-M1 large-arc OID), synthetic CMS/profile builder (plist →
  wrapped bytes), P12/profile fixture loading from `Tests/Fixtures/`.
- `Tests/Fixtures/` + `README.md`: fixtures generated on a Mac with
  `openssl` (self-signed test identity, throwaway password `test123`
  documented in the README — test-only, no real Apple material).
  Correction to Gemini: `SecKeyGeneratePair` + `SecPKCS12Import`
  cannot generate a P12 (Import imports; Export needs an existing
  identity + certificate, and there is no public API to mint a
  self-signed certificate) — committed openssl-generated fixtures are
  the way; synthetic DER covers the OID case without a real cert.
- `InMemoryCoreDataStack` (`NSInMemoryStoreType`) for repository tests.
- `FakeCertificateEngine` / `FakeProvisioningEngine` (protocol-based,
  deterministic) for use-case tests.
- `KeychainTestService`: `KeychainService(service: "com.ksignnext.app.tests")`
  so tests never touch the production namespace.
- Core Data failure injection: in-memory container pointed at an
  invalid store URL / read-only configuration; repositories must map
  the failure to `AppError.storage` (asserted, not just "throws").

### D.5 Error-assertion rule

Every throwing test asserts the EXACT error case
(`XCTAssertThrowsError` + case match), never just "throws".
Cancellation is rethrown unwrapped, never wrapped as a generic error
(R-M4 pattern — applies to any cancellable Phase 1 work).

---

## E. Risks / blockers / Gemini verdicts

### E.1 Risks and unverified items

1. **Reference snapshot timing:** the parallel surgery agent deleted
   `Domain/Protocols/`, `Domain/UseCases/` and all but one file of
   `Data/Repositories/` from the live tree during this task. The
   reference snapshot `~/workspace/ksign-next-rebuild-reference/`
   appeared mid-task; concrete repository semantics (upsert-by-id,
   delete-missing → `StorageError.notFound`) were verified from it,
   but Wave 2 must re-verify every "carried over" behaviour against
   that snapshot at build start, not against the live tree.
2. **P12 fixtures need a Mac:** no P12 fixture exists in the repo.
   Wave 2 must generate one with `openssl` on a Mac and commit it
   under `Tests/Fixtures/` (throwaway password documented). Until
   that lands, the 5 P12 engine tests cannot run — this is the only
   Phase 1 test dependency on an external step.
3. **CMS last-`</plist>` hardening** (§B.9) is a reasoned change over
   verified behaviour, not itself verified against a real profile:
   it is pinned by `testParse_plistStringContainingPlistEndTag` and
   must pass against a real profile fixture before the phase is
   declared done.
4. **CI open items carried from B-J1:** exact xcodebuild log casing
   and the precise stall mechanism still need the next run's
   `test.log`; the strict judge sidesteps both, but Wave 2 must keep
   the judge exactly as specified in §D.1.
5. **No live profile/certificate available to Wave 1:** all expiry,
   team and coverage behaviour is specified from code, not from a
   live import. The first live import (user's real P12 + profile)
   is a Phase 1 acceptance check Wave 2 must do with the user.
6. **Gemini model:** `gemini-2.5-flash` was 429-blocked; all 5 passes
   ran on `gemini-3.5-flash-lite`. Answers were shorter and contained
   more errors than the earlier `2.5-flash` audits (see §E.2) — the
   verification pass mattered more than usual.

### E.2 Gemini verdicts — adopted vs rejected

**Adopted (verified against source/docs):**
- Core: keep nested-enum `AppError` shape; single actor logger with
  1000/10000 caps + secret redaction; one-shot persist-retry flag
  (also required by W-20); `Data.write(.atomic)` for standard
  replacement, `replaceItemAt` only for strict descriptor coordination.
- Domain/Data: decoupled plain structs + Core Data + mappers in Data;
  upsert-by-id repositories; UDID in UserDefaults (matches verified
  `DeviceUDIDStore`); rollback ordering parse → copy → Keychain →
  record.
- Engines: engine-enforced size limits; password-less P12 must
  succeed and register; first identity wins; validatePair excludes
  bundle/device coverage (Phase 2 signing-time); DER length/first-arc/
  serial audit safe; fixture matrix (valid/wrong-password/corrupt/
  password-less/expired/enterprise/development/App-Store/large-arc OID).
- UI: 5-tab screen inventory with the Library/Store exception rows;
  HUD ships hidden-until-work; deferred Settings sections absent
  entirely; ar/en fallback to English + AppLogger warning; VoiceOver/
  Dynamic Type rules.
- Tests: per-file counts as a starting point (completed to full method
  lists in §D); Keychain test-service isolation; in-memory Core Data
  stack; fake engines; strict-judge steps (count → run → parse
  summary → compare); sim prep as a separate step (B-J2).

**Rejected (with reason — Wave 2 must NOT reintroduce these):**
- Core: rewritten `AppError` (dropped `.signing`, `.cancelled`,
  `.unknown(underlying:)`; dropped `notYetValid`/`unsupportedType`
  payloads; invented `StorageError`/`NetworkError` shapes) — the
  verified file stays verbatim. Rewritten `KeychainService` (`read`
  throws on not-found; unconditional `SecItemDelete` before save;
  nonexistent `AppError.CertificateError`) — verified API stays.
  `FileSystemManager` as actor with root `KsignWorkspace`,
  string-`hasPrefix` path check, `.completeFileProtection` on writes,
  system-tmp temp dirs, throwing `freeSpaceBytes` — verified
  `SecureFileManager` semantics stay. "Defer HTTPClient to Phase 2" —
  blueprint §1 requires it in Core. HTTPClient snippet with the
  `response asckelHttpResponse` typo, no HTTPS guard, no redirect cap.
  `AppLogger` as `@globalActor` + class (odd shape; plain actor
  matches verified `LogsManager`).
- Domain/Data: `daysUntilExpiration` snippet with a stray `day`
  token (does not compile). `allows()` addition `bundleID ==
  basePrefix` (lets `com.example` match `com.example.*` — contradicts
  verified semantics). `bundleIdentifier` via `split(maxSplits: 1)`
  (loses the team-prefix rule). "Validate password non-empty before
  recording" (§6b) — reintroduces W-3; password-less P12s MUST
  register. `isDeviceCovered` fallback `return
  provisionedDevices.isEmpty` (an App Store profile would "cover"
  any UDID — wrong; exact `contains` only). Profile raw bytes in
  Core Data with external storage (duplicates the verified
  file-on-disk design; hides profiles from Files). Model renamed to
  `KsignNext_v1.xcdatamodeld` (churn; keep the name, add version v2).
  `save() -> Model` with `@discardableResult` (gratuitous change).
  Invented `StorageError` cases (`entityNotFound`, `duplicateEntry`,
  …) contradicting the verified enum. `keychainReferenceID` as a
  second stored field alongside `keychainAccount` (redundant — the
  UUID in the account string IS the reference; see §B.6).
- Engines: actor protocols, typed `throws(AppError)`, invented
  `ParsedIdentity`/`StoredCertificate` types (churn vs verified API).
  R-M1 cap at `UInt32.max` + throw (stricter than the verified
  `UInt64(Int.max)` + return-nil fix; could reject valid certs).
  `missingIdentity` case (does not exist; empty P12 is
  `.invalidFormat`). Constant `kSecImportExportPassphraseKey` (wrong
  name; verified constant is `kSecImportExportPassphrase`).
  `errSec密码错误` (garbage non-English token in the answer).
  `AppError.app(.provisioning(.invalidFormat…))` (nonexistent
  nesting; does not compile). validatePair rejecting a `nil`
  expiration date + invented cases (`.invalidProfile`,
  `.profileExpired`, `.teamMismatch`, …) — verified behaviour
  tolerates nil expiry and uses `provisioningMismatch` /
  `provisioningExpired` / `expired`. "allows/deviceIsProvisioned
  engine-only" (would delete the verified, tested model methods).
- UI: "primary active identity" health card (no such concept in
  Phase 1); "File Details" destination (no such screen); `.ipa` →
  "staging area" (invented folder; the contract is workspace
  `Inbox/` + Phase 3 stub); tap-a-file opens the share sheet directly
  (hides Rename/Delete; the share sheet cannot rename); Diagnostics
  export as `.zip` (verified export is text/JSON); About "design
  system specs" (not user-facing); coordinator code inventing
  `ProvisioningEngine.shared`, `stageIncomingBinary`,
  `importGenericFile` and deep-link hosts contradicting blueprint
  §10.7.
- Tests: error paths `AppError.provisioning(…)`,
  `AppError.keychain(…)`, `AppError.fileSystem(…)` (nonexistent —
  correct paths are `AppError.certificate(…)` /
  `AppError.storage(…)` / `AppError.ipa(…)`). `status()` returning
  `.notYetValid` for future `notBefore` (verified: `.invalid`).
  Certificate `kind` "developer/enterprise derived from CN" (wrong:
  CN maps to development/distribution/unknown; enterprise is a
  profile kind). "Expired profile throws on import/parse" (ambiguous:
  parse succeeds, import throws — specified exactly in §D.2). Count
  scope `Tests/UnitTests/` only (correct scope is `Tests/` minus
  `UITests`, B-J1). Deferred-phase mapping (install server Phase 3,
  sources Phase 4 — blueprint §7 says Phase 2 and Phase 3).
  `-parallel-testing-enabled YES` (contradicts the deliberate
  `-disable-concurrent-testing`). `-test-timeouts-enabled YES`
  (unverified flag). P12 generation via `SecKeyGeneratePair` +
  `SecPKCS12Import` (cannot mint a certificate; openssl fixtures
  required — §D.4).

### E.3 Interface decisions Wave 2 must not change without coordinator approval

1. `AppError` case set (verbatim + zero additions in Phase 1).
2. Keychain account naming `p12-password-<uuid>`; service
   `com.ksignnext.app`; `AfterFirstUnlockThisDeviceOnly`.
3. Workspace root `Documents/KsignNext` and folder names (§B.3).
4. Six tabs in order Dashboard, Applications, Sources, Downloads, Files, Settings, plus the side menu (Certificates);
   scheme `ksignnext://`; Open-In routing table (§C.6).
5. R-M1 fix form: `UInt64` accumulator, `guard value <=
   UInt64(Int.max) else { return nil }` at arc end.
6. `allows(bundleID:)` verified semantics (wildcard needs
   `prefix + "."`).
7. Repository upsert-by-id; `delete`-missing throws
   `AppError.storage(.notFound(id:))`; `fetch`-missing returns `nil`.
8. Password-less P12s are registered (W-3); import rollback order
   (§B.10).
9. Library/Store honest empty states (one line, no buttons) — the
   exception closes only when Phases 3–4 land, not by adding fake
   actions in Phase 1.
10. No other app/tool name in any visible string; signing backend
    referred to generically.

### E.4 Conflicts logged (blueprint wins)

- Gemini "defer HTTPClient" vs blueprint §1 (Core includes it) →
  blueprint wins; HTTPClient ships in Phase 1.
- Gemini "validate password non-empty" vs W-3 fix requirement →
  W-3 wins; password-less P12s register.
- Gemini `UInt32.max` OID cap vs deep-dive R-M1 verified fix →
  deep-dive wins.
- Gemini deferred-phase mapping vs blueprint §7 → blueprint wins.
- Gemini count scope vs B-J1 → B-J1 wins.
- No `.ksign` migration tool, no external-contributors guide,
  `ksignnext://` scheme, no "Enterprise Distribution Engine",
  dead-end audit as a per-phase check (§10.9) — all already settled
  by the blueprint; Gemini proposed none of these in Phase 1, and
  Wave 2 must not add them.

---

## Build log (Phase 1 — Wave 1)

- **2026-11-28 ~15:05 — Wave 1 (design contracts):** this document
  (`Documentation/Rebuild-Phase1-Design.md`) + 5 Gemini prompt/answer
  pairs (`Gemini-Rebuild-P1-{Core,Domain-Data,Engines,UI-Navigation,
  Tests}-{Prompt,Answer}-2026-11-28.txt`, model
  `gemini-3.5-flash-lite`). No repo source code written. Next: Wave 2
  implementation from §A–§D; first live import (user's real P12 +
  profile) is the Phase 1 acceptance check.

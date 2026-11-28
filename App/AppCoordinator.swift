import SwiftUI
import UniformTypeIdentifiers

/// The six bottom tabs (user order 2026-11-28 15:00). Raw values are
/// stable identifiers; they are not deep-link hosts.
enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, applications, sources, downloads, files, settings
    var id: String { rawValue }
    var titleKey: String { "tab.\(rawValue)" }
}

/// Push destinations for every tab's `NavigationStack`. The
/// coordinator owns the single shared `path`; destinations are
/// resolved here so any tab can push the manager, a detail, or a
/// Settings sub-screen.
enum AppRoute: Hashable {
    case certificateDetail(UUID)
    case profileDetail(UUID)
    case storage
    case diagnostics
    case about
}

/// A file handed to the app via Open-In / document types
/// (.ipa / .ksign / .p12 / .mobileprovision).
struct IncomingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var fileName: String { url.lastPathComponent }
    var kindDescription: String {
        switch url.pathExtension.lowercased() {
        case "ipa": return Loc.string("file.kind.ipa")
        case "ksign": return Loc.string("file.kind.ksign")
        case "p12": return Loc.string("file.kind.p12")
        case "mobileprovision": return Loc.string("file.kind.mobileprovision")
        default: return Loc.string("file.kind.unknown")
        }
    }
    static func == (lhs: IncomingFile, rhs: IncomingFile) -> Bool { lhs.id == rhs.id }
}

enum DeepLinkError: LocalizedError {
    case unsupportedScheme
    case unknownHost(String)
    case malformedURL
    case missingURLParameter
    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return Loc.string("deeplink.error.scheme")
        case .unknownHost(let host): return Loc.string("deeplink.error.host", host)
        case .malformedURL: return Loc.string("deeplink.error.malformed")
        case .missingURLParameter: return Loc.string("deeplink.error.missingUrl")
        }
    }
}

/// Single central router: 6 tabs + side menu, sheets, `ksignnext://`
/// deep links and Open-In routing (contract §C.6).
///
/// Navigation note: the contract specifies ONE `path` owned here.
/// A single path shared by six stacks would leak one tab's stack
/// into another, so `selectTab` always resets it — a tab switch
/// starts at its root. (Gemini pass 1 advised per-tab paths instead;
/// the contract wins and this reset is the mitigation. See the
/// Wave 2 build log.)
@MainActor
final class AppCoordinator: ObservableObject {
    /// The single dependency container for the app, created once at launch
    /// and shared by every tab (the views receive it from here, so the
    /// engines and use cases are built exactly once).
    let container: DependencyContainer

    /// The shared certificates view model: the manager, the side menu
    /// and the root-level P12 password sheet all observe this one
    /// instance, so an import from any entry point refreshes the same
    /// list.
    let certificatesViewModel: CertificatesViewModel

    init(container: DependencyContainer = DependencyContainer(taskRegistry: TaskRegistry())) {
        self.container = container
        self.certificatesViewModel = CertificatesViewModel(container: container)
    }

    enum SheetDestination: Identifiable {
        case p12PasswordPrompt(URL)
        case diagnostics
        var id: String {
            switch self {
            case .p12PasswordPrompt(let url): return "p12-\(url.path)"
            case .diagnostics: return "diagnostics"
            }
        }
    }

    @Published var selectedTab: AppTab = .dashboard
    @Published var sideMenuOpen = false
    @Published var path = NavigationPath()
    @Published var presentedSheet: SheetDestination?
    /// The Certificates manager is a full-screen cover (not a tab
    /// push): it is reachable from every tab and from deep links,
    /// and a cover can never be pushed twice onto a tab's stack.
    @Published var showCertificatesManager = false
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var showInfo = false
    @Published var infoMessage: String?
    /// Incoming .p12 awaiting its password (W-1). Points at the
    /// Certificates/ copy made by `handleIncomingFile`; the password
    /// sheet's import registers it and removes that plain copy.
    @Published var pendingP12ImportURL: URL?
    /// Bumped whenever the coordinator drops a file into
    /// Certificates/, so CertificatesView refreshes even when already
    /// on that screen.
    @Published var certificatesChangedToken = UUID()
    /// Bumped whenever the coordinator drops a file into Inbox/, so
    /// FilesView refreshes even when already on that tab.
    @Published var filesChangedToken = UUID()

    // MARK: - Tabs + side menu

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
        // The path is shared by all six stacks: reset it so the
        // previous tab's pushed screens never appear in this tab.
        path = NavigationPath()
        sideMenuOpen = false
    }

    func openSideMenu() { sideMenuOpen = true }
    func closeSideMenu() { sideMenuOpen = false }

    /// Opens the side menu's Certificates manager: closes the menu
    /// and presents the manager as a full-screen cover.
    func openCertificatesManager() {
        sideMenuOpen = false
        showCertificatesManager = true
    }

    // MARK: - Persistence

    /// Loads the Core Data stores once at launch. A failure is shown
    /// in the error alert instead of crashing.
    func loadPersistence() async {
        do {
            try await container.persistence.load()
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }

    // MARK: - Deep links (`ksignnext://` only)

    /// `ksignnext://source/add?url=…` → Sources tab + Phase 3 alert.
    /// `ksignnext://install/remote?url=…` → Downloads tab + Phase 3
    /// alert. `ksignnext://certificates` → side menu → manager.
    /// Unknown scheme/host, malformed URL or a missing `url`
    /// parameter → error alert with the specific reason, never a
    /// silent drop. `file://` URLs route to `handleIncomingFile`.
    /// There is no `ksign://` handling: that scheme belongs to the
    /// reference app and would collide if both apps are installed.
    func handleOpenURL(_ url: URL) {
        if url.scheme == "file" { handleIncomingFile(url); return }
        guard url.scheme == "ksignnext" else { fail(.unsupportedScheme); return }
        guard let host = url.host, !host.isEmpty else { fail(.malformedURL); return }
        switch host {
        case "source":
            guard url.pathComponents.dropFirst().first == "add" else { fail(.unknownHost(host)); return }
            guard let value = queryValue(url, name: "url"), !value.isEmpty else {
                fail(.missingURLParameter)
                return
            }
            _ = value
            selectTab(.sources)
            showInfoMessage(Loc.string("deeplink.phase3.source"))
        case "install":
            guard url.pathComponents.dropFirst().first == "remote" else { fail(.unknownHost(host)); return }
            guard let value = queryValue(url, name: "url"), !value.isEmpty else {
                fail(.missingURLParameter)
                return
            }
            _ = value
            selectTab(.downloads)
            showInfoMessage(Loc.string("deeplink.phase3.install"))
        case "certificates":
            openCertificatesManager()
        default:
            fail(.unknownHost(host))
        }
    }

    private func queryValue(_ url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - Open-In routing (W-1 fix: the file lands somewhere real)

    /// Called by `onOpenURL` for document-type opens.
    /// Security-scoped URLs (Open-In) get scoped access; plain file
    /// paths are not security-scoped, so a `false` from
    /// `startAccessingSecurityScopedResource` must not drop them —
    /// only scoped URLs are stopped again.
    func handleIncomingFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showErrorMessage(Loc.string("error.file.access"))
            return
        }
        switch url.pathExtension.lowercased() {
        case "p12":
            importIncomingP12(url)
        case "mobileprovision":
            // The import is async and needs scoped access across the
            // await, so it re-starts access inside its own Task.
            Task { await importIncomingProvision(url) }
        default:
            // .ipa / .tipa / anything else: ordinary file → Inbox/
            // (stub for the Phase 3 locker import path). No
            // "unsupported" alert (blueprint §10.9).
            importIncomingFile(IncomingFile(url: url))
        }
    }

    /// Copies the incoming file into the workspace `Inbox/` folder,
    /// bumps `filesChangedToken` and selects the Files tab. Every
    /// copy failure surfaces in the error alert.
    func importIncomingFile(_ item: IncomingFile) {
        do {
            let inbox = try container.files.folder(.inbox)
            let dest = inbox.appendingPathComponent(item.fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: item.url, to: dest)
        } catch {
            showErrorMessage(error.localizedDescription)
            return
        }
        filesChangedToken = UUID()
        selectTab(.files)
    }

    /// Copies the .p12 into `Certificates/` (so it is visible in the
    /// list), publishes it for the password sheet, opens the side
    /// menu → Certificates manager, and opens the password sheet.
    /// The sheet's import registers the certificate and removes this
    /// plain copy afterwards.
    private func importIncomingP12(_ url: URL) {
        do {
            let certsDir = try container.files.folder(.certificates)
            let dest = certsDir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            certificatesChangedToken = UUID()
            pendingP12ImportURL = dest
        } catch {
            showErrorMessage(error.localizedDescription)
            return
        }
        openCertificatesManager()
        if let pending = pendingP12ImportURL {
            presentedSheet = .p12PasswordPrompt(pending)
        }
    }

    /// Runs the profile import use case (which rejects an
    /// already-expired profile before any file copy), bumps the
    /// refresh token and opens the side menu → Certificates manager.
    private func importIncomingProvision(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let useCase = try container.makeImportProvisioningProfileUseCase()
            _ = try await useCase.execute(fileURL: url)
        } catch {
            showErrorMessage(error.localizedDescription)
            return
        }
        certificatesChangedToken = UUID()
        openCertificatesManager()
    }

    // MARK: - Alerts

    func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    func showInfoMessage(_ message: String) {
        infoMessage = message
        showInfo = true
    }

    private func fail(_ error: DeepLinkError) {
        showErrorMessage(error.localizedDescription)
    }
}

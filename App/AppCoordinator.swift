import SwiftUI
import UniformTypeIdentifiers

/// Tabs of the app. Raw values are stable for deep links (ksign://tab/<rawValue>).
enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, applications, certificates, signing, installation, tweaks, downloads, sources, files, logs, settings
    var id: String { rawValue }
    var titleKey: String { "tab.\(rawValue)" }
}

/// A file handed to the app via Open-In / document types (.ipa / .ksign / .p12 / .mobileprovision).
struct IncomingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var fileName: String { url.lastPathComponent }
    var kindDescription: String {
        switch url.pathExtension.lowercased() {
        case "ipa": return NSLocalizedString("file.kind.ipa", comment: "")
        case "ksign": return NSLocalizedString("file.kind.ksign", comment: "")
        case "p12": return NSLocalizedString("file.kind.p12", comment: "")
        case "mobileprovision": return NSLocalizedString("file.kind.mobileprovision", comment: "")
        default: return NSLocalizedString("file.kind.unknown", comment: "")
        }
    }
    static func == (lhs: IncomingFile, rhs: IncomingFile) -> Bool { lhs.id == rhs.id }
}

enum DeepLinkError: LocalizedError {
    case unsupportedScheme, unknownTab(String), malformedURL
    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return NSLocalizedString("deeplink.error.scheme", comment: "")
        case .unknownTab(let t): return String(format: NSLocalizedString("deeplink.error.tab", comment: ""), t)
        case .malformedURL: return NSLocalizedString("deeplink.error.malformed", comment: "")
        }
    }
}

/// Owns navigation state, deep links (ksign://) and incoming files.
@MainActor
final class AppCoordinator: ObservableObject {
    /// The single dependency container for the app, created once at launch
    /// and shared by every tab (the views receive it from here, so the
    /// engines and use cases are built exactly once).
    let container: DependencyContainer

    init(container: DependencyContainer = DependencyContainer()) {
        self.container = container
    }

    @Published var selectedTab: AppTab = .dashboard
    @Published var pendingFileOpen: IncomingFile?
    @Published var showDeepLinkError = false
    @Published var deepLinkError: String?
    /// Inbox copy of an incoming .p12 awaiting its password (W-1).
    /// CertificatesView bridges this into its view model and opens
    /// the password sheet. It points at the Inbox copy, never at the
    /// Certificates/ copy: `importFile` deletes its destination
    /// before copying, so pointing it at the moved file would delete
    /// the file and then fail to copy it.
    @Published var pendingP12ImportURL: URL?
    /// Bumped whenever the coordinator drops a file into
    /// Certificates/ (W-1), so CertificatesView refreshes even when
    /// already on that tab.
    @Published var certificatesChangedToken = UUID()

    /// Loads the Core Data stores once at launch. A failure is shown in
    /// the existing error alert instead of crashing.
    func loadPersistence() async {
        do {
            try await container.persistence.load()
        } catch {
            deepLinkError = error.localizedDescription
            showDeepLinkError = true
        }
    }

    /// ksign://tab/applications  |  ksign://sign  |  ksign://open?file=...
    /// file:// URLs route to `handleIncomingFile`. Deep links to screens
    /// that moved under Settings (tweaks, downloads, sources, files,
    /// logs, about) select the Settings tab instead of failing.
    func handleOpenURL(_ url: URL) {
        if url.scheme == "file" { handleIncomingFile(url); return }
        guard url.scheme == "ksign" else { fail(.unsupportedScheme); return }
        guard let host = url.host else { fail(.malformedURL); return }
        switch host {
        case "tab":
            let name = url.pathComponents.dropFirst().first ?? ""
            routeTabLink(name)
        case "sign":
            selectedTab = .signing
        case "open":
            guard let fileValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "file" })?.value,
                !fileValue.isEmpty else { fail(.malformedURL); return }
            let fileURL: URL
            if fileValue.hasPrefix("file:") {
                guard let parsed = URL(string: fileValue) else { fail(.malformedURL); return }
                fileURL = parsed
            } else {
                fileURL = URL(fileURLWithPath: fileValue)
            }
            handleIncomingFile(fileURL)
        case "applications", "certificates", "settings":
            selectedTab = AppTab(rawValue: host) ?? .dashboard
        case "downloads", "tweaks", "sources", "files", "logs", "about":
            selectedTab = .settings
        default:
            fail(.unknownTab(host))
        }
    }

    /// Routes a `ksign://tab/<name>` link. Moved screens live under
    /// Settings now, so their links select Settings; anything else must
    /// be a real tab or it is an error.
    private func routeTabLink(_ name: String) {
        switch name {
        case "tweaks", "downloads", "sources", "files", "logs", "about":
            selectedTab = .settings
        default:
            guard let tab = AppTab(rawValue: name) else { fail(.unknownTab(name)); return }
            selectedTab = tab
        }
    }

    /// Called by the scene delegate / onOpenURL for document-type opens.
    /// Security-scoped URLs (Open-In) get scoped access; plain file paths
    /// (e.g. from `ksign://open?file=/path`) are not security-scoped, so
    /// a `false` from `startAccessingSecurityScopedResource` must not
    /// drop them — only scoped URLs are stopped again.
    func handleIncomingFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            deepLinkError = NSLocalizedString("error.file.access", comment: "")
            showDeepLinkError = true
            return
        }
        let ext = url.pathExtension.lowercased()
        guard ["ipa", "ksign", "p12", "mobileprovision"].contains(ext) else {
            deepLinkError = NSLocalizedString("file.error.unsupported", comment: "")
            showDeepLinkError = true
            return
        }
        pendingFileOpen = IncomingFile(url: url)
        switch ext {
        case "p12", "mobileprovision": selectedTab = .certificates
        default: selectedTab = .applications
        }
    }

    /// Copies the incoming file into the app workspace (Documents/Inbox),
    /// then routes it by extension (W-1): .ipa through the import use
    /// case, .p12 into Certificates/ with the password sheet, and
    /// .mobileprovision into Certificates/ with a refresh. Failures are
    /// surfaced in the existing error alert instead of silently
    /// dropping the file; the sheet is cleared in all cases.
    func importIncomingFile(_ item: IncomingFile) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            deepLinkError = NSLocalizedString("error.documents.unavailable", comment: "")
            showDeepLinkError = true
            pendingFileOpen = nil
            return
        }
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        do {
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            deepLinkError = error.localizedDescription
            showDeepLinkError = true
            pendingFileOpen = nil
            return
        }
        let dest = inbox.appendingPathComponent(item.fileName)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: item.url, to: dest)
        } catch {
            deepLinkError = error.localizedDescription
            showDeepLinkError = true
            pendingFileOpen = nil
            return
        }
        pendingFileOpen = nil
        switch item.url.pathExtension.lowercased() {
        case "ipa":
            Task { await importIncomingIPA(dest) }
        case "p12":
            importIncomingP12(dest)
        case "mobileprovision":
            importIncomingProvision(dest)
        default:
            break
        }
    }

    /// Validates the IPA and records it, then copies it into
    /// Documents/ImportedApps, where the app list and the Signing
    /// Center look for apps (mirrors ApplicationsViewModel.importIPA).
    /// The list refreshes when the Applications tab appears.
    private func importIncomingIPA(_ url: URL) async {
        do {
            _ = try await container.makeImportIPAUseCase().execute(url: url)
            guard let destDir = Workspace.folder("ImportedApps") else {
                deepLinkError = NSLocalizedString("error.documents.unavailable", comment: "")
                showDeepLinkError = true
                return
            }
            let dest = destDir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            deepLinkError = error.localizedDescription
            showDeepLinkError = true
        }
    }

    /// Copies the .p12 into Certificates/ (so it is visible in the
    /// list) and publishes the Inbox copy for the password sheet:
    /// the sheet's `importFile` copies from that URL into
    /// Certificates/ and registers the certificate with its password.
    private func importIncomingP12(_ url: URL) {
        guard let certsDir = Workspace.folder("Certificates") else {
            deepLinkError = NSLocalizedString("certs.error.storage", comment: "")
            showDeepLinkError = true
            return
        }
        let dest = certsDir.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            deepLinkError = error.localizedDescription
            showDeepLinkError = true
            return
        }
        certificatesChangedToken = UUID()
        pendingP12ImportURL = url
    }

    /// Copies the profile into Certificates/ and refreshes the list.
    private func importIncomingProvision(_ url: URL) {
        guard let certsDir = Workspace.folder("Certificates") else {
            deepLinkError = NSLocalizedString("certs.error.storage", comment: "")
            showDeepLinkError = true
            return
        }
        let dest = certsDir.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            deepLinkError = error.localizedDescription
            showDeepLinkError = true
            return
        }
        certificatesChangedToken = UUID()
    }

    func selectTab(_ tab: AppTab) { selectedTab = tab }

    private func fail(_ error: DeepLinkError) {
        deepLinkError = error.localizedDescription
        showDeepLinkError = true
    }
}

/// Shared helpers for views that read the app Documents workspace.
enum Workspace {
    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static func folder(_ name: String) -> URL? {
        guard let docs = documents else { return nil }
        let url = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func fileSizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

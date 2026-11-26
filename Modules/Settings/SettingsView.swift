import SwiftUI

enum AppearanceChoice: String, CaseIterable {
    case system, light, dark
    var titleKey: String { "settings.appearance.\(rawValue)" }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var storageUsed: Int64 = 0
    @Published var storageFree: Int64 = 0
    @Published var errorMessage: String?

    func refreshStorage() {
        guard let docs = Workspace.documents else { return }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
        storageUsed = total
        if let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            storageFree = values.volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    /// Clears the real caches: Library/Caches, the system temp directory
    /// and the app's own temp workspace (Documents/KsignNext/Temp).
    /// Deliberately NOT Documents/Inbox: that holds incoming files the
    /// user asked to import, not cache data.
    func clearCaches() {
        let fm = FileManager.default
        var firstError: Error?
        func removeContents(of directory: URL) {
            guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for item in items {
                do { try fm.removeItem(at: item) } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            removeContents(of: caches)
        }
        removeContents(of: fm.temporaryDirectory)
        if let docs = Workspace.documents {
            removeContents(of: docs.appendingPathComponent("KsignNext/Temp", isDirectory: true))
        }
        if let error = firstError {
            errorMessage = error.localizedDescription
        } else {
            refreshStorage()
        }
    }
}

struct SettingsView: View {
    @AppStorage("ksign.language") private var language = "en"
    @AppStorage("ksign.appearance") private var appearanceRaw = "system"
    @AppStorage("ksign.downloads.maxConcurrent") private var maxConcurrent = 2
    @AppStorage("ksign.signing.verifyAfterSign") private var verifyAfterSign = true
    @AppStorage("ksign.install.autoStartServer") private var autoStartServer = false
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showClearConfirm = false
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text(NSLocalizedString("settings.section.language", comment: "")).dsSectionHeader()) {
                    Picker(NSLocalizedString("settings.language", comment: ""), selection: $language) {
                        Text("English").tag("en")
                        Text("العربية").tag("ar")
                    }
                    .accessibilityIdentifier("settings.language")
                    Picker(NSLocalizedString("settings.appearance", comment: ""), selection: $appearanceRaw) {
                        ForEach(AppearanceChoice.allCases, id: \.self) { choice in
                            Text(NSLocalizedString(choice.titleKey, comment: "")).tag(choice.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings.appearance")
                }
                Section(header: Text(NSLocalizedString("settings.section.storage", comment: "")).dsSectionHeader()) {
                    HStack {
                        Text(NSLocalizedString("settings.storage.used", comment: ""))
                        Spacer()
                        Text(Workspace.fileSizeString(viewModel.storageUsed))
                    }
                    HStack {
                        Text(NSLocalizedString("settings.storage.free", comment: ""))
                        Spacer()
                        Text(Workspace.fileSizeString(viewModel.storageFree))
                    }
                    Button(NSLocalizedString("settings.storage.clear", comment: "")) { showClearConfirm = true }
                        .dsPrimaryButton()
                        .tint(.red)
                        .accessibilityIdentifier("settings.clearCache")
                }
                Section(header: Text(NSLocalizedString("settings.section.downloads", comment: "")).dsSectionHeader()) {
                    Stepper(value: $maxConcurrent, in: 1...5) {
                        Text(String(format: NSLocalizedString("settings.downloads.concurrent", comment: ""), maxConcurrent))
                    }
                }
                Section(header: Text(NSLocalizedString("settings.section.signing", comment: "")).dsSectionHeader()) {
                    Toggle(NSLocalizedString("settings.signing.verify", comment: ""), isOn: $verifyAfterSign)
                }
                Section(header: Text(NSLocalizedString("settings.section.appleid", comment: "")).dsSectionHeader()) {
                    NavigationLink(NSLocalizedString("appleid.title", comment: "")) {
                        AppleIDSignInView(useCase: coordinator.container.makeAppleIDSignInUseCase())
                    }
                }
                Section(header: Text(NSLocalizedString("settings.section.install", comment: "")).dsSectionHeader()) {
                    Toggle(NSLocalizedString("settings.install.autostart", comment: ""), isOn: $autoStartServer)
                }
                Section(header: Text(NSLocalizedString("settings.section.security", comment: "")).dsSectionHeader()) {
                    // No passcode/biometric feature exists in this app, so
                    // this section states the real security facts instead
                    // of offering a toggle that does nothing.
                    Text(NSLocalizedString("settings.security.keychain", comment: ""))
                    Text(NSLocalizedString("settings.security.p12", comment: ""))
                }
                Section(header: Text(NSLocalizedString("settings.section.more", comment: "")).dsSectionHeader()) {
                    NavigationLink(NSLocalizedString("tab.tweaks", comment: "")) { TweaksView(container: coordinator.container) }
                    NavigationLink(NSLocalizedString("tab.sources", comment: "")) { SourcesView(container: coordinator.container) }
                    NavigationLink(NSLocalizedString("tab.downloads", comment: "")) { DownloadsView(container: coordinator.container) }
                    NavigationLink(NSLocalizedString("tab.files", comment: "")) { FileManagerView() }
                    NavigationLink(NSLocalizedString("tab.logs", comment: "")) { LogsView() }
                    NavigationLink(NSLocalizedString("tab.about", comment: "")) { AboutView() }
                }
            }
            .navigationTitle(NSLocalizedString("tab.settings", comment: ""))
            .dsLargeTitle()
            .onAppear { viewModel.refreshStorage() }
            .alert(NSLocalizedString("settings.storage.clear.confirm", comment: ""), isPresented: $showClearConfirm) {
                Button(NSLocalizedString("settings.storage.clear", comment: ""), role: .destructive) { viewModel.clearCaches() }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
            }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }
}

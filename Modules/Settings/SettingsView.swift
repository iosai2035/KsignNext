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

    func clearCaches() {
        guard let docs = Workspace.documents else { return }
        let cacheDir = docs.appendingPathComponent("Cache", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                try FileManager.default.removeItem(at: cacheDir)
            }
            refreshStorage()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SettingsView: View {
    @AppStorage("ksign.language") private var language = "en"
    @AppStorage("ksign.appearance") private var appearanceRaw = "system"
    @AppStorage("ksign.downloads.wifiOnly") private var wifiOnly = true
    @AppStorage("ksign.downloads.maxConcurrent") private var maxConcurrent = 2
    @AppStorage("ksign.signing.verifyAfterSign") private var verifyAfterSign = true
    @AppStorage("ksign.signing.keepOriginal") private var keepOriginal = true
    @AppStorage("ksign.install.autoStartServer") private var autoStartServer = false
    @AppStorage("ksign.security.requirePasscode") private var requirePasscode = false
    @AppStorage("ksign.notifications.signingDone") private var notifySigningDone = true
    @AppStorage("ksign.notifications.downloadsDone") private var notifyDownloadsDone = true
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showClearConfirm = false
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            List {
                Section(NSLocalizedString("settings.section.language", comment: "")) {
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
                Section(NSLocalizedString("settings.section.storage", comment: "")) {
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
                        .accessibilityIdentifier("settings.clearCache")
                }
                Section(NSLocalizedString("settings.section.downloads", comment: "")) {
                    Toggle(NSLocalizedString("settings.downloads.wifi", comment: ""), isOn: $wifiOnly)
                    Stepper(value: $maxConcurrent, in: 1...5) {
                        Text(String(format: NSLocalizedString("settings.downloads.concurrent", comment: ""), maxConcurrent))
                    }
                }
                Section(NSLocalizedString("settings.section.signing", comment: "")) {
                    Toggle(NSLocalizedString("settings.signing.verify", comment: ""), isOn: $verifyAfterSign)
                    Toggle(NSLocalizedString("settings.signing.keep", comment: ""), isOn: $keepOriginal)
                }
                Section(NSLocalizedString("settings.section.install", comment: "")) {
                    Toggle(NSLocalizedString("settings.install.autostart", comment: ""), isOn: $autoStartServer)
                    NavigationLink(NSLocalizedString("tab.installation", comment: "")) { InstallationView(container: coordinator.container) }
                }
                Section(NSLocalizedString("settings.section.security", comment: "")) {
                    Toggle(NSLocalizedString("settings.security.passcode", comment: ""), isOn: $requirePasscode)
                    NavigationLink(NSLocalizedString("settings.security.details", comment: "")) {
                        Text(NSLocalizedString("settings.security.details.text", comment: "")).padding()
                    }
                }
                Section(NSLocalizedString("settings.section.notifications", comment: "")) {
                    Toggle(NSLocalizedString("settings.notifications.signing", comment: ""), isOn: $notifySigningDone)
                    Toggle(NSLocalizedString("settings.notifications.downloads", comment: ""), isOn: $notifyDownloadsDone)
                }
                Section(NSLocalizedString("settings.section.more", comment: "")) {
                    NavigationLink(NSLocalizedString("tab.tweaks", comment: "")) { TweaksView() }
                    NavigationLink(NSLocalizedString("tab.sources", comment: "")) { SourcesView() }
                    NavigationLink(NSLocalizedString("tab.files", comment: "")) { FileManagerView() }
                    NavigationLink(NSLocalizedString("tab.logs", comment: "")) { LogsView() }
                    NavigationLink(NSLocalizedString("tab.about", comment: "")) { AboutView() }
                }
            }
            .navigationTitle(NSLocalizedString("tab.settings", comment: ""))
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

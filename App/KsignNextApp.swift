import SwiftUI

/// Ksign Next — iOS 16+, SwiftUI entry point.
/// Own code: no reference-app code is used anywhere in this target.
@main
struct KsignNextApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @AppStorage("ksign.appearance") private var appearanceRaw = "system"
    @AppStorage("ksign.language") private var language = "en"

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(coordinator)
                .preferredColorScheme(colorScheme)
                .environment(\.locale, Locale(identifier: language == "ar" ? "ar" : "en"))
                .onOpenURL { url in coordinator.handleOpenURL(url) }
                .task { await coordinator.loadPersistence() }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearanceRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

private struct RootTabView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            DashboardView()
                .tabItem { Label(NSLocalizedString("tab.dashboard", comment: ""), systemImage: "square.grid.2x2") }
                .tag(AppTab.dashboard)
            ApplicationsView()
                .tabItem { Label(NSLocalizedString("tab.applications", comment: ""), systemImage: "app.badge") }
                .tag(AppTab.applications)
            CertificatesView(container: coordinator.container)
                .tabItem { Label(NSLocalizedString("tab.certificates", comment: ""), systemImage: "key.fill") }
                .tag(AppTab.certificates)
            SigningCenterView(container: coordinator.container)
                .tabItem { Label(NSLocalizedString("tab.signing", comment: ""), systemImage: "signature") }
                .tag(AppTab.signing)
            DownloadsView()
                .tabItem { Label(NSLocalizedString("tab.downloads", comment: ""), systemImage: "arrow.down.circle") }
                .tag(AppTab.downloads)
            TweaksView()
                .tabItem { Label(NSLocalizedString("tab.tweaks", comment: ""), systemImage: "wrench.and.screwdriver") }
                .tag(AppTab.tweaks)
            SourcesView()
                .tabItem { Label(NSLocalizedString("tab.sources", comment: ""), systemImage: "globe") }
                .tag(AppTab.sources)
            FileManagerView()
                .tabItem { Label(NSLocalizedString("tab.files", comment: ""), systemImage: "folder") }
                .tag(AppTab.files)
            LogsView()
                .tabItem { Label(NSLocalizedString("tab.logs", comment: ""), systemImage: "list.bullet.rectangle") }
                .tag(AppTab.logs)
            SettingsView()
                .tabItem { Label(NSLocalizedString("tab.settings", comment: ""), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: $coordinator.showDeepLinkError) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {}
        } message: {
            Text(coordinator.deepLinkError ?? "")
        }
        .sheet(item: $coordinator.pendingFileOpen) { item in
            FileOpenSheet(item: item)
        }
    }
}

private struct FileOpenSheet: View {
    let item: IncomingFile
    @EnvironmentObject private var coordinator: AppCoordinator
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(NSLocalizedString("file.open.title", comment: "")).font(.headline)
                Text(item.fileName).font(.subheadline).foregroundStyle(.secondary)
                Text(item.kindDescription).font(.body)
                Button(NSLocalizedString("file.open.import", comment: "")) {
                    coordinator.importIncomingFile(item)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("fileOpen.import")
                Spacer()
            }
            .padding()
            .navigationTitle(NSLocalizedString("file.open.title", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { coordinator.pendingFileOpen = nil }
                }
            }
        }
    }
}

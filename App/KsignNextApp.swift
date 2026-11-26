import SwiftUI

/// Ksign Next — iOS 16+, SwiftUI entry point.
/// Own code: no reference-app code is used anywhere in this target.
@main
struct KsignNextApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @AppStorage("ksign.appearance") private var appearanceRaw = "system"
    @AppStorage("ksign.language") private var language = "en"

    init() {
        // Install the language-overriding bundle class before any
        // NSLocalizedString lookup, so the first render already uses
        // the app-selected language (see Localization.swift).
        Localization.applyLanguage()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .id(language)
                .environmentObject(coordinator)
                .preferredColorScheme(colorScheme)
                .environment(\.locale, Locale(identifier: language == "ar" ? "ar" : "en"))
                .onChange(of: language) { _ in Localization.applyLanguage() }
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
            ApplicationsView(container: coordinator.container)
                .tabItem { Label(NSLocalizedString("tab.applications", comment: ""), systemImage: "app.badge") }
                .tag(AppTab.applications)
            SigningCenterView(container: coordinator.container)
                .tabItem { Label(NSLocalizedString("tab.signing", comment: ""), systemImage: "signature") }
                .tag(AppTab.signing)
            CertificatesView(container: coordinator.container)
                .tabItem { Label(NSLocalizedString("tab.certificates", comment: ""), systemImage: "key.fill") }
                .tag(AppTab.certificates)
            InstallationView(container: coordinator.container)
                .tabItem { Label(NSLocalizedString("tab.installation", comment: ""), systemImage: "arrow.down.app") }
                .tag(AppTab.installation)
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
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                Text(NSLocalizedString("file.open.title", comment: "")).font(.headline)
                Text(item.fileName).font(.subheadline).foregroundStyle(.secondary)
                Text(item.kindDescription).font(.body)
                Button(NSLocalizedString("file.open.import", comment: "")) {
                    coordinator.importIncomingFile(item)
                }
                .dsPrimaryButton()
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

import SwiftUI

/// Ksign Next — iOS 16+, SwiftUI entry point.
/// Own code: no reference-app code is used anywhere in this target.
@main
struct KsignNextApp: App {
    @StateObject private var coordinator = AppCoordinator()

    init() {
        // W-18: purge stale temp directories at launch, before any
        // work can depend on them. Best-effort and non-throwing.
        FileSystemManager.shared.cleanupStaleTempDirectories()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.container.taskRegistry)
                .onOpenURL { url in coordinator.handleOpenURL(url) }
                .task { await coordinator.loadPersistence() }
        }
    }
}

/// Root view: 6 bottom tabs (user order 2026-11-28 15:00), the side
/// menu, the coordinator-driven sheets and alerts, and the global
/// progress HUD. Each tab owns a `NavigationStack` bound to the
/// coordinator's single shared path; `selectTab` resets the path so
/// one tab's pushed screens never leak into another.
private struct RootTabView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: the side menu is a persistent sidebar.
                HStack(spacing: 0) {
                    SideMenuView(viewModel: coordinator.certificatesViewModel, isDrawer: false)
                        .frame(width: 320)
                    tabView
                }
            } else {
                // iPhone: the side menu is a leading-edge drawer over
                // the tabs, opened from any tab.
                ZStack(alignment: .leading) {
                    tabView
                    if coordinator.sideMenuOpen {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture { coordinator.closeSideMenu() }
                            .transition(.opacity)
                        SideMenuView(viewModel: coordinator.certificatesViewModel, isDrawer: true)
                            .frame(width: 320)
                            .transition(.move(edge: .leading))
                    }
                }
                .animation(.default, value: coordinator.sideMenuOpen)
            }
        }
        .sheet(item: $coordinator.presentedSheet, onDismiss: {
            // The Open-In .p12 trigger is consumed when its password
            // sheet closes, so a stale URL can never reopen it.
            coordinator.pendingP12ImportURL = nil
        }) { sheet in
            switch sheet {
            case .p12PasswordPrompt(let url):
                P12PasswordSheet(url: url, viewModel: coordinator.certificatesViewModel)
            case .diagnostics:
                NavigationStack {
                    DiagnosticsView()
                }
            }
        }
        .fullScreenCover(isPresented: $coordinator.showCertificatesManager) {
            NavigationStack {
                CertificatesView(viewModel: coordinator.certificatesViewModel)
                    .navigationDestination(for: AppRoute.self) { route in
                        appRouteView(route)
                    }
            }
        }
        .alert(Loc.string("alert.error.title"), isPresented: $coordinator.showError) {
            Button(Loc.string("common.ok"), role: .cancel) {
                coordinator.errorMessage = nil
            }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .alert(Loc.string("common.notice"), isPresented: $coordinator.showInfo) {
            Button(Loc.string("common.ok"), role: .cancel) {
                coordinator.infoMessage = nil
            }
        } message: {
            Text(coordinator.infoMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            GlobalProgressHUD()
        }
    }

    private var tabView: some View {
        TabView(selection: $coordinator.selectedTab) {
            NavigationStack(path: $coordinator.path) {
                DashboardView(container: coordinator.container)
                    .navigationDestination(for: AppRoute.self) { route in
                        appRouteView(route)
                    }
            }
            .tabItem { Label(Loc.string("tab.dashboard"), systemImage: "square.grid.2x2") }
            .tag(AppTab.dashboard)
            NavigationStack(path: $coordinator.path) {
                ApplicationsView()
                    .navigationDestination(for: AppRoute.self) { route in
                        appRouteView(route)
                    }
            }
            .tabItem { Label(Loc.string("tab.applications"), systemImage: "app.badge") }
            .tag(AppTab.applications)
            NavigationStack(path: $coordinator.path) {
                SourcesView()
                    .navigationDestination(for: AppRoute.self) { route in
                        appRouteView(route)
                    }
            }
            .tabItem { Label(Loc.string("tab.sources"), systemImage: "globe") }
            .tag(AppTab.sources)
            NavigationStack(path: $coordinator.path) {
                DownloadsView()
                    .navigationDestination(for: AppRoute.self) { route in
                        appRouteView(route)
                    }
            }
            .tabItem { Label(Loc.string("tab.downloads"), systemImage: "arrow.down.circle") }
            .tag(AppTab.downloads)
            NavigationStack(path: $coordinator.path) {
                FilesView()
                    .navigationDestination(for: AppRoute.self) { route in
                        appRouteView(route)
                    }
                    // Subfolder pushes register once, at the tab's
                    // navigation root — not inside FilesView, where
                    // every pushed copy would register the same type
                    // again (Gemini review pass 4).
                    .navigationDestination(for: URL.self) { url in
                        FilesView(directory: url)
                    }
            }
            .tabItem { Label(Loc.string("tab.files"), systemImage: "folder") }
            .tag(AppTab.files)
            NavigationStack(path: $coordinator.path) {
                SettingsView()
                    .navigationDestination(for: AppRoute.self) { route in
                        appRouteView(route)
                    }
            }
            .tabItem { Label(Loc.string("tab.settings"), systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(DS.ColorPalette.accentBrand)
    }

    /// Shared push destinations for every tab's stack.
    @ViewBuilder
    private func appRouteView(_ route: AppRoute) -> some View {
        switch route {
        case .certificateDetail(let id):
            if let certificate = coordinator.certificatesViewModel.certificates.first(where: { $0.id == id }) {
                CertificateDetailView(certificate: certificate)
            } else {
                Text(Loc.string("certs.empty"))
                    .foregroundStyle(.secondary)
                    .navigationTitle(Loc.string("tab.certificates"))
            }
        case .profileDetail(let id):
            if let profile = coordinator.certificatesViewModel.profiles.first(where: { $0.id == id }) {
                CertificateDetailView(profile: profile)
            } else {
                Text(Loc.string("certs.empty"))
                    .foregroundStyle(.secondary)
                    .navigationTitle(Loc.string("tab.certificates"))
            }
        case .storage:
            StorageView()
        case .diagnostics:
            DiagnosticsView()
        case .about:
            AboutView()
        }
    }
}

import SwiftUI

/// Settings root (contract §C.5): every row is a real action.
/// Deferred sections are absent entirely — no disabled toggles, no
/// "coming soon" rows. There is NO Certificates entry here: the
/// manager lives in the side menu (user order 2026-11-28 15:01).
struct SettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: AppRoute.storage) {
                    settingsRow(
                        icon: "internaldrive",
                        title: Loc.string("settings.storage.title")
                    )
                }
                .accessibilityLabel(Loc.string("settings.storage.title"))
                NavigationLink(value: AppRoute.diagnostics) {
                    settingsRow(
                        icon: "list.bullet.rectangle",
                        title: Loc.string("settings.diagnostics.title")
                    )
                }
                .accessibilityLabel(Loc.string("settings.diagnostics.title"))
                NavigationLink(value: AppRoute.about) {
                    settingsRow(
                        icon: "info.circle",
                        title: Loc.string("settings.about.title")
                    )
                }
                .accessibilityLabel(Loc.string("settings.about.title"))
            }
        }
        .navigationTitle(Loc.string("tab.settings"))
        .dsLargeTitle()
        .dsSideMenuButton()
    }

    private func settingsRow(icon: String, title: String) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(DS.ColorPalette.accentBrand)
            Text(title)
            Spacer()
        }
        .frame(minHeight: DS.Accessibility.minTouchTarget)
    }
}

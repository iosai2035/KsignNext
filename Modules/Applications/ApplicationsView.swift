import SwiftUI

/// Applications tab (contract §C.1 — documented exception).
/// Honest Phase 1 empty state, one line, no buttons: the engines
/// land in Phases 3–4, so there is nothing to show and nothing fake
/// to tap.
struct ApplicationsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text(Loc.string("apps.phase3"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .accessibilityLabel(Loc.string("apps.phase3"))
            Spacer()
        }
        .navigationTitle(Loc.string("tab.applications"))
        .dsLargeTitle()
        .dsSideMenuButton()
    }
}

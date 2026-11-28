import SwiftUI

/// Sources tab (contract §C.1 — documented exception).
/// Honest Phase 1 empty state, one line, no buttons: the sources
/// engine lands in Phase 3, so there is nothing to show and nothing
/// fake to tap.
struct SourcesView: View {
    var body: some View {
        VStack {
            Spacer()
            Text(Loc.string("sources.phase3"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .accessibilityLabel(Loc.string("sources.phase3"))
            Spacer()
        }
        .navigationTitle(Loc.string("tab.sources"))
        .dsLargeTitle()
        .dsSideMenuButton()
    }
}

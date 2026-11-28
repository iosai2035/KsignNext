import SwiftUI

/// Downloads tab (contract §C.1 — documented exception).
/// Honest Phase 1 empty state, one line, no buttons: the download
/// engine lands in Phase 3, so there is nothing to show and nothing
/// fake to tap.
struct DownloadsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text(Loc.string("downloads.phase3"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .accessibilityLabel(Loc.string("downloads.phase3"))
            Spacer()
        }
        .navigationTitle(Loc.string("tab.downloads"))
        .dsLargeTitle()
        .dsSideMenuButton()
    }
}

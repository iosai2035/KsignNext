import SwiftUI

/// iOS 16-compatible replacement for `ContentUnavailableView` (iOS 17+).
/// Kept call-compatible with the sites it replaces: a title, a system
/// image, an optional description text, and an optional trailing actions
/// closure. Rendered as a centred icon + title + description + actions.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: Text?
    let actions: Actions

    init(_ title: String, systemImage: String, description: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    init(_ title: String, systemImage: String, description: Text? = nil) where Actions == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = EmptyView()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let description {
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

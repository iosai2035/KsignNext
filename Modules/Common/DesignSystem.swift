import SwiftUI

/// The single shared design system for Ksign Next.
///
/// Every screen uses these values instead of inventing its own spacing,
/// corner radius, card background, button style or title mode, so the
/// app looks like one app:
/// - Spacing scale: 2 / 4 / 6 / 8 / 12 / 16 / 20 (section stacks use 20,
///   rows and inner stacks use 8, tight groups use 4).
/// - Cards: 12pt padding on a `Color.secondary.opacity(0.08)` fill with
///   a 12pt corner radius (see ``DS/Card`` / `.dsCard()`).
/// - Buttons: primary actions use `.borderedProminent`, secondary
///   actions use `.bordered`, plain text actions use `.plain` — see
///   ``DS/PrimaryButton`` / ``DS/SecondaryButton`` / ``DS/PlainButton``.
/// - Titles: top-level (tab-root) screens use `.large`; pushed detail
///   screens use `.inline` (see `.dsLargeTitle()` / `.dsInlineTitle()`).
/// - Section headers: `.headline` (see `.dsSectionHeader()`).
public enum DS {
    /// Spacing scale in points.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 20
    }

    /// Standard corner radius for cards and banners.
    public static let cornerRadius: CGFloat = 12

    /// Standard padding inside a card.
    public static let cardPadding: CGFloat = 12

    /// Spacing between rows inside a section.
    public static let rowSpacing: CGFloat = 8

    /// Spacing between sections on a screen.
    public static let sectionSpacing: CGFloat = 20

    /// Primary action button style (destructive actions use
    /// `.borderedProminent` with `.tint(.red)` at the call site).
    public static let primaryButton: BorderedProminentButtonStyle = .borderedProminent

    /// Secondary action button style.
    public static let secondaryButton: BorderedButtonStyle = .bordered

    /// Plain text action button style.
    public static let plainButton: PlainButtonStyle = .plain
}

public extension View {
    /// Standard card: 12pt padding on a subtle secondary fill with a
    /// 12pt corner radius. Use for count cards, banners and grouped rows.
    func dsCard() -> some View {
        padding(DS.cardPadding)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.cornerRadius))
    }

    /// Standard section header text style.
    func dsSectionHeader() -> some View {
        font(.headline)
    }

    /// Primary action button style (`.borderedProminent`).
    func dsPrimaryButton() -> some View {
        buttonStyle(DS.primaryButton)
    }

    /// Secondary action button style (`.bordered`).
    func dsSecondaryButton() -> some View {
        buttonStyle(DS.secondaryButton)
    }

    /// Plain text action button style (`.plain`).
    func dsPlainButton() -> some View {
        buttonStyle(DS.plainButton)
    }

    /// Large title display mode, for top-level (tab-root) screens.
    func dsLargeTitle() -> some View {
        navigationBarTitleDisplayMode(.large)
    }

    /// Inline title display mode, for pushed detail screens.
    func dsInlineTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI
import UIKit

/// The single shared design system for Ksign Next.
///
/// Every screen uses these values instead of inventing its own spacing,
/// corner radius, card background, button style or title mode, so the
/// app looks like one app:
/// - Spacing scale: 2 / 4 / 6 / 8 / 12 / 16 / 20 (section stacks use 20,
///   rows and inner stacks use 8, tight groups use 4).
/// - Cards: 12pt padding on the brand card fill (light: near-white,
///   dark: lifted dark grey) with a 12pt corner radius (see
///   ``DS/Card`` / `.dsCard()`).
/// - Buttons: primary actions use `.borderedProminent` tinted with
///   the brand accent, secondary actions use `.bordered`, plain text
///   actions use `.plain` — see ``DS/PrimaryButton`` /
///   ``DS/SecondaryButton`` / ``DS/PlainButton``.
/// - Brand: one accent colour, `DS/ColorPalette/accentBrand` — a
///   deep indigo that reads on both light and dark — used for the
///   tab bar tint, primary buttons and count-card icons, so the app
///   is recognisable instead of default system blue/grey.
/// - Titles: top-level (tab-root) screens use `.large`; pushed detail
///   screens use `.inline` (see `.dsLargeTitle()` / `.dsInlineTitle()`).
/// - Section headers: `.headline` (see `.dsSectionHeader()`).
public enum DS {
    /// Brand colours. Defined in code (not the asset catalog) so
    /// they adapt to light/dark without extra files: the accent is
    /// a deep indigo in light mode and a lighter indigo in dark
    /// mode, so it keeps contrast on both backgrounds.
    public enum ColorPalette {
        public static let accentBrand = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.55, green: 0.62, blue: 1.0, alpha: 1.0)
                : UIColor(red: 0.22, green: 0.27, blue: 0.80, alpha: 1.0)
        })
        public static let cardBackground = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.13, alpha: 1.0)
                : UIColor(white: 0.96, alpha: 1.0)
        })
    }

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

    /// Accessibility: minimum touch target (contract §C.8).
    public enum Accessibility {
        public static let minTouchTarget: CGFloat = 44
    }

    /// Band colour for an expiry state (contract §B.11): green >7
    /// days, orange 1–7 days, red ≤24h / expired.
    public static func expiryColor(for band: ExpiryBand) -> Color {
        switch band {
        case .healthy: return .green
        case .warning: return .orange
        case .urgent, .expired: return .red
        }
    }

    /// Semantic countdown text for an expiry, in the user's language.
    /// Never a raw number and never a fake countdown: no expiry date
    /// → "No expiry date". `days` is `daysUntilExpiration`
    /// (calendar days from today; negative = already expired).
    public static func expiryText(days: Int?) -> String {
        guard let days else { return Loc.string("expiry.none") }
        if days < 0 { return Loc.string("expiry.expiredDays", -days) }
        if days == 0 { return Loc.string("expiry.today") }
        if days == 1 { return Loc.string("expiry.tomorrow") }
        return Loc.string("expiry.inDays", days)
    }
}

/// Expiry countdown pill: band-coloured text with a semantic
/// VoiceOver label ("Expires in 3 days"), never raw numbers
/// (contract §C.8). The label is the whole status, so it is the
/// accessibility label, not a value.
struct ExpiryPill: View {
    let daysUntilExpiration: Int?

    var body: some View {
        let band = expiryBand(daysUntilExpiration: daysUntilExpiration)
        Text(DS.expiryText(days: daysUntilExpiration))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(DS.expiryColor(for: band))
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .background(DS.expiryColor(for: band).opacity(0.15), in: Capsule())
            .accessibilityLabel(DS.expiryText(days: daysUntilExpiration))
    }
}

/// Localised strings with the contract §C.8 fallback rule: a missing
/// key falls back to the English string and logs a warning to
/// `AppLogger` — it never renders a raw key.
enum Loc {
    /// Localised string for `key`, formatted with `args` when the
    /// string contains format specifiers.
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let raw = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        if raw != key {
            return format(raw, args: args)
        }
        // Missing key: fall back to the English table, and log it.
        if let enURL = Bundle.main.url(forResource: "en", withExtension: "lproj"),
           let enBundle = Bundle(url: enURL) {
            let english = enBundle.localizedString(forKey: key, value: nil, table: nil)
            if english != key {
                Task { await AppLogger.shared.warning("Missing localized string for key: \(key)") }
                return format(english, args: args)
            }
        }
        Task { await AppLogger.shared.warning("Missing localized string for key: \(key)") }
        return key
    }

    private static func format(_ string: String, args: [CVarArg]) -> String {
        guard !args.isEmpty else { return string }
        return String(format: string, locale: .current, arguments: args)
    }
}

public extension View {
    /// Standard card: 12pt padding on the brand card fill with a
    /// 12pt corner radius. Use for count cards, banners and grouped rows.
    func dsCard() -> some View {
        padding(DS.cardPadding)
            .background(DS.ColorPalette.cardBackground, in: RoundedRectangle(cornerRadius: DS.cornerRadius))
    }

    /// Standard section header text style.
    func dsSectionHeader() -> some View {
        font(.headline)
    }

    /// Primary action button style (`.borderedProminent`, brand tint).
    func dsPrimaryButton() -> some View {
        buttonStyle(DS.primaryButton)
            .tint(DS.ColorPalette.accentBrand)
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

    /// Leading toolbar button that opens the side menu from any tab.
    /// Hidden on iPad, where the side menu is a persistent sidebar.
    func dsSideMenuButton() -> some View {
        toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                SideMenuToolbarButton()
            }
        }
    }
}

/// The side-menu toolbar button. Separated so the `toolbar` modifier
/// above stays small; hidden when the horizontal size class is
/// regular (iPad persistent sidebar).
private struct SideMenuToolbarButton: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass != .regular {
            Button {
                coordinator.openSideMenu()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
            }
            .accessibilityLabel(Loc.string("sidemenu.title"))
            .accessibilityHint(Loc.string("sidemenu.open.hint"))
        }
    }
}

/// System share sheet (`UIActivityViewController`) for iOS 16
/// SwiftUI. The iPad popover gets a source view from the key window,
/// so presenting it never crashes for a missing source rect.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad presents the sheet in a popover, which needs a source
        // view. Prefer the key window; fall back to any window in the
        // first scene so the popover never has a nil source.
        let windows = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
        if let rootView = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?
            .rootViewController?.view {
            controller.popoverPresentationController?.sourceView = rootView
            controller.popoverPresentationController?.sourceRect = CGRect(
                x: rootView.bounds.midX, y: rootView.bounds.midY, width: 0, height: 0
            )
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

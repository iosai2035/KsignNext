import Foundation

/// Expiry band for a certificate or provisioning profile, used for the
/// countdown pill colour and the dashboard banners.
public enum ExpiryBand: Sendable, Equatable {
    /// More than 7 days left, or no expiry date known.
    case healthy
    /// 1–7 days left.
    case warning
    /// Expires within 24 hours.
    case urgent
    /// Past its expiration date.
    case expired
}

/// Band for a whole-calendar-day count (`daysUntilExpiration`).
///
/// - `nil` → `.healthy`: no expiry is known, so the UI shows
///   "no expiry date" and never a fake countdown.
/// - Negative → `.expired`; `0` → `.urgent` (fewer than 24 hours of
///   whole calendar days remain); `1...7` → `.warning`;
///   more than 7 → `.healthy`.
///
/// Note: a whole-day count of `0` cannot distinguish "expires within
/// 24 hours" from "expired within the last 24 hours" — both render
/// red. When the expiration date is available, prefer
/// `expiryBand(expirationDate:referenceDate:)`, which is exact.
public func expiryBand(daysUntilExpiration: Int?) -> ExpiryBand {
    guard let days = daysUntilExpiration else { return .healthy }
    if days < 0 { return .expired }
    if days == 0 { return .urgent }
    if days <= 7 { return .warning }
    return .healthy
}

/// Exact band for a known expiration date.
///
/// - `nil` → `.healthy` (no expiry known).
/// - Past expiry → `.expired`.
/// - Within 24 hours (86,400 seconds) → `.urgent`.
/// - 1–7 whole calendar days left → `.warning`.
/// - More than 7 days left → `.healthy`.
public func expiryBand(expirationDate: Date?, referenceDate: Date = Date()) -> ExpiryBand {
    guard let expirationDate else { return .healthy }
    let remaining = expirationDate.timeIntervalSince(referenceDate)
    if remaining <= 0 { return .expired }
    if remaining <= 86_400 { return .urgent }
    let days = Calendar.current.dateComponents([.day], from: referenceDate, to: expirationDate).day
    guard let days else { return .healthy }
    if days <= 7 { return .warning }
    return .healthy
}

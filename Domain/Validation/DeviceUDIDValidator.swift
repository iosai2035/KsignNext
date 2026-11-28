import Foundation

/// Domain validation for device UDIDs, returning typed errors (not
/// bare booleans) so the UI can show the exact problem. A UDID is
/// exactly 40 hex characters; lowercase input is accepted and
/// normalised to uppercase. There is no public iOS API for the UDID,
/// so the user pastes it (see `DeviceUDIDStore`).
///
/// Self-contained: the old shared `Validators` helper was deleted in
/// the rebuild and is not part of Phase 1, so the 40-hex rule lives
/// here.
public enum DeviceUDIDValidator {
    /// The exact length of a UDID in characters.
    public static let requiredLength = 40

    /// Throws `AppError.validation` for an empty or malformed UDID.
    public static func validate(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.validation(.emptyValue(field: "UDID"))
        }
        guard isValid(value) else {
            throw AppError.validation(.invalidDeviceUDID(value))
        }
    }

    /// `true` when `value` is a 40-character hex UDID
    /// (case-insensitive, surrounding / embedded whitespace ignored).
    public static func isValid(_ value: String) -> Bool {
        normalized(value) != nil
    }

    /// The normalised (whitespace-stripped, uppercased) UDID, or
    /// `nil` when `value` is not a valid UDID.
    public static func normalized(_ value: String) -> String? {
        let normalized = value.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .uppercased()
        guard normalized.count == requiredLength,
              normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        return normalized
    }
}

import Foundation

/// Domain validation for device UDIDs, returning typed errors (not bare
/// booleans) so the UI can show the exact problem. A UDID is exactly 40
/// hex characters; lowercase input is accepted and normalized to
/// uppercase. There is no public iOS API for the UDID, so the user
/// pastes it (see `DeviceUDIDStore` / `DeviceUDIDSection`).
public enum DeviceUDIDValidator {
    public static func validate(_ value: String) throws {
        guard Validators.isNonEmpty(value) else {
            throw AppError.validation(.emptyValue(field: "UDID"))
        }
        guard Validators.isValidDeviceUDID(value) else {
            throw AppError.validation(.invalidDeviceUDID(value))
        }
    }

    public static func isValid(_ value: String) -> Bool {
        Validators.isValidDeviceUDID(value)
    }

    /// The normalized (whitespace-stripped, uppercased) UDID, or nil
    /// when `value` is not a valid UDID.
    public static func normalized(_ value: String) -> String? {
        Validators.normalizedDeviceUDID(value)
    }
}

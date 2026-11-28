import Combine
import Foundation

/// The device UDID the user pasted for coverage checks: iOS has no
/// public API for it, so the user pastes it once and it is kept in
/// UserDefaults.
///
/// A missing UDID is not an error — coverage UI shows "paste a UDID
/// to check coverage" until one is saved.
@MainActor
public final class DeviceUDIDStore: ObservableObject {
    /// UserDefaults key for the pasted UDID.
    public static let storageKey = "ksign.deviceUDID"

    @Published public private(set) var savedUDID: String?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.savedUDID = defaults.string(forKey: Self.storageKey)
    }

    /// Validates `raw` (40 hex chars, either case) and stores the
    /// normalised (uppercased) UDID. Returns the stored value.
    /// Throws `AppError.validation` for an empty or malformed UDID.
    @discardableResult
    public func save(_ raw: String) throws -> String {
        try DeviceUDIDValidator.validate(raw)
        guard let normalized = DeviceUDIDValidator.normalized(raw) else {
            throw AppError.validation(.invalidDeviceUDID(raw))
        }
        defaults.set(normalized, forKey: Self.storageKey)
        savedUDID = normalized
        return normalized
    }

    /// Removes the saved UDID.
    public func clear() {
        defaults.removeObject(forKey: Self.storageKey)
        savedUDID = nil
    }
}

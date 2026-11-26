import Foundation

/// The device UDID the user pasted for real refresh (Phase 1/2): Apple
/// needs the UDID to register this device before it issues a fresh
/// provisioning profile, and iOS has no public API for it, so the user
/// pastes it once and it is kept in UserDefaults.
///
/// This is the fallback the feasibility gate settled on (see
/// Documentation/RealRefresh-Research.md, update 2026-11-26): a free
/// Apple ID profile cannot carry the Packet Tunnel entitlement, and the
/// LocalDevVPN + RPPairing flow needs Wi-Fi, so there is no automatic
/// UDID lookup to build. The sign-in / refresh flow reads `savedUDID`;
/// nil means the user has not pasted one yet.
@MainActor
final class DeviceUDIDStore: ObservableObject {
    /// UserDefaults key for the pasted UDID.
    static let storageKey = "ksign.deviceUDID"

    @Published private(set) var savedUDID: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.savedUDID = defaults.string(forKey: Self.storageKey)
    }

    /// Validates `raw` (40 hex chars, either case) and stores the
    /// normalized (uppercased) UDID. Returns the stored value.
    /// Throws `AppError.validation` for an empty or malformed UDID.
    @discardableResult
    func save(_ raw: String) throws -> String {
        try DeviceUDIDValidator.validate(raw)
        guard let normalized = DeviceUDIDValidator.normalized(raw) else {
            throw AppError.validation(.invalidDeviceUDID(raw))
        }
        defaults.set(normalized, forKey: Self.storageKey)
        savedUDID = normalized
        return normalized
    }

    /// Removes the saved UDID.
    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
        savedUDID = nil
    }
}

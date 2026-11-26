import Foundation

/// What a successful Phase 1 sign-in leaves behind. The Xcode token
/// value never crosses to Swift (design §5.1.6) — `appTokenProven`
/// only records that `get_app_token` succeeded on this handle, so
/// Phase 2 knows the session is usable for developer services.
public struct AppleIDSession: Equatable, Sendable, Codable {
    public var email: String
    public var firstName: String?
    public var lastName: String?
    public var adsid: String?
    public var serverURL: String
    public var claimPreset: String
    public var signedInAt: Date
    public var appTokenProven: Bool

    public var displayName: String? {
        let parts = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Persists the Apple ID sign-in state and the AltLoad backoff rules
/// (research doc §7):
/// - the password lives in the Keychain only, under
///   `appleid-password-<email>`; a rejected password is removed.
/// - the session record (email, names, adsid, server, claim) is not
///   a secret and lives in the Keychain as data, so it survives with
///   the password's protection class.
/// - pause state and the rejection count live in UserDefaults (not
///   secrets): a second consecutive rejection pauses sign-ins for
///   this Apple ID for 15 minutes; a locked account pauses
///   immediately; "too many requests" pauses without removing the
///   password.
/// - the email is also kept in UserDefaults so the sign-in form can
///   pre-fill it after sign-out.
public final class AppleIDSessionStore: @unchecked Sendable {

    private static let sessionAccount = "appleid-session"
    private static let emailKey = "ksign.appleid.email"
    private static let pauseUntilKey = "ksign.appleid.pauseUntil"
    private static let rejectionsKey = "ksign.appleid.rejections"
    private static let lastClaimKey = "ksign.appleid.lastClaim"
    private static let lastServerKey = "ksign.appleid.lastServer"

    /// Backoff pause after repeated rejections (AltLoad rule).
    public static let pauseDuration: TimeInterval = 15 * 60

    private let keychain: KeychainService
    private let defaults: UserDefaults

    public init(keychain: KeychainService = .shared, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    // MARK: - Storage directory

    /// `<Application Support>/KsignNext/AppleRefresh` — the Rust
    /// core stores one folder per anisette server under it
    /// (design §6.2). Created on demand.
    public var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("KsignNext/AppleRefresh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Session

    public static func passwordAccount(for email: String) -> String {
        "appleid-password-\(email.lowercased())"
    }

    public func saveSession(_ session: AppleIDSession, password: String) {
        if let data = try? JSONEncoder().encode(session) {
            try? keychain.save(data, account: Self.sessionAccount)
        }
        try? keychain.savePassword(password, account: Self.passwordAccount(for: session.email))
        defaults.set(session.email, forKey: Self.emailKey)
        defaults.set(session.claimPreset, forKey: Self.lastClaimKey)
        defaults.set(session.serverURL, forKey: Self.lastServerKey)
    }

    public func loadSession() -> AppleIDSession? {
        guard let data = try? keychain.read(account: Self.sessionAccount),
              let session = try? JSONDecoder().decode(AppleIDSession.self, from: data) else {
            return nil
        }
        return session
    }

    public func loadPassword(email: String) -> String? {
        try? keychain.readPassword(account: Self.passwordAccount(for: email))
    }

    public var savedEmail: String? {
        defaults.string(forKey: Self.emailKey)
    }

    /// Signs out: removes the password and the session record. The
    /// email stays saved so the form can pre-fill it.
    public func clearSession() {
        if let session = loadSession() {
            try? keychain.delete(account: Self.passwordAccount(for: session.email))
        }
        try? keychain.delete(account: Self.sessionAccount)
        resetRejections()
        defaults.removeObject(forKey: Self.pauseUntilKey)
    }

    public func clearPassword(email: String) {
        try? keychain.delete(account: Self.passwordAccount(for: email))
    }

    // MARK: - Backoff (AltLoad rules)

    public func recordRejection() -> Int {
        let count = defaults.integer(forKey: Self.rejectionsKey) + 1
        defaults.set(count, forKey: Self.rejectionsKey)
        return count
    }

    public func resetRejections() {
        defaults.removeObject(forKey: Self.rejectionsKey)
    }

    public var rejectionCount: Int {
        defaults.integer(forKey: Self.rejectionsKey)
    }

    public func pause(until date: Date = Date().addingTimeInterval(pauseDuration)) {
        defaults.set(date, forKey: Self.pauseUntilKey)
    }

    public func pauseUntil() -> Date? {
        guard let date = defaults.object(forKey: Self.pauseUntilKey) as? Date,
              date > Date() else { return nil }
        return date
    }

    public var isPaused: Bool { pauseUntil() != nil }

    // MARK: - Last successful attempt

    public var lastClaimPreset: String? {
        defaults.string(forKey: Self.lastClaimKey)
    }

    public var lastServerURL: String? {
        defaults.string(forKey: Self.lastServerKey)
    }
}

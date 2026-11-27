import Foundation

// MARK: - Errors

/// Typed errors from the Rust Apple-refresh core (isideload 0.5.2).
/// Mapped from the FFI JSON error object (`error.code` + `apple_ec`,
/// design doc §4/§7). The password and any token value never appear
/// in these messages — the Rust side redacts them before they cross.
public enum AppleRefreshError: LocalizedError, Equatable {
    case unavailable(reason: String)
    case invalidArgument(reason: String)
    case network(reason: String)
    case tls(reason: String)
    case timeout
    case anisetteUnavailable(reason: String)
    case anisetteProvision(reason: String)
    case appleAuth(appleEC: Int?, appleEM: String?, message: String)
    case wrongPassword
    case accountLocked
    case tooManyRequests
    case server503
    case twoFactorAborted
    case cancelled
    case noPromptPending
    case paused(until: Date)
    case notSignedIn
    case developerError(appleEC: Int?, appleEM: String?, message: String)
    case internalError(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Apple sign-in is unavailable in this build: \(reason)"
        case .invalidArgument(let reason):
            return reason
        case .network(let reason):
            return "Network error during Apple sign-in: \(reason)"
        case .tls(let reason):
            return "Secure connection to Apple failed: \(reason)"
        case .timeout:
            return "Apple sign-in timed out. Check your connection and try again."
        case .anisetteUnavailable(let reason):
            return "The anisette server could not be reached: \(reason)"
        case .anisetteProvision(let reason):
            return "Could not set up the device identity with the anisette server: \(reason)"
        case .appleAuth(let ec, _, let message):
            if ec == -22410 {
                return "Apple refused sign-in (-22410). This is the known breakage from Apple's 21 November change: sign-in fails after the verification code on every claim and server tried. No workaround is known yet."
            }
            return "Apple refused sign-in\(ec.map { " (\($0))" } ?? ""): \(message)"
        case .wrongPassword:
            return "The Apple ID password is incorrect."
        case .accountLocked:
            return "This Apple ID is locked. Sign in at appleid.apple.com to unlock it, then try again later."
        case .tooManyRequests:
            return "Too many sign-in attempts. Wait a while before trying again."
        case .server503:
            return "Apple's sign-in service refused this request (503). Try a different anisette server or claim."
        case .twoFactorAborted:
            return "Two-factor authentication was cancelled."
        case .cancelled:
            return "Sign-in was cancelled."
        case .noPromptPending:
            return "No two-factor prompt is waiting for an answer."
        case .paused(let until):
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Sign-in is paused until \(formatter.string(from: until)) after repeated rejections."
        case .notSignedIn:
            return "Sign in with an Apple ID first."
        case .developerError(let ec, _, let message):
            if ec == 7460 {
                return "Apple refused: the maximum number of development certificates for this account has been reached (7460). Revoke an old certificate and try again."
            }
            return "Apple's developer service refused the request\(ec.map { " (\($0))" } ?? ""): \(message)"
        case .internalError(let reason):
            return "Apple sign-in failed: \(reason)"
        }
    }

    /// Maps an FFI error JSON object to a typed error. `wrong_password`
    /// is only produced when the Rust side emits that code (design
    /// doc Q2: the wrong-password Apple code is still unknown — the
    /// Rust mapper sends every other auth failure as `apple_auth`).
    static func from(json: [String: Any], step: String) -> AppleRefreshError {
        let err = json["error"] as? [String: Any]
        let code = err?["code"] as? String ?? "internal"
        let message = err?["message"] as? String ?? "Apple sign-in failed at \(step)."
        let ec = err?["apple_ec"] as? Int
        let em = err?["apple_em"] as? String
        switch code {
        case "invalid_argument": return .invalidArgument(reason: message)
        case "network": return .network(reason: message)
        case "tls": return .tls(reason: message)
        case "timeout": return .timeout
        case "anisette_unavailable": return .anisetteUnavailable(reason: message)
        case "anisette_provision": return .anisetteProvision(reason: message)
        case "apple_auth": return .appleAuth(appleEC: ec, appleEM: em, message: message)
        case "wrong_password": return .wrongPassword
        case "account_locked": return .accountLocked
        case "too_many_requests": return .tooManyRequests
        case "server_503": return .server503
        case "two_factor_aborted": return .twoFactorAborted
        case "cancelled": return .cancelled
        case "no_prompt_pending": return .noPromptPending
        case "not_signed_in": return .notSignedIn
        case "developer_error": return .developerError(appleEC: ec, appleEM: em, message: message)
        default: return .internalError(reason: message)
        }
    }
}

// MARK: - Claims

/// Which `X-MMe-Client-Info` the Rust core presents to Apple.
/// Try `sideinstaller` first (macOS 10.15.7, still calls itself
/// "Mac OS X" — Apple lets that through while
/// `<macOS;…>` claims get a 503), then `apparition` (macOS 27),
/// then the anisette server's own claim. Exact strings: design §5.3.
public enum AppleRefreshClaim: Equatable, Sendable {
    case server
    case apparition
    case sideinstaller
    case custom(clientInfo: String, userAgent: String)

    public var presetName: String {
        switch self {
        case .server: return "server"
        case .apparition: return "apparition"
        case .sideinstaller: return "sideinstaller"
        case .custom: return "custom"
        }
    }

    public var clientInfo: String? {
        switch self {
        case .server: return nil
        case .apparition:
            return "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        case .sideinstaller:
            return "<MacBookPro16,1> <Mac OS X;10.15.7;19H2> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        case .custom(let info, _): return info
        }
    }

    public var userAgent: String? {
        switch self {
        case .server: return nil
        case .apparition: return "akd/1.0 CFNetwork/808.1.4"
        case .sideinstaller: return "akd/1.0 CFNetwork/1121.1.2 Darwin/19.7.0"
        case .custom(_, let agent): return agent
        }
    }

    /// The `{"preset": …, …}` object the FFI expects. Custom claims
    /// are validated: non-empty, no NUL/CR/LF (design §4).
    public func jsonObject() throws -> [String: Any] {
        switch self {
        case .server: return ["preset": "server"]
        case .apparition: return ["preset": "apparition"]
        case .sideinstaller: return ["preset": "sideinstaller"]
        case .custom(let info, let agent):
            guard !info.isEmpty, !agent.isEmpty,
                  !info.contains("\0"), !info.contains("\r"), !info.contains("\n"),
                  !agent.contains("\0"), !agent.contains("\r"), !agent.contains("\n") else {
                throw AppleRefreshError.invalidArgument(
                    reason: "The custom client claim must be non-empty and contain no control characters.")
            }
            return ["preset": "custom", "client_info": info, "user_agent": agent]
        }
    }
}

// MARK: - Session config

/// Everything `apple_refresh_session_new` needs. One config = one
/// Apple ID + one anisette server + one claim set.
public struct AppleRefreshSessionConfig: Sendable {
    public var anisetteServerURL: String
    public var storageDirectory: URL
    public var serialNumber: String = "0"
    public var signInClaim: AppleRefreshClaim = .sideinstaller
    public var err429Retries: Int = 10

    public init(anisetteServerURL: String, storageDirectory: URL,
                serialNumber: String = "0",
                signInClaim: AppleRefreshClaim = .sideinstaller,
                err429Retries: Int = 10) {
        self.anisetteServerURL = anisetteServerURL
        self.storageDirectory = storageDirectory
        self.serialNumber = serialNumber
        self.signInClaim = signInClaim
        self.err429Retries = err429Retries
    }

    func jsonString() throws -> String {
        let object: [String: Any] = [
            "anisette_server_url": anisetteServerURL,
            "storage_dir": storageDirectory.path,
            "serial_number": serialNumber,
            "sign_in_claim": try signInClaim.jsonObject(),
            "err_429_retries": err429Retries,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppleRefreshError.internalError(reason: "Could not encode the sign-in configuration.")
        }
        return text
    }
}

// MARK: - Results

public struct AppleIDLoginResult: Equatable, Sendable {
    public let email: String
    public let firstName: String?
    public let lastName: String?
    public let adsid: String?

    static func from(json: [String: Any]) -> AppleIDLoginResult {
        AppleIDLoginResult(
            email: json["email"] as? String ?? "",
            firstName: json["first_name"] as? String,
            lastName: json["last_name"] as? String,
            adsid: json["adsid"] as? String
        )
    }
}

public struct AppleRefreshAppToken: Equatable, Sendable {
    public let app: String
    public let hasToken: Bool
    public let tokenLength: Int

    static func from(json: [String: Any]) -> AppleRefreshAppToken {
        AppleRefreshAppToken(
            app: json["app"] as? String ?? "",
            hasToken: json["has_token"] as? Bool ?? false,
            tokenLength: json["token_length"] as? Int ?? 0
        )
    }
}

public struct AppleRefreshSessionInfo: Equatable, Sendable {
    public let email: String?
    public let firstName: String?
    public let lastName: String?
    public let adsid: String?
    public let loggedIn: Bool
    public let server: String?
    public let signInClaim: String?

    static func from(json: [String: Any]) -> AppleRefreshSessionInfo {
        AppleRefreshSessionInfo(
            email: json["email"] as? String,
            firstName: json["first_name"] as? String,
            lastName: json["last_name"] as? String,
            adsid: json["adsid"] as? String,
            loggedIn: json["logged_in"] as? Bool ?? false,
            server: json["server"] as? String,
            signInClaim: json["sign_in_claim"] as? String
        )
    }
}

// MARK: - Two-factor prompt / response

public struct TwoFactorNumber: Equatable, Sendable {
    public let id: Int
    public let numberWithDialCode: String
    public let lastTwoDigits: String
    public let pushMode: String
}

public struct TwoFactorPrompt: Equatable, Sendable {
    public let unknown: Bool
    public let sms: Bool
    public let lastError: String?
    public let numbers: [TwoFactorNumber]
    public let selectedNumberID: Int?

    /// Parses the `poll_prompt` envelope. Returns nil when nothing is
    /// pending. When a prompt IS pending but cannot be parsed, returns
    /// a minimal prompt instead of nil: the user already holds a code
    /// from Apple, and the code field needs none of the prompt's
    /// numbers — dropping the prompt silently left the user with a
    /// code and no place to type it (the sheet never opened). A wrong
    /// code simply re-prompts (isideload re-asks with last_error).
    static func fromOrFallback(json: [String: Any]) -> TwoFactorPrompt? {
        guard json["pending"] as? Bool == true else { return nil }
        if let prompt = from(json: json) { return prompt }
        return TwoFactorPrompt(
            unknown: true, sms: false,
            lastError: NSLocalizedString("appleid.2fa.unparsed", comment: ""),
            numbers: [], selectedNumberID: nil)
    }

    static func from(json: [String: Any]) -> TwoFactorPrompt? {
        guard let prompt = json["prompt"] as? [String: Any] else { return nil }
        var numbers: [TwoFactorNumber] = []
        for raw in (prompt["numbers"] as? [[String: Any]]) ?? [] {
            guard let id = raw["id"] as? Int else { continue }
            // isideload's TrustedNumber carries
            // #[serde(rename_all = "camelCase")], so the wire fields
            // are camelCase (numberWithDialCode, lastTwoDigits,
            // pushMode) — the same as the top-level prompt fields.
            // snake_case is kept only as a fallback for older cores.
            numbers.append(TwoFactorNumber(
                id: id,
                numberWithDialCode: (raw["numberWithDialCode"] as? String)
                    ?? (raw["number_with_dial_code"] as? String) ?? "",
                lastTwoDigits: (raw["lastTwoDigits"] as? String)
                    ?? (raw["last_two_digits"] as? String) ?? "",
                pushMode: (raw["pushMode"] as? String)
                    ?? (raw["push_mode"] as? String) ?? ""
            ))
        }
        // isideload's TwoFactorCallbackParams carries
        // #[serde(rename_all = "camelCase")] on its own fields, so the
        // top-level keys are camelCase. Read the camelCase key first,
        // snake_case as a fallback.
        return TwoFactorPrompt(
            unknown: prompt["unknown"] as? Bool ?? false,
            sms: prompt["sms"] as? Bool ?? false,
            lastError: (prompt["lastError"] as? String)
                ?? (prompt["last_error"] as? String),
            numbers: numbers,
            selectedNumberID: (prompt["selectedNumberId"] as? Int)
                ?? (prompt["selected_number_id"] as? Int)
        )
    }
}

public enum TwoFactorResponse: Equatable, Sendable {
    case code(String)
    case sms(id: Int)
    case devices
    case resend
    case abort

    func jsonString() throws -> String {
        let object: [String: Any]
        switch self {
        case .code(let code):
            guard code.count == 6, code.allSatisfy(\.isNumber) else {
                throw AppleRefreshError.invalidArgument(
                    reason: "The verification code must be 6 digits.")
            }
            object = ["action": "code", "code": code]
        case .sms(let id): object = ["action": "sms", "id": id]
        case .devices: object = ["action": "devices"]
        case .resend: object = ["action": "resend"]
        case .abort: object = ["action": "abort"]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppleRefreshError.internalError(reason: "Could not encode the two-factor answer.")
        }
        return text
    }
}

// MARK: - Client protocol (test seam)

/// The FFI surface the sign-in use case drives. The concrete
/// `AppleRefreshClient` talks to the Rust core; tests substitute a
/// fake that returns canned envelopes.
public protocol AppleRefreshClientProtocol: AnyObject, Sendable {
    func createSession(config: AppleRefreshSessionConfig) async throws
    func provisionAnisette(forceReset: Bool) async throws
    func login(email: String, password: String,
               twoFactorHandler: @escaping @Sendable (TwoFactorPrompt) async -> TwoFactorResponse,
               timeout: TimeInterval) async throws -> AppleIDLoginResult
    func getAppToken(app: String, claim: AppleRefreshClaim?) async throws -> AppleRefreshAppToken
    func sessionInfo() throws -> AppleRefreshSessionInfo
    func resetAnisette() throws
    func cancel() throws
    func close()

    // MARK: - Developer services (Phase 2, same session handle)

    func listTeams() async throws -> [DeveloperTeam]
    func listDevices(teamID: String) async throws -> [DeveloperDevice]
    func ensureDevice(teamID: String, name: String, udid: String) async throws -> DeveloperDevice
    func listAppIDs(teamID: String) async throws -> DeveloperAppIDList
    func addAppID(teamID: String, name: String, identifier: String) async throws -> DeveloperAppID
    func listCertificates(teamID: String) async throws -> [DevelopmentCertificate]
    func createCertificate(teamID: String, machineName: String, email: String) async throws -> CreatedCertificate
    func revokeCertificate(teamID: String, serialNumber: String) async throws
    func downloadProfile(teamID: String, appID: String) async throws -> DeveloperProfile
}

// MARK: - Client

/// Swift wrapper over the Rust Apple-refresh core
/// (`RustCore/apple_refresh/include/AppleRefreshBridge.h`).
///
/// Threading discipline (design §5.5): every BLOCKING FFI call runs
/// on a detached background task, never the main thread and never the
/// caller's task. `login` stays blocked on its own task while this
/// class polls `poll_prompt` every 250 ms and answers through the
/// two-factor handler. One client = one live login at a time.
///
/// The session handle is owned by this object. `close()` frees it,
/// but must not be called while a blocking call is in flight — the
/// class tracks in-flight calls and skips the free (leaking the Rust
/// session) rather than freeing under a live call. `deinit` does the
/// same. The password buffer is zeroed by Rust on return and is
/// never logged or persisted by this class.
public final class AppleRefreshClient: AppleRefreshClientProtocol, @unchecked Sendable {

    /// Swift-side timeout for a login / app-token call (design Q11:
    /// isideload sets no GSA timeout, so Swift imposes its own and
    /// calls `cancel`; a login stuck in a bare socket read returns
    /// only on the OS TCP timeout, and the session is dead after).
    public static let defaultTimeout: TimeInterval = 120

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var closed = false
    private var inFlight = 0

    public init() {}

    deinit { freeIfIdle() }

    // MARK: - Version

    public static func version() -> String {
        String(cString: apple_refresh_version())
    }

    // MARK: - Session lifecycle

    public func createSession(config: AppleRefreshSessionConfig) async throws {
        let configText = try config.jsonString()
        try await runBlocking { [self] in
            var rawSession: OpaquePointer? = nil
            let json = try Self.callJSON(step: "session_new") { outJSON in
                configText.withCString { cConfig in
                    apple_refresh_session_new(cConfig, &rawSession, outJSON)
                }
            }
            guard let rawSession else {
                throw AppleRefreshError.internalError(
                    reason: "The Apple Refresh core created no session.")
            }
            self.lock.lock()
            self.handle = rawSession
            self.closed = false
            self.lock.unlock()
            _ = json
        }
    }

    public func provisionAnisette(forceReset: Bool) async throws {
        try await runBlocking { [self] in
            let session = try self.rawSession()
            _ = try Self.callJSON(step: "provision_anisette") { outJSON in
                apple_refresh_provision_anisette(session, forceReset ? 1 : 0, outJSON)
            }
        }
    }

    public func resetAnisette() throws {
        let session = try rawSession()
        _ = try Self.callJSON(step: "reset_anisette") { outJSON in
            apple_refresh_reset_anisette(session, outJSON)
        }
    }

    public func cancel() throws {
        let session = try rawSession()
        _ = try Self.callJSON(step: "cancel") { outJSON in
            apple_refresh_cancel(session, outJSON)
        }
    }

    public func close() {
        freeIfIdle()
    }

    // MARK: - Login (blocking + poll loop)

    public func login(email: String, password: String,
                      twoFactorHandler: @escaping @Sendable (TwoFactorPrompt) async -> TwoFactorResponse,
                      timeout: TimeInterval = defaultTimeout) async throws -> AppleIDLoginResult {
        let loginTask = Task.detached(priority: .userInitiated) { [self] in
            try self.loginBlocking(email: email, password: password)
        }
        let deadline = Date().addingTimeInterval(timeout)
        do {
            return try await withThrowingTaskGroup(of: AppleIDLoginResult.self) { group in
                group.addTask { try await loginTask.value }
                group.addTask {
                    while true {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        if let prompt = try self.pollPrompt() {
                            let response = await twoFactorHandler(prompt)
                            try self.respond2FA(response)
                        }
                        if Date() > deadline {
                            try? self.cancel()
                            throw AppleRefreshError.timeout
                        }
                        if Task.isCancelled { throw CancellationError() }
                    }
                }
                guard let result = try await group.next() else {
                    throw AppleRefreshError.internalError(
                        reason: "Sign-in ended without a result.")
                }
                group.cancelAll()
                return result
            }
        } catch {
            loginTask.cancel()
            throw error
        }
    }

    private func loginBlocking(email: String, password: String) throws -> AppleIDLoginResult {
        let session = try rawSession()
        let json = try Self.callJSON(step: "login") { outJSON in
            email.withCString { cEmail in
                password.withCString { cPassword in
                    apple_refresh_login(session, cEmail, cPassword, outJSON)
                }
            }
        }
        return AppleIDLoginResult.from(json: json)
    }

    // MARK: - Two-factor (non-blocking)

    private func pollPrompt() throws -> TwoFactorPrompt? {
        let session = try rawSession()
        let json = try Self.callRawJSON(step: "poll_prompt") { outJSON in
            apple_refresh_poll_prompt(session, outJSON)
        }
        return TwoFactorPrompt.fromOrFallback(json: json)
    }

    private func respond2FA(_ response: TwoFactorResponse) throws {
        let responseText = try response.jsonString()
        let session = try rawSession()
        _ = try Self.callJSON(step: "respond_2fa") { outJSON in
            responseText.withCString { cResponse in
                apple_refresh_respond_2fa(session, cResponse, outJSON)
            }
        }
    }

    // MARK: - App token + info (non-blocking except get_app_token)

    public func getAppToken(app: String, claim: AppleRefreshClaim?) async throws -> AppleRefreshAppToken {
        let claimText: String?
        if let claim {
            let object = try claim.jsonObject()
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AppleRefreshError.internalError(reason: "Could not encode the claim.")
            }
            claimText = text
        } else {
            claimText = nil
        }
        return try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "get_app_token") { outJSON in
                app.withCString { cApp in
                    if let claimText {
                        return claimText.withCString { cClaim in
                            apple_refresh_get_app_token(session, cApp, cClaim, outJSON)
                        }
                    }
                    return apple_refresh_get_app_token(session, cApp, nil, outJSON)
                }
            }
            return AppleRefreshAppToken.from(json: json)
        }
    }

    public func sessionInfo() throws -> AppleRefreshSessionInfo {
        let session = try rawSession()
        let json = try Self.callJSON(step: "session_info") { outJSON in
            apple_refresh_session_info(session, outJSON)
        }
        return AppleRefreshSessionInfo.from(json: json)
    }

    // MARK: - Developer services (Phase 2, same session handle)

    /// All of these are BLOCKING network calls on the Rust side, so
    /// each runs on a detached task like `getAppToken`. They all
    /// require a login on this handle (`not_signed_in` otherwise).

    public func listTeams() async throws -> [DeveloperTeam] {
        try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "list_teams") { outJSON in
                apple_refresh_list_teams(session, outJSON)
            }
            return (json["teams"] as? [[String: Any]] ?? []).map(DeveloperTeam.from(json:))
        }
    }

    public func listDevices(teamID: String) async throws -> [DeveloperDevice] {
        try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "list_devices") { outJSON in
                teamID.withCString { cTeam in
                    apple_refresh_list_devices(session, cTeam, outJSON)
                }
            }
            return (json["devices"] as? [[String: Any]] ?? []).map(DeveloperDevice.from(json:))
        }
    }

    public func ensureDevice(teamID: String, name: String, udid: String) async throws -> DeveloperDevice {
        let request = try Self.requestJSONString(["team_id": teamID, "name": name, "udid": udid])
        return try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "ensure_device") { outJSON in
                request.withCString { cRequest in
                    apple_refresh_ensure_device(session, cRequest, outJSON)
                }
            }
            guard let device = json["device"] as? [String: Any] else {
                throw AppleRefreshError.internalError(reason: "Apple returned no device for ensure_device.")
            }
            return DeveloperDevice.from(json: device)
        }
    }

    public func listAppIDs(teamID: String) async throws -> DeveloperAppIDList {
        try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "list_app_ids") { outJSON in
                teamID.withCString { cTeam in
                    apple_refresh_list_app_ids(session, cTeam, outJSON)
                }
            }
            return DeveloperAppIDList.from(json: json)
        }
    }

    public func addAppID(teamID: String, name: String, identifier: String) async throws -> DeveloperAppID {
        let request = try Self.requestJSONString(["team_id": teamID, "name": name, "identifier": identifier])
        return try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "add_app_id") { outJSON in
                request.withCString { cRequest in
                    apple_refresh_add_app_id(session, cRequest, outJSON)
                }
            }
            guard let appID = json["app_id"] as? [String: Any] else {
                throw AppleRefreshError.internalError(reason: "Apple returned no App ID for add_app_id.")
            }
            return DeveloperAppID.from(json: appID)
        }
    }

    public func listCertificates(teamID: String) async throws -> [DevelopmentCertificate] {
        try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "list_certificates") { outJSON in
                teamID.withCString { cTeam in
                    apple_refresh_list_certificates(session, cTeam, outJSON)
                }
            }
            return (json["certificates"] as? [[String: Any]] ?? []).map(DevelopmentCertificate.from(json:))
        }
    }

    public func createCertificate(teamID: String, machineName: String, email: String) async throws -> CreatedCertificate {
        let request = try Self.requestJSONString(["team_id": teamID, "machine_name": machineName, "email": email])
        return try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "create_certificate") { outJSON in
                request.withCString { cRequest in
                    apple_refresh_create_certificate(session, cRequest, outJSON)
                }
            }
            return try CreatedCertificate.from(json: json)
        }
    }

    public func revokeCertificate(teamID: String, serialNumber: String) async throws {
        let request = try Self.requestJSONString(["team_id": teamID, "serial_number": serialNumber])
        try await runBlocking { [self] in
            let session = try self.rawSession()
            _ = try Self.callJSON(step: "revoke_certificate") { outJSON in
                request.withCString { cRequest in
                    apple_refresh_revoke_certificate(session, cRequest, outJSON)
                }
            }
        }
    }

    public func downloadProfile(teamID: String, appID: String) async throws -> DeveloperProfile {
        let request = try Self.requestJSONString(["team_id": teamID, "app_id_id": appID])
        return try await runBlocking { [self] in
            let session = try self.rawSession()
            let json = try Self.callJSON(step: "download_profile") { outJSON in
                request.withCString { cRequest in
                    apple_refresh_download_profile(session, cRequest, outJSON)
                }
            }
            guard let profile = json["profile"] as? [String: Any] else {
                throw AppleRefreshError.internalError(reason: "Apple returned no profile for download_profile.")
            }
            return try DeveloperProfile.from(json: profile)
        }
    }

    // MARK: - Private helpers

    private func rawSession() throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !closed else {
            throw AppleRefreshError.internalError(reason: "No live Apple Refresh session.")
        }
        return handle
    }

    private func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        lock.lock()
        inFlight += 1
        lock.unlock()
        defer {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
        return try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    private func freeIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !closed, inFlight == 0 else { return }
        apple_refresh_session_free(handle)
        self.handle = nil
        closed = true
    }

    /// Encodes a small request object for the `request_json`
    /// FFI arguments (dev calls). Throws rather than producing
    /// an empty string — Rust would reject it as invalid anyway.
    private static func requestJSONString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppleRefreshError.internalError(reason: "Could not encode the request.")
        }
        return text
    }

    /// Runs one FFI call, decodes the `{"ok": …}` envelope, and
    /// throws the mapped error when `ok` is false. The JSON string
    /// is always freed with `apple_refresh_string_free`.
    private static func callJSON(step: String,
                                 _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) throws -> [String: Any] {
        let json = try callRawJSON(step: step, body)
        if json["ok"] as? Bool == true { return json }
        throw AppleRefreshError.from(json: json, step: step)
    }

    /// Same as `callJSON` but without the `ok` check — `poll_prompt`
    /// answers `{"pending": …}` instead of the envelope.
    private static func callRawJSON(step: String,
                                    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) throws -> [String: Any] {
        var outJSON: UnsafeMutablePointer<CChar>? = nil
        let code = body(&outJSON)
        defer { if let outJSON { apple_refresh_string_free(outJSON) } }
        guard let outJSON else {
            throw AppleRefreshError.internalError(
                reason: "The Apple Refresh core returned no result for \(step).")
        }
        let text = String(cString: outJSON)
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppleRefreshError.internalError(
                reason: "The Apple Refresh core returned unreadable JSON for \(step).")
        }
        if code != 0, json["error"] == nil {
            throw AppleRefreshError.internalError(
                reason: "The Apple Refresh core failed at \(step) (code \(code)) without an error object.")
        }
        return json
    }
}

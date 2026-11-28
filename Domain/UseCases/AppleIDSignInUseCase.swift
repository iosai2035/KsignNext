import Foundation

/// Drives a Phase 1 Apple ID sign-in through the Rust core and owns
/// the retry + backoff policy (design §5.5, research doc §7):
///
/// Attempt order — the claim is the variable Apple reacts to, so the
/// claims are tried first: `sideinstaller` (macOS 10.15.7, "Mac OS
/// X" — the variant Apple currently lets through), then `apparition`
/// (macOS 27), then the anisette server's own claim; each on up to 2
/// anisette servers. Which claim + server succeeded is recorded on
/// the session, so the next sign-in can start there.
///
/// Never retried: a rejected password, a locked account, too many
/// requests, a cancelled/aborted 2FA, or an invalid argument — those
/// throw immediately. A rejected password is removed from the
/// Keychain; the second consecutive rejection pauses sign-ins for
/// this Apple ID for 15 minutes; a locked account pauses at once.
///
/// The app token (`com.apple.gs.xcode.auth`) is fetched with the
/// sign-in claim first and retried with the other Mac claim —
/// apptokens must claim a Mac or Apple answers -80046 (design Q4).
/// The token VALUE never crosses to Swift; only `has_token` is kept.
///
/// The signed-in client is RETAINED after a successful sign-in
/// (Phase 2): the live Rust session on that handle is what the
/// developer-services calls run on, so closing it here would kill
/// the real refresh. It is closed on sign-out, on a fresh sign-in,
/// and by `closeSignedInClient()`. The password is never held here
/// — it lives in the Keychain through the store.
/// One sign-in attempt, reported to the UI so a multi-attempt
/// sign-in is never a silent spinner: the user sees which claim and
/// server is being tried and how many attempts remain. A sign-in
/// that stalls before the 2FA prompt shows its progress instead of
/// an endless spinner with no explanation.
public struct SignInAttemptProgress: Sendable, Equatable {
    public let attempt: Int
    public let totalAttempts: Int
    public let claimPreset: String
    public let serverHost: String

    public init(attempt: Int, totalAttempts: Int, claimPreset: String, serverHost: String) {
        self.attempt = attempt
        self.totalAttempts = totalAttempts
        self.claimPreset = claimPreset
        self.serverHost = serverHost
    }
}

public final class AppleIDSignInUseCase: @unchecked Sendable {

    public static let xcodeAuthApp = "com.apple.gs.xcode.auth"

    private let store: AppleIDSessionStore
    private let servers: AnisetteServerProvider
    private let clientFactory: @Sendable () -> any AppleRefreshClientProtocol
    /// Visible app log: every attempt failure is logged here (with
    /// the real underlying error, e.g. Apple's ec/em) so the next
    /// live sign-in failure can be diagnosed from Logs instead of a
    /// bare spinner — the 2FA diagnosis (deep dive Pass 1, 2FA-1).
    private let logs: LogsManager
    private let lock = NSLock()
    private var currentClient: (any AppleRefreshClientProtocol)?
    private var _signedInClient: (any AppleRefreshClientProtocol)?

    /// The live client of the current sign-in, if any — the handle
    /// the developer-services calls (teams, certificates, profiles)
    /// run on. Nil when signed out or before the first sign-in.
    public var signedInClient: (any AppleRefreshClientProtocol)? {
        lock.lock()
        defer { lock.unlock() }
        return _signedInClient
    }

    public init(store: AppleIDSessionStore = AppleIDSessionStore(),
                servers: AnisetteServerProvider = AnisetteServerProvider(),
                clientFactory: @escaping @Sendable () -> any AppleRefreshClientProtocol = { AppleRefreshClient() },
                logs: LogsManager = .shared) {
        self.store = store
        self.servers = servers
        self.clientFactory = clientFactory
        self.logs = logs
    }

    // MARK: - State

    public var currentSession: AppleIDSession? { store.loadSession() }
    public var pauseUntil: Date? { store.pauseUntil() }
    public var savedEmail: String? { store.savedEmail }

    /// The saved Apple ID password from the Keychain, if the user
    /// signed in before and the password was kept. Nil when the
    /// user never signed in or the password was cleared (e.g. after
    /// a rejection). Used by the real refresh to sign in silently.
    public func savedPassword() -> String? {
        guard let email = store.savedEmail else { return nil }
        return store.loadPassword(email: email)
    }

    /// Asks the in-flight login to stop at the next 2FA boundary.
    /// The session is dead after a cancel — the next sign-in creates
    /// a fresh one. Safe to call when nothing is signing in.
    public func cancelCurrentSignIn() {
        lock.lock()
        let client = currentClient
        lock.unlock()
        try? client?.cancel()
    }

    public func signOut() {
        store.clearSession()
        closeSignedInClient()
    }

    /// Closes the retained signed-in client (and drops it). The
    /// Rust session dies with it; the next developer-services call
    /// needs a fresh sign-in. Safe to call when nothing is signed in.
    public func closeSignedInClient() {
        lock.lock()
        let client = _signedInClient
        _signedInClient = nil
        lock.unlock()
        client?.close()
    }

    // MARK: - Sign-in

    /// - Parameters:
    ///   - onAttempt: called before every claim/server attempt with
    ///     its progress (attempt N of M, claim, server). Nil by
    ///     default; the sign-in screen wires it to a status line so
    ///     the user always sees what the app is trying.
    ///   - onAttemptError: called with the real error of every failed
    ///     attempt, before the retry decision. Nil by default; the
    ///     sign-in screen wires it to the same status line so a
    ///     failure is visible live instead of only after all
    ///     attempts fail (2FA-1 diagnostic).
    public func signIn(email: String, password: String,
                       claimOverride: AppleRefreshClaim? = nil,
                       twoFactorHandler: @escaping @Sendable (TwoFactorPrompt) async -> TwoFactorResponse,
                       onAttempt: (@Sendable (SignInAttemptProgress) -> Void)? = nil,
                       onAttemptError: (@Sendable (AppleRefreshError) -> Void)? = nil) async throws -> AppleIDSession {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, email.contains("@"), email.contains(".") else {
            throw AppleRefreshError.invalidArgument(reason: "Enter a valid Apple ID email address.")
        }
        guard !password.isEmpty else {
            throw AppleRefreshError.invalidArgument(reason: "Enter your Apple ID password.")
        }
        if let until = store.pauseUntil() {
            throw AppleRefreshError.paused(until: until)
        }
        // A fresh sign-in replaces the retained client, if any —
        // its Rust session (and DeveloperSession) dies with it.
        closeSignedInClient()

        let claims: [AppleRefreshClaim] = claimOverride.map { [$0] }
            ?? [.sideinstaller, .apparition, .server]
        let serversToTry = servers.serversToTry()
        let totalAttempts = max(1, serversToTry.count * claims.count)
        var attemptNumber = 0
        var lastError: AppleRefreshError?
        for server in serversToTry {
            for claim in claims {
                attemptNumber += 1
                onAttempt?(SignInAttemptProgress(
                    attempt: attemptNumber,
                    totalAttempts: totalAttempts,
                    claimPreset: claim.presetName,
                    serverHost: URL(string: server)?.host ?? server))
                let client = clientFactory()
                lock.lock(); currentClient = client; lock.unlock()
                do {
                    let config = AppleRefreshSessionConfig(
                        anisetteServerURL: server,
                        storageDirectory: store.storageDirectory,
                        signInClaim: claim)
                    try await client.createSession(config: config)
                    try await client.provisionAnisette(forceReset: false)
                    let login = try await client.login(
                        email: email, password: password,
                        twoFactorHandler: twoFactorHandler,
                        timeout: AppleRefreshClient.defaultTimeout)
                    let tokenProven = try await proveAppToken(client: client, claim: claim)
                    guard tokenProven else {
                        // Signed in, but Apple issued no Xcode token —
                        // the session would be useless for the real
                        // refresh, so try the next claim instead of
                        // saving a half-working session.
                        throw AppleRefreshError.appleAuth(
                            appleEC: nil, appleEM: nil,
                            message: "Apple issued no Xcode token for this sign-in.")
                    }
                    let session = AppleIDSession(
                        email: login.email.isEmpty ? email : login.email,
                        firstName: login.firstName,
                        lastName: login.lastName,
                        adsid: login.adsid,
                        serverURL: server,
                        claimPreset: claim.presetName,
                        signedInAt: Date(),
                        appTokenProven: tokenProven)
                    store.saveSession(session, password: password)
                    store.resetRejections()
                    // Retain the live client: its Rust session is
                    // what the Phase 2 developer-services calls run
                    // on. Closed by signOut / the next sign-in /
                    // closeSignedInClient().
                    lock.lock()
                    _signedInClient = client
                    lock.unlock()
                    clearCurrentClient(client)
                    return session
                } catch let error as AppleRefreshError {
                    client.close()
                    clearCurrentClient(client)
                    lastError = error
                    // Diagnostic (2FA-1): surface the real failure
                    // live — in the visible log and on the sign-in
                    // screen via onAttemptError — instead of silently
                    // retrying the next claim/server. The final throw
                    // below already surfaces the last error; this is
                    // what makes each earlier failure visible too.
                    await logs.error("Sign-in attempt \(attemptNumber)/\(totalAttempts) failed (\(claim.presetName) @ \(URL(string: server)?.host ?? server)): \(error.localizedDescription)")
                    onAttemptError?(error)
                    switch error {
                    case .wrongPassword:
                        // Never retry a rejected password on another
                        // claim or server — it is definitive.
                        store.clearPassword(email: email)
                        let count = store.recordRejection()
                        if count >= 2 {
                            store.pause()
                        }
                        throw error
                    case .accountLocked:
                        store.clearPassword(email: email)
                        store.pause()
                        throw error
                    case .tooManyRequests:
                        store.pause()
                        throw error
                    case .twoFactorAborted, .cancelled, .invalidArgument:
                        throw error
                    case .appleAuth, .server503, .anisetteUnavailable,
                         .anisetteProvision, .network, .tls, .timeout:
                        // The claim/server is the variable: try the next one.
                        continue
                    case .unavailable, .noPromptPending, .paused, .internalError,
                         .notSignedIn, .developerError:
                        // These two cannot occur during sign-in itself
                        // (they come from the Phase 2 developer-service
                        // calls), but the switch must stay exhaustive.
                        throw error
                    }
                } catch {
                    client.close()
                    clearCurrentClient(client)
                    throw AppleRefreshError.internalError(reason: error.localizedDescription)
                }
            }
        }
        throw lastError ?? AppleRefreshError.internalError(
            reason: "Sign-in failed on every anisette server and claim tried.")
    }

    // MARK: - Private helpers

    private func clearCurrentClient(_ client: any AppleRefreshClientProtocol) {
        lock.lock()
        if currentClient === client { currentClient = nil }
        lock.unlock()
    }

    /// Fetches the Xcode app token with the sign-in claim, then with
    /// the other Mac claim (design Q4). Throws when both fail; returns
    /// `has_token` otherwise.
    private func proveAppToken(client: any AppleRefreshClientProtocol,
                               claim: AppleRefreshClaim) async throws -> Bool {
        do {
            let token = try await client.getAppToken(app: Self.xcodeAuthApp, claim: claim)
            return token.hasToken
        } catch {
            let other: AppleRefreshClaim =
                (claim == .sideinstaller) ? .apparition : .sideinstaller
            let token = try await client.getAppToken(app: Self.xcodeAuthApp, claim: other)
            return token.hasToken
        }
    }
}

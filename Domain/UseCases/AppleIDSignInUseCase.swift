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
public final class AppleIDSignInUseCase: @unchecked Sendable {

    public static let xcodeAuthApp = "com.apple.gs.xcode.auth"

    private let store: AppleIDSessionStore
    private let servers: AnisetteServerProvider
    private let clientFactory: @Sendable () -> any AppleRefreshClientProtocol
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
                clientFactory: @escaping @Sendable () -> any AppleRefreshClientProtocol = { AppleRefreshClient() }) {
        self.store = store
        self.servers = servers
        self.clientFactory = clientFactory
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

    public func signIn(email: String, password: String,
                       claimOverride: AppleRefreshClaim? = nil,
                       twoFactorHandler: @escaping @Sendable (TwoFactorPrompt) async -> TwoFactorResponse) async throws -> AppleIDSession {
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
        var lastError: AppleRefreshError?
        for server in servers.serversToTry() {
            for claim in claims {
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
                    case .unavailable, .noPromptPending, .paused, .internalError:
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

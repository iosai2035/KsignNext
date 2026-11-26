import Foundation

/// Errors of the real refresh, on top of the errors the underlying
/// calls already throw (`AppleRefreshError` from the Rust core,
/// `AppError` from the engines).
public enum RealRefreshError: LocalizedError, Equatable {
    /// The user has not pasted this device's UDID yet (or it is
    /// malformed) — Apple cannot register the device without it.
    case missingUDID
    /// The account has no developer team to work on.
    case noTeams
    /// The certificate limit is hit; `teamID` is the team whose
    /// certificates the user can revoke from.
    case certificateLimit(teamID: String)
    /// No free App ID slot is left on the account.
    case appIDQuota(available: Int?)
    /// No saved Apple ID password — the user must sign in (with
    /// password + 2FA) before a real refresh can run.
    case signInRequired

    public var errorDescription: String? {
        switch self {
        case .missingUDID:
            return "Paste this device's UDID first — Apple needs it to register the device before issuing a fresh profile."
        case .noTeams:
            return "This Apple ID has no developer team."
        case .certificateLimit:
            return "Apple refused: the maximum number of development certificates for this account has been reached. Revoke an old certificate and try again."
        case .appIDQuota(let available):
            return "No free App ID slot is left on this account\(available.map { " (\($0) available)" } ?? ""). Delete an unused App ID at developer.apple.com and try again."
        case .signInRequired:
            return "Sign in with your Apple ID first — a real refresh needs a live sign-in."
        }
    }
}

/// What a completed real refresh produced.
public struct RealRefreshResult: Sendable {
    public let team: DeveloperTeam
    public let certificate: CertificateModel
    public let certificateReused: Bool
    public let profile: ProvisioningModel
    public let signedFileURL: URL
    public let profileExpirationDate: Date?
}

/// The full real refresh (research doc §11, Phase 2 + 3): on the
/// live signed-in client, pick the team, register this device,
/// reuse or create the development certificate, register the App
/// ID, download a FRESH provisioning profile from Apple, then
/// re-sign with that certificate + profile and hand the signed IPA
/// back for installation. The re-signing reuses the existing
/// `RefreshApplicationUseCase` plan + `SignApplicationUseCase`
/// pipeline — only the certificate and profile are new.
///
/// Sign-in: when no client is live, this signs in silently with
/// the saved email + Keychain password (the same credentials the
/// Settings sign-in saved). A 2FA prompt during that sign-in is
/// delivered through `twoFactorHandler`, exactly like the Settings
/// flow. When no saved password exists it throws
/// `.signInRequired` instead of inventing credentials.
///
/// The generated .p12 bytes are written to a temporary file only
/// long enough for `CertificateEngine.importP12` to copy them into
/// the store and the password into the Keychain; the temp files
/// (p12 + .mobileprovision) are deleted afterwards.
public final class RealRefreshUseCase: @unchecked Sendable {

    private let signInUseCase: AppleIDSignInUseCase
    private let developerService: DeveloperServiceUseCase
    private let certificateEngine: CertificateEngineProtocol
    private let certificateRepository: CertificateRepository
    private let refreshUseCase: RefreshApplicationUseCase
    private let signUseCase: SignApplicationUseCase

    public init(signInUseCase: AppleIDSignInUseCase,
                developerService: DeveloperServiceUseCase,
                certificateEngine: CertificateEngineProtocol,
                certificateRepository: CertificateRepository,
                refreshUseCase: RefreshApplicationUseCase,
                signUseCase: SignApplicationUseCase) {
        self.signInUseCase = signInUseCase
        self.developerService = developerService
        self.certificateEngine = certificateEngine
        self.certificateRepository = certificateRepository
        self.refreshUseCase = refreshUseCase
        self.signUseCase = signUseCase
    }

    /// Runs the whole refresh. `udid` is the pasted device UDID
    /// (40 hex chars); `deviceName` is the display name Apple
    /// records for the device. Progress strings are localized
    /// step labels for the UI; signing progress events are
    /// forwarded as their messages.
    public func execute(signedIPAURL: URL,
                        bundleID: String,
                        appName: String?,
                        udid: String,
                        deviceName: String,
                        twoFactorHandler: @escaping @Sendable (TwoFactorPrompt) async -> TwoFactorResponse,
                        onProgress: @escaping @Sendable (String) -> Void) async throws -> RealRefreshResult {
        guard let normalizedUDID = DeviceUDIDValidator.normalized(udid) else {
            throw RealRefreshError.missingUDID
        }

        // 1. Live sign-in (silent when saved credentials exist).
        if signInUseCase.signedInClient == nil {
            onProgress(NSLocalizedString("realrefresh.step.signin", comment: ""))
            guard let email = signInUseCase.savedEmail,
                  let password = signInUseCase.savedPassword() else {
                throw RealRefreshError.signInRequired
            }
            _ = try await signInUseCase.signIn(
                email: email, password: password,
                twoFactorHandler: twoFactorHandler)
        }
        guard let email = signInUseCase.savedEmail ?? signInUseCase.currentSession?.email else {
            throw RealRefreshError.signInRequired
        }

        // 2. Team (free accounts have exactly one).
        onProgress(NSLocalizedString("realrefresh.step.team", comment: ""))
        guard let team = try await developerService.firstTeam() else {
            throw RealRefreshError.noTeams
        }

        // 3. Register this device on the team.
        onProgress(NSLocalizedString("realrefresh.step.device", comment: ""))
        _ = try await developerService.ensureDevice(
            teamID: team.teamID, name: deviceName, udid: normalizedUDID)

        // 4. Reuse or create the development certificate, then
        // import the .p12 into the Certificates store.
        onProgress(NSLocalizedString("realrefresh.step.certificate", comment: ""))
        let created: CreatedCertificate
        do {
            created = try await developerService.createCertificate(teamID: team.teamID, email: email)
        } catch let error as AppleRefreshError {
            if case .developerError(let ec, _, _) = error, ec == 7460 {
                throw RealRefreshError.certificateLimit(teamID: team.teamID)
            }
            throw error
        }
        let certificate: CertificateModel
        do {
            let tempDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let p12URL = tempDir.appendingPathComponent("KsignNext-Development.p12")
            try created.p12Data.write(to: p12URL, options: [.atomic])
            certificate = try await certificateEngine.importP12(at: p12URL, password: created.p12Password)
            // The signing engine resolves certificates from the
            // repository (not the file) — without this save the
            // fresh certificate is invisible to the signing step.
            try await certificateRepository.save(certificate)
        }

        // 5. App ID: reuse the registered one, else register it.
        onProgress(NSLocalizedString("realrefresh.step.appid", comment: ""))
        let appIDs = try await developerService.listAppIDs(teamID: team.teamID)
        let appID: DeveloperAppID
        if let existing = appIDs.appIDs.first(where: { $0.identifier == bundleID }) {
            appID = existing
        } else {
            guard appIDs.availableQuantity == nil || (appIDs.availableQuantity ?? 0) > 0 else {
                throw RealRefreshError.appIDQuota(available: appIDs.availableQuantity)
            }
            appID = try await developerService.addAppID(
                teamID: team.teamID,
                name: appName ?? bundleID,
                identifier: bundleID)
        }

        // 6. Fresh provisioning profile from Apple, imported into
        // the provisioning store.
        onProgress(NSLocalizedString("realrefresh.step.profile", comment: ""))
        let downloaded = try await developerService.downloadProfile(teamID: team.teamID, appID: appID.appID)
        let profile: ProvisioningModel
        do {
            let tempDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let profileURL = tempDir.appendingPathComponent(downloaded.filename.isEmpty ? "profile.mobileprovision" : downloaded.filename)
            try downloaded.encodedProfile.write(to: profileURL, options: [.atomic])
            profile = try await certificateEngine.importProvisioningProfile(at: profileURL)
        }

        // 7. Re-sign with the fresh certificate + profile, using
        // the existing refresh plan + signing pipeline.
        onProgress(NSLocalizedString("realrefresh.step.signing", comment: ""))
        let plan = try await refreshUseCase.planWithFreshProfile(
            signedIPAURL: signedIPAURL,
            certificateID: certificate.id,
            profile: profile)
        let result = try await signUseCase.execute(plan.request) { event in
            onProgress(event.message)
        }

        return RealRefreshResult(
            team: team,
            certificate: certificate,
            certificateReused: created.reused,
            profile: profile,
            signedFileURL: result.signedFileURL,
            profileExpirationDate: plan.profileExpirationDate)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ksign-realrefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

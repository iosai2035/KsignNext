import Foundation

/// Thin wrapper over the live signed-in client (owned by
/// `AppleIDSignInUseCase`). Every method throws
/// `AppleRefreshError.notSignedIn` when no sign-in is live —
/// callers surface that as "sign in first" instead of failing
/// opaquely inside the Rust core.
public final class DeveloperServiceUseCase: @unchecked Sendable {

    /// The machine name the on-device development certificate is
    /// registered under. Stable per install so a later run finds
    /// and reuses the same certificate instead of creating a new
    /// one each time (see `RustCore/apple_refresh/src/dev.rs`).
    public static let certificateMachineName = "KsignNext"

    private let signInUseCase: AppleIDSignInUseCase

    public init(signInUseCase: AppleIDSignInUseCase) {
        self.signInUseCase = signInUseCase
    }

    /// The live client, or `.notSignedIn` when nothing is signed in.
    public func client() throws -> any AppleRefreshClientProtocol {
        guard let client = signInUseCase.signedInClient else {
            throw AppleRefreshError.notSignedIn
        }
        return client
    }

    public func listTeams() async throws -> [DeveloperTeam] {
        try await client().listTeams()
    }

    /// The first team of the account (free accounts have exactly
    /// one). Nil when the account has no teams at all.
    public func firstTeam() async throws -> DeveloperTeam? {
        try await listTeams().first
    }

    public func listDevices(teamID: String) async throws -> [DeveloperDevice] {
        try await client().listDevices(teamID: teamID)
    }

    public func ensureDevice(teamID: String, name: String, udid: String) async throws -> DeveloperDevice {
        try await client().ensureDevice(teamID: teamID, name: name, udid: udid)
    }

    public func listAppIDs(teamID: String) async throws -> DeveloperAppIDList {
        try await client().listAppIDs(teamID: teamID)
    }

    public func addAppID(teamID: String, name: String, identifier: String) async throws -> DeveloperAppID {
        try await client().addAppID(teamID: teamID, name: name, identifier: identifier)
    }

    public func listCertificates(teamID: String) async throws -> [DevelopmentCertificate] {
        try await client().listCertificates(teamID: teamID)
    }

    public func createCertificate(teamID: String, email: String) async throws -> CreatedCertificate {
        try await client().createCertificate(
            teamID: teamID,
            machineName: Self.certificateMachineName,
            email: email)
    }

    public func revokeCertificate(teamID: String, serialNumber: String) async throws {
        try await client().revokeCertificate(teamID: teamID, serialNumber: serialNumber)
    }

    public func downloadProfile(teamID: String, appID: String) async throws -> DeveloperProfile {
        try await client().downloadProfile(teamID: teamID, appID: appID)
    }
}

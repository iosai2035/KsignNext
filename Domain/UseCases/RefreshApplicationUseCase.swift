import Foundation

// MARK: - RefreshApplicationUseCase
//
// In-app refresh: re-sign a signed app with the same certificate and
// provisioning profile it was signed with, then the caller installs
// the fresh file over loopback (no Wi-Fi, no SideStore, no computer).
//
// The profile is read from the signed IPA itself
// (`embedded.mobileprovision` inside the app bundle), so the exact
// profile used at signing time is reused — no guesswork, no stored
// profile id. The certificate comes from the persisted signing
// record (`SigningResult.certificateID`). The import is transient:
// the copied file and the extraction workspace are removed
// afterwards, so refreshing never leaves a stray copy in the
// Applications list.
//
// Honest limit: a refresh only extends the signature while the stored
// profile is still valid. A free Apple ID profile expires 7 days
// after creation; once it is expired, refresh refuses with a typed
// error and a fresh profile must be imported (from Xcode or from
// Apple's servers) before signing again. A paid developer profile
// lasts a year, so refresh works for a year with no Apple contact.

// MARK: - Errors

/// Failures while planning a refresh. All cases are typed so the UI
/// can show exactly what is missing instead of a generic failure.
public enum RefreshError: Error, LocalizedError, Equatable {
    case noSigningRecord(String)
    case certificateNotFound
    case profileNotFound
    case profileExpired(Date)
    case profileMismatch(String)
    case invalidIPA(String)

    public var errorDescription: String? {
        switch self {
        case .noSigningRecord(let name):
            return "No signing record for \(name): sign it from the Signing tab first, then refresh."
        case .certificateNotFound:
            return "The certificate used to sign this app is no longer imported. Import it again in Certificates."
        case .profileNotFound:
            return "The provisioning profile used to sign this app was not found inside the IPA."
        case .profileExpired(let date):
            return "The provisioning profile expired on \(date). Import a fresh profile in Certificates, then sign again."
        case .profileMismatch(let detail):
            return "The provisioning profile does not match this app: \(detail)"
        case .invalidIPA(let detail):
            return "Could not read the signed app: \(detail)"
        }
    }
}

// MARK: - Plan

/// A refresh ready to run: the signing request that re-signs the app
/// with the same certificate and profile, plus the profile's expiry
/// for display.
public struct RefreshPlan: Sendable, Equatable {
    public let request: SigningRequest
    public let profileExpirationDate: Date?
    public let certificateID: UUID?

    public init(request: SigningRequest, profileExpirationDate: Date?, certificateID: UUID?) {
        self.request = request
        self.profileExpirationDate = profileExpirationDate
        self.certificateID = certificateID
    }
}

// MARK: - Use case

/// Builds refresh plans for signed apps. Signing itself runs through
/// `SignApplicationUseCase`; installing the fresh file runs through
/// `InstallationEngine` — this use case only resolves and validates
/// what the refresh needs.
public final class RefreshApplicationUseCase {

    private let signedRepository: SignedApplicationRepository
    private let certificateRepository: CertificateRepository
    private let provisioningEngine: ProvisioningEngine
    private let ipaEngine: IPAEngineProtocol

    public init(
        signedRepository: SignedApplicationRepository,
        certificateRepository: CertificateRepository,
        provisioningEngine: ProvisioningEngine,
        ipaEngine: IPAEngineProtocol
    ) {
        self.signedRepository = signedRepository
        self.certificateRepository = certificateRepository
        self.provisioningEngine = provisioningEngine
        self.ipaEngine = ipaEngine
    }

    /// Reads the embedded provisioning profile of a signed IPA and
    /// returns its expiration date. Nil when the IPA has no embedded
    /// profile (e.g. ad-hoc signed). Throws `RefreshError.invalidIPA`
    /// when the file cannot be read at all.
    public func profileExpiration(signedIPAURL: URL) async throws -> Date? {
        let profile = try await embeddedProfile(signedIPAURL: signedIPAURL)
        return profile?.expirationDate
    }

    /// Builds the signing request that re-signs `signedIPAURL` with the
    /// same certificate and provisioning profile recorded at signing
    /// time. The signed IPA itself is the signing input — the engine
    /// removes the old signature first (`removeOriginalSignature` is
    /// on by default in `SigningConfiguration`).
    ///
    /// Throws `RefreshError.noSigningRecord` when the app has no
    /// signing record, `.certificateNotFound` when its certificate is
    /// gone, `.profileNotFound` / `.profileExpired` / `.profileMismatch`
    /// when the embedded profile cannot be reused.
    public func plan(signedIPAURL: URL) async throws -> RefreshPlan {
        let fileName = signedIPAURL.lastPathComponent
        let records = (try? await signedRepository.fetchAll()) ?? []
        guard let record = records.first(where: { $0.signedFileURL.lastPathComponent == fileName }) else {
            throw RefreshError.noSigningRecord(fileName)
        }
        if let certificateID = record.certificateID {
            guard try await certificateRepository.fetch(id: certificateID) != nil else {
                throw RefreshError.certificateNotFound
            }
        }
        guard let profile = try await embeddedProfile(signedIPAURL: signedIPAURL) else {
            throw RefreshError.profileNotFound
        }
        if profile.isExpired {
            throw RefreshError.profileExpired(profile.expirationDate ?? Date.distantPast)
        }
        guard profile.allows(bundleID: record.bundleIdentifier) else {
            throw RefreshError.profileMismatch("profile allows \(profile.bundleIdentifier), app is \(record.bundleIdentifier)")
        }
        let configuration = SigningConfiguration(
            certificateID: record.certificateID,
            provisioningProfileID: profile.id,
            bundleIdentifier: record.bundleIdentifier,
            displayName: nil,
            version: record.version.isEmpty ? nil : record.version,
            verifyAfterSigning: false
        )
        let request = SigningRequest(
            importedIPAID: record.importedIPAID,
            sourceURL: signedIPAURL,
            configuration: configuration
        )
        return RefreshPlan(
            request: request,
            profileExpirationDate: profile.expirationDate,
            certificateID: record.certificateID
        )
    }

    /// Extracts the embedded provisioning profile from a signed IPA.
    /// Returns nil when the IPA has no embedded profile (ad-hoc).
    /// The import is transient: the copied file and the extraction
    /// workspace are removed afterwards.
    private func embeddedProfile(signedIPAURL: URL) async throws -> ProvisioningModel? {
        let imported: ImportedIPA
        do {
            imported = try await ipaEngine.importIPA(from: signedIPAURL)
        } catch {
            throw RefreshError.invalidIPA(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: imported.fileURL) }
        let extracted: ExtractedIPA
        do {
            extracted = try await ipaEngine.extractIPA(imported)
        } catch {
            throw RefreshError.invalidIPA(error.localizedDescription)
        }
        defer { Task { try? await ipaEngine.cleanupWorkspace(for: imported.id) } }
        guard let bundleURL = extracted.primaryAppBundleURL else { return nil }
        let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return nil }
        do {
            return try await provisioningEngine.parseProvisioningProfile(at: profileURL)
        } catch {
            throw RefreshError.invalidIPA(error.localizedDescription)
        }
    }
}

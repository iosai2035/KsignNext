import Foundation

/// Dashboard expiry list: every stored provisioning profile, sorted
/// by expiration date ascending with expired profiles first.
///
/// Expiry always comes from the provisioning engine, never from a raw
/// plist read: each stored profile whose file still exists is
/// re-parsed through the engine and the freshly parsed expiration
/// date is used. When a file can no longer be parsed (missing or
/// unreadable), the stored expiration date is kept so one bad file
/// never breaks the whole dashboard list. Profiles with no expiration
/// date known sort last — an unknown expiry is not an expired one.
public struct FetchExpiringProfilesUseCase: Sendable {
    private let repository: ProvisioningProfileRepository
    private let engine: ProvisioningEngineProtocol

    public init(
        repository: ProvisioningProfileRepository,
        engine: ProvisioningEngineProtocol
    ) {
        self.repository = repository
        self.engine = engine
    }

    public func execute() async throws -> [ProvisioningModel] {
        let stored = try await repository.fetchAll()
        var refreshed: [ProvisioningModel] = []
        refreshed.reserveCapacity(stored.count)
        for profile in stored {
            guard let fileURL = profile.fileURL else {
                refreshed.append(profile)
                continue
            }
            do {
                let parsed = try await engine.parseProvisioningProfile(at: fileURL)
                var current = profile
                current.expirationDate = parsed.expirationDate
                refreshed.append(current)
            } catch {
                // Keep the stored record: a missing or unreadable
                // file must not drop the profile from the list.
                refreshed.append(profile)
            }
        }
        return refreshed.sorted { lhs, rhs in
            guard let lhsDate = lhs.expirationDate else { return false }
            guard let rhsDate = rhs.expirationDate else { return true }
            return lhsDate < rhsDate
        }
    }
}

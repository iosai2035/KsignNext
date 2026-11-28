import Foundation

/// Dashboard state (contract §C.2). Expiry comes from
/// `FetchExpiringProfilesUseCase` (W-2: never raw plist reads);
/// activity comes from the single `AppLogger` source (W-4); counts
/// come from the repositories. Every read failure is surfaced in
/// `errorMessage` — there is no dead alert and no silent empty list.
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var expiringProfiles: [ProvisioningModel] = []
    @Published var recentActivity: [LogEntry] = []
    @Published var activityError: String?
    @Published var certificateCount = 0
    @Published var profileCount = 0
    @Published var freeSpaceBytes: Int64?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let container: DependencyContainer

    init(container: DependencyContainer) {
        self.container = container
    }

    /// Expiry banners for profiles that need attention (contract
    /// §B.11): expired, expiring today, or expiring within 3 days.
    /// The list is already sorted nearest-first by the use case.
    var banners: [ProvisioningModel] {
        expiringProfiles.filter { profile in
            guard let days = profile.daysUntilExpiration else { return false }
            return days <= 3
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let useCase = try container.makeFetchExpiringProfilesUseCase()
            expiringProfiles = try await useCase.execute()
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            let certificateRepository = try container.resolveCertificateRepository()
            let certificates = try await certificateRepository.fetchAll()
            certificateCount = certificates.count
            let profileRepository = try container.resolveProvisioningProfileRepository()
            let profiles = try await profileRepository.fetchAll()
            profileCount = profiles.count
        } catch {
            errorMessage = error.localizedDescription
        }
        freeSpaceBytes = FileSystemManager.shared.freeSpaceBytes()
        await loadActivity()
    }

    /// Last 10 log entries, newest first. The `AppLogger` read is
    /// the single log source; a failure here is shown as an error
    /// row in the activity section, never as an empty list (W-4).
    /// The current `AppLogger` read API is non-throwing, so the
    /// error path is defensive — it fires if a future read throws.
    private func loadActivity() async {
        activityError = nil
        do {
            let entries = try await loadActivityEntries()
            recentActivity = Array(entries.suffix(10).reversed())
        } catch {
            activityError = error.localizedDescription
            recentActivity = []
        }
    }

    private func loadActivityEntries() async throws -> [LogEntry] {
        await AppLogger.shared.allEntries()
    }
}

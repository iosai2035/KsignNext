import Foundation

/// Kind of a provisioning profile, derived from its contents by the
/// provisioning engine (`ProvisionsAllDevices` / device list /
/// `get-task-allow` heuristic).
public enum ProvisioningKind: String, Codable, CaseIterable, Sendable {
    case development
    case adhoc
    case appStore
    case enterprise
    case unknown
}

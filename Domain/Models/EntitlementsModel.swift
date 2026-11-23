import Foundation

/// Structured entitlements: the plist dictionary decoded into typed
/// values. Unknown keys are preserved as strings so a round-trip
/// never silently drops an entitlement.
public struct EntitlementsModel: Codable, Equatable, Identifiable {
    public let id: UUID
    public var values: [String: EntitlementValue]
    public var source: Source

    public enum Source: String, Codable {
        case app
        case provisioningProfile
        case custom
        case merged
    }

    public init(id: UUID = UUID(), values: [String: EntitlementValue] = [:], source: Source = .app) {
        self.id = id
        self.values = values
        self.source = source
    }

    public subscript(key: String) -> EntitlementValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var applicationIdentifier: String? {
        if case .string(let value) = values["application-identifier"] { return value }
        return nil
    }

    public var teamIdentifier: String? {
        if case .string(let value) = values["com.apple.developer.team-identifier"] { return value }
        return nil
    }

    public var keys: [String] { values.keys.sorted() }

    public func boolValue(forKey key: String) -> Bool? {
        if case .bool(let value) = values[key] { return value }
        return nil
    }

    public func stringArrayValue(forKey key: String) -> [String]? {
        if case .array(let value) = values[key] { return value }
        return nil
    }
}

public enum EntitlementValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case array([String])
    case dictionary([String: String])

    public var plistValue: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .integer(let value): return value
        case .array(let value): return value
        case .dictionary(let value): return value
        }
    }

    public var displayString: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .array(let value): return value.joined(separator: ", ")
        case .dictionary(let value): return value.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        }
    }
}

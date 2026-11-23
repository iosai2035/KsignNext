import Foundation

public enum TweakCompatibility: String, Codable, CaseIterable {
    case compatible
    case incompatibleArchitecture
    case incompatibleDependency
    case jailbreakOnly
    case unknown

    /// Jailbreak-only tweaks can never run on stock iOS; the UI must
    /// label them as such instead of offering to inject them silently.
    public var canRunOnStockiOS: Bool {
        self == .compatible || self == .unknown
    }
}

/// A tweak (dylib / DEB / framework / bundle) available for injection.
public struct TweakModel: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
    public var architecture: String
    public var dependencies: [String]
    public var injectionType: InjectionType
    public var compatibility: TweakCompatibility
    public var fileURL: URL?
    public var isEnabled: Bool
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String? = nil,
        version: String? = nil,
        architecture: String = "arm64",
        dependencies: [String] = [],
        injectionType: InjectionType = .dylib,
        compatibility: TweakCompatibility = .unknown,
        fileURL: URL? = nil,
        isEnabled: Bool = true,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.architecture = architecture
        self.dependencies = dependencies
        self.injectionType = injectionType
        self.compatibility = compatibility
        self.fileURL = fileURL
        self.isEnabled = isEnabled
        self.importedAt = importedAt
    }
}

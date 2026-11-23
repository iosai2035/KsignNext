import Foundation

/// Information parsed from a Mach-O binary. All reads are
/// bounds-checked; parsing never uses text search as a substitute
/// for load-command parsing.
public struct MachOInfo: Codable, Equatable {
    public var cpuType: String
    public var cpuSubtype: String
    public var is64Bit: Bool
    public var isFat: Bool
    public var architectures: [String]
    public var uuid: String?
    public var linkedLibraries: [String]
    public var rpaths: [String]
    public var hasCodeSignature: Bool
    public var minimumOSVersion: String?
    public var sdkVersion: String?
    public var segments: [String]
    public var isEncrypted: Bool

    public init(
        cpuType: String = "arm64",
        cpuSubtype: String = "",
        is64Bit: Bool = true,
        isFat: Bool = false,
        architectures: [String] = ["arm64"],
        uuid: String? = nil,
        linkedLibraries: [String] = [],
        rpaths: [String] = [],
        hasCodeSignature: Bool = false,
        minimumOSVersion: String? = nil,
        sdkVersion: String? = nil,
        segments: [String] = [],
        isEncrypted: Bool = false
    ) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.is64Bit = is64Bit
        self.isFat = isFat
        self.architectures = architectures
        self.uuid = uuid
        self.linkedLibraries = linkedLibraries
        self.rpaths = rpaths
        self.hasCodeSignature = hasCodeSignature
        self.minimumOSVersion = minimumOSVersion
        self.sdkVersion = sdkVersion
        self.segments = segments
        self.isEncrypted = isEncrypted
    }
}

public protocol MachOEngineProtocol: AnyObject, Sendable {
    /// Parses the Mach-O header and load commands of the executable
    /// at `url` (a single binary or a fat binary).
    func inspect(_ url: URL) async throws -> MachOInfo

    /// The architectures present in the binary (e.g. ["arm64"]).
    func architectures(of url: URL) async throws -> [String]

    /// The dylibs the binary links against (LC_LOAD_DYLIB / WEAK).
    func dependencies(of url: URL) async throws -> [String]

    /// `true` when the binary is encrypted (LC_ENCRYPTION_INFO cryptid != 0).
    func isEncrypted(_ url: URL) async throws -> Bool

    /// The UUID load command value, if present.
    func uuid(of url: URL) async throws -> String?
}

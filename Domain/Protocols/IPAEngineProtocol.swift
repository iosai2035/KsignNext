import Foundation

/// Inspects an IPA without signing it. Every structural problem
/// throws the specific `AppError.ipa` case.
public protocol IPAEngineProtocol: AnyObject, Sendable {
    func inspect(ipaURL: URL) async throws -> AppInfo
}

/// One Mach-O architecture (thin binary, or one slice of a fat
/// binary). `cpuType` is the Mach-O `cputype` (arm64 = 0x0100000C).
public struct MachOArchitecture: Equatable, Sendable {
    public let cpuType: Int32
    public let cpuSubtype: Int32
    public let is64Bit: Bool

    public init(cpuType: Int32, cpuSubtype: Int32, is64Bit: Bool) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.is64Bit = is64Bit
    }

    public var isArm64: Bool { cpuType == 0x0100000C }
    public var isX86_64: Bool { cpuType == 0x01000007 }
}

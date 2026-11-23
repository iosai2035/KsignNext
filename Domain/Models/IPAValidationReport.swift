import Foundation

public struct ValidationIssue: Codable, Equatable, Identifiable {
    public enum Severity: String, Codable {
        case error
        case warning
        case info
    }

    public let id: UUID
    public var severity: Severity
    public var code: String
    public var message: String

    public init(id: UUID = UUID(), severity: Severity, code: String, message: String) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
    }
}

// NOTE (coordinator integration): the `IPAValidationReport` struct itself
// lives in Engines/IPAEngine/IPAValidation.swift (the engine's shape:
// isValid, errors/warnings as [String], checks, fileSize, entryCount,
// appBundleCount, appBundleIdentifiers). The Domain definition was a
// duplicate with a different shape and has been removed; this file
// keeps only ValidationIssue, which other layers use for typed issues.

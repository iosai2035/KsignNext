import Foundation

// MARK: - Validation report types

/// Severity of a single validation check.
public enum ValidationSeverity: String, Equatable {
    case error
    case warning
    case info
}

/// One named check inside a validation report.
public struct ValidationCheck: Equatable {
    public let name: String
    public let passed: Bool
    public let detail: String
    public let severity: ValidationSeverity

    public init(name: String, passed: Bool, detail: String, severity: ValidationSeverity = .error) {
        self.name = name
        self.passed = passed
        self.detail = detail
        self.severity = severity
    }
}

/// Result of validating an IPA file: structural ZIP checks, Payload layout,
/// Info.plist presence, and executable architecture checks.
public struct IPAValidationReport: Identifiable {
    public let id: UUID
    public var ipaURL: URL
    public var isValid: Bool
    public var errors: [String]
    public var warnings: [String]
    public var checks: [ValidationCheck]
    public var fileSize: Int64
    public var entryCount: Int
    public var appBundleCount: Int
    public var appBundleIdentifiers: [String]
    public var validatedAt: Date

    public init(
        id: UUID = UUID(),
        ipaURL: URL,
        isValid: Bool,
        errors: [String] = [],
        warnings: [String] = [],
        checks: [ValidationCheck] = [],
        fileSize: Int64 = 0,
        entryCount: Int = 0,
        appBundleCount: Int = 0,
        appBundleIdentifiers: [String] = [],
        validatedAt: Date = Date()
    ) {
        self.id = id
        self.ipaURL = ipaURL
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
        self.checks = checks
        self.fileSize = fileSize
        self.entryCount = entryCount
        self.appBundleCount = appBundleCount
        self.appBundleIdentifiers = appBundleIdentifiers
        self.validatedAt = validatedAt
    }
}

// MARK: - Validator

/// Stateless validator used by `IPAEngine.validateIPA(at:)` and by the
/// verification engine. It inspects the ZIP central directory and the
/// extracted Info.plist files without extracting the whole archive, except
/// for the executable-architecture check, which needs the Mach-O header
/// bytes of each main executable.
public struct IPAValidator {

    public init() {}

    /// Runs every check against the IPA at `url` and returns a report.
    /// This never throws for a merely-invalid IPA: invalidity is reported
    /// in the report. It throws only for I/O failures (file unreadable).
    public func validate(url: URL) async throws -> IPAValidationReport {
        var checks: [ValidationCheck] = []
        var errors: [String] = []
        var warnings: [String] = []
        var entryCount = 0
        var appBundleIdentifiers: [String] = []

        func record(_ check: ValidationCheck) {
            checks.append(check)
            if !check.passed {
                if check.severity == .error {
                    errors.append(check.detail)
                } else if check.severity == .warning {
                    warnings.append(check.detail)
                }
            }
        }

        // --- File existence / size -------------------------------------------------
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw IPAError.fileNotFound(path: url.path)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw IPAError.ioError("Cannot stat \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        let sizeCheck = ValidationCheck(
            name: "file-size",
            passed: fileSize > 0 && fileSize <= IPAEngine.maxIPASize,
            detail: fileSize <= 0
                ? "IPA file is empty."
                : fileSize > IPAEngine.maxIPASize
                ? "IPA is \(fileSize) bytes, over the \(IPAEngine.maxIPASize) byte limit."
                : "IPA size is \(fileSize) bytes.",
            severity: .error
        )
        record(sizeCheck)
        if !sizeCheck.passed {
            return IPAValidationReport(
                ipaURL: url, isValid: false, errors: errors, warnings: warnings,
                checks: checks, fileSize: fileSize
            )
        }

        // --- ZIP structure ---------------------------------------------------------
        let archive = ArchiveEngine()
        let entries: [ZipEntry]
        do {
            entries = try archive.listEntries(at: url)
        } catch {
            let check = ValidationCheck(
                name: "zip-structure",
                passed: false,
                detail: "Cannot read ZIP structure: \(error.localizedDescription)",
                severity: .error
            )
            record(check)
            return IPAValidationReport(
                ipaURL: url, isValid: false, errors: errors, warnings: warnings,
                checks: checks, fileSize: fileSize
            )
        }
        entryCount = entries.count
        record(ValidationCheck(
            name: "zip-structure",
            passed: true,
            detail: "ZIP central directory parsed: \(entries.count) entries.",
            severity: .info
        ))

        // --- Entry-count limit -----------------------------------------------------
        record(ValidationCheck(
            name: "entry-count",
            passed: entries.count <= IPAEngine.maxEntryCount,
            detail: entries.count > IPAEngine.maxEntryCount
                ? "Archive has \(entries.count) entries, over the limit of \(IPAEngine.maxEntryCount)."
                : "\(entries.count) entries, within the limit.",
            severity: .error
        ))

        // --- Duplicate names -------------------------------------------------------
        var seenNames = Set<String>()
        var duplicates: [String] = []
        for entry in entries {
            if !seenNames.insert(entry.name).inserted {
                duplicates.append(entry.name)
            }
        }
        record(ValidationCheck(
            name: "duplicate-entries",
            passed: duplicates.isEmpty,
            detail: duplicates.isEmpty
                ? "No duplicate entry names."
                : "Duplicate entries: \(duplicates.prefix(5).joined(separator: ", "))",
            severity: .error
        ))

        // --- Unsafe paths ----------------------------------------------------------
        let unsafe = entries.filter { ArchiveEngine.isUnsafeEntryName($0.name) }
        record(ValidationCheck(
            name: "entry-paths",
            passed: unsafe.isEmpty,
            detail: unsafe.isEmpty
                ? "All entry paths are safe."
                : "Unsafe entry paths: \(unsafe.prefix(5).map(\.name).joined(separator: ", "))",
            severity: .error
        ))

        // --- Zip-bomb ratio --------------------------------------------------------
        let totalCompressed = entries.reduce(Int64(0)) { $0 + $1.compressedSize }
        let totalUncompressed = entries.reduce(Int64(0)) { $0 + $1.uncompressedSize }
        let ratio: Double = totalCompressed > 0 ? Double(totalUncompressed) / Double(totalCompressed) : 0
        record(ValidationCheck(
            name: "compression-ratio",
            passed: ratio <= IPAEngine.maxCompressionRatio && totalUncompressed <= IPAEngine.maxTotalUncompressedSize,
            detail: "Total compressed \(totalCompressed) bytes, uncompressed \(totalUncompressed) bytes (ratio \(String(format: "%.1f", ratio)):1).",
            severity: .error
        ))

        // --- Payload / .app presence ----------------------------------------------
        let appPaths = entries
            .map(\.name)
            .filter { $0.hasPrefix("Payload/") && $0.hasSuffix(".app/") }
        // Also accept entries directly under Payload/*.app/Info.plist.
        let appInfoPlists = entries
            .map(\.name)
            .filter { $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist") }
        let appBundleNames = Set(
            appPaths.map { String($0.dropFirst("Payload/".count)) }
            + appInfoPlists.map { plistPath -> String in
                let withoutPlist = String(plistPath.dropLast("Info.plist".count))
                return String(withoutPlist.dropFirst("Payload/".count))
            }
        )
        record(ValidationCheck(
            name: "payload-present",
            passed: !appBundleNames.isEmpty,
            detail: appBundleNames.isEmpty
                ? "No .app bundle found under Payload/."
                : "Found \(appBundleNames.count) .app bundle(s) under Payload/.",
            severity: .error
        ))

        // --- Per-app Info.plist + executable checks --------------------------------
        let plistReader = PlistReader()
        for bundleName in appBundleNames.sorted() {
            let plistName = "Payload/\(bundleName)Info.plist"
            guard let plistEntry = entries.first(where: { $0.name == plistName }) else {
                record(ValidationCheck(
                    name: "info-plist-\(bundleName)",
                    passed: false,
                    detail: "Missing Info.plist in \(bundleName).",
                    severity: .error
                ))
                continue
            }
            do {
                let plistData = try archive.readEntryData(named: plistName, in: url)
                _ = plistEntry
                let dict = try plistReader.readDictionary(data: plistData)
                guard let bundleID = plistReader.string(dict, "CFBundleIdentifier"), !bundleID.isEmpty else {
                    record(ValidationCheck(
                        name: "info-plist-\(bundleName)",
                        passed: false,
                        detail: "Info.plist in \(bundleName) has no CFBundleIdentifier.",
                        severity: .error
                    ))
                    continue
                }
                appBundleIdentifiers.append(bundleID)
                let hasExecutableName = plistReader.string(dict, "CFBundleExecutable") != nil
                record(ValidationCheck(
                    name: "info-plist-\(bundleName)",
                    passed: hasExecutableName,
                    detail: hasExecutableName
                        ? "Info.plist valid for \(bundleID)."
                        : "Info.plist in \(bundleName) has no CFBundleExecutable.",
                    severity: .error
                ))

                // Executable architecture check (Mach-O header only, no full extract).
                if let executableName = plistReader.string(dict, "CFBundleExecutable") {
                    let executablePath = "Payload/\(bundleName)\(executableName)"
                    if let execEntry = entries.first(where: { $0.name == executablePath }) {
                        do {
                            let headerData = try archive.readEntryData(
                                named: executablePath, in: url, maxBytes: 4096
                            )
                            _ = execEntry
                            let machO = try MachOParser.parse(data: headerData, allowTruncatedHeader: true)
                            let archNames = machO.architectures.map(\.cpuTypeName)
                            let hasARM64 = archNames.contains("arm64")
                            record(ValidationCheck(
                                name: "executable-arch-\(bundleName)",
                                passed: hasARM64,
                                detail: hasARM64
                                    ? "Executable architectures: \(archNames.joined(separator: ", "))."
                                    : "Executable has no arm64 slice (found: \(archNames.joined(separator: ", "))).",
                                severity: .error
                            ))
                            if !hasARM64 {
                                warnings.append("Non-arm64 executable in \(bundleName): \(archNames.joined(separator: ", ")).")
                            }
                        } catch {
                            record(ValidationCheck(
                                name: "executable-arch-\(bundleName)",
                                passed: false,
                                detail: "Cannot parse Mach-O header of \(executableName): \(error.localizedDescription)",
                                severity: .warning
                            ))
                        }
                    } else {
                        record(ValidationCheck(
                            name: "executable-present-\(bundleName)",
                            passed: false,
                            detail: "Executable \(executableName) listed in Info.plist is missing from the archive.",
                            severity: .error
                        ))
                    }
                }
            } catch {
                record(ValidationCheck(
                    name: "info-plist-\(bundleName)",
                    passed: false,
                    detail: "Cannot read Info.plist in \(bundleName): \(error.localizedDescription)",
                    severity: .error
                ))
            }
        }

        // --- Unreasonable individual sizes -----------------------------------------
        let oversized = entries.filter { $0.uncompressedSize > IPAEngine.maxSingleEntrySize }
        record(ValidationCheck(
            name: "entry-sizes",
            passed: oversized.isEmpty,
            detail: oversized.isEmpty
                ? "No single entry exceeds the per-entry size limit."
                : "Oversized entries: \(oversized.prefix(5).map(\.name).joined(separator: ", "))",
            severity: .warning
        ))

        let isValid = errors.isEmpty
        return IPAValidationReport(
            ipaURL: url,
            isValid: isValid,
            errors: errors,
            warnings: warnings,
            checks: checks,
            fileSize: fileSize,
            entryCount: entryCount,
            appBundleCount: appBundleNames.count,
            appBundleIdentifiers: appBundleIdentifiers
        )
    }
}

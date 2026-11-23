import Foundation

// MARK: - Report types

/// One named check inside a verification report.
public struct VerificationCheck: Equatable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// Result of verifying a signed .app bundle or IPA.
public struct VerificationReport: Identifiable {
    public let id: UUID
    public var targetURL: URL
    public var bundleIdentifier: String?
    public var passed: Bool
    public var checks: [VerificationCheck]
    public var errors: [String]
    public var warnings: [String]
    public var verifiedAt: Date

    public init(
        id: UUID = UUID(),
        targetURL: URL,
        bundleIdentifier: String? = nil,
        passed: Bool,
        checks: [VerificationCheck] = [],
        errors: [String] = [],
        warnings: [String] = [],
        verifiedAt: Date = Date()
    ) {
        self.id = id
        self.targetURL = targetURL
        self.bundleIdentifier = bundleIdentifier
        self.passed = passed
        self.checks = checks
        self.errors = errors
        self.warnings = warnings
        self.verifiedAt = verifiedAt
    }
}

// MARK: - Engine

/// Verifies a signed .app bundle or IPA structurally.
///
/// What this engine checks (all real, on-device checks):
/// - `_CodeSignature/CodeResources` exists and is a valid plist;
/// - the main executable has a LC_CODE_SIGNATURE load command;
/// - Info.plist is present and valid, with a bundle identifier and an
///   executable that actually exists;
/// - Payload structure (for IPAs) and bundle-identifier consistency
///   between the app and the provisioning profile;
/// - entitlements requested by the app are a subset of the entitlements
///   allowed by the provisioning profile;
/// - the main executable is arm64 (and not FairPlay-encrypted, which
///   would make re-signing impossible).
///
/// HONEST LIMIT: this engine does NOT verify Apple's CMS signature
/// cryptographically on-device. True cryptographic verification of the
/// code signature (the CMS blob in `_CodeSignature/CodeResources` and the
/// `LC_CODE_SIGNATURE` superblob) requires the Security framework's
/// `SecStaticCode` / `SecCodeCheckValidity` APIs, which are not available
/// to third-party iOS apps for arbitrary bundles, and on-device
/// re-implementation of CMS/PKCS#7 verification is out of scope and would
/// be unreliable. The checks here are structural: they prove the signature
/// artefacts are present and internally consistent, not that Apple (or any
/// particular certificate) actually signed them. The report never claims
/// otherwise — a passing report means "structurally sound", not
/// "cryptographically proven".
public final class VerificationEngine {

    private let plistReader = PlistReader()
    private let machOEngine = MachOEngine()
    private let entitlementsEngine = EntitlementsEngine()
    private let fileManager = FileManager.default

    public init() {}

    // MARK: - Public entry points

    /// Verifies an IPA file. The IPA is extracted to a temporary directory
    /// (removed afterwards) and the primary .app bundle is verified.
    public func verifyIPA(at ipaURL: URL, provisioningProfileURL: URL? = nil) async throws -> VerificationReport {
        guard fileManager.fileExists(atPath: ipaURL.path) else {
            throw IPAError.fileNotFound(path: ipaURL.path)
        }
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("KsignNext-verify-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        _ = try ArchiveEngine().extractAll(from: ipaURL, to: tempDirectory)
        let payload = tempDirectory.appendingPathComponent("Payload", isDirectory: true)
        guard fileManager.fileExists(atPath: payload.path) else {
            return failedReport(target: ipaURL, bundleIdentifier: nil, checks: [
                VerificationCheck(name: "payload-structure", passed: false, detail: "IPA has no Payload directory.")
            ])
        }
        let contents = (try? fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        let appBundles = contents.filter { $0.pathExtension.lowercased() == "app" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let primary = appBundles.first else {
            return failedReport(target: ipaURL, bundleIdentifier: nil, checks: [
                VerificationCheck(name: "payload-structure", passed: false, detail: "No .app bundle found under Payload/.")
            ])
        }
        var report = try verifyAppBundle(at: primary, provisioningProfileURL: provisioningProfileURL)
        report.targetURL = ipaURL
        return report
    }

    /// Verifies an extracted .app bundle on disk.
    public func verifyApp(at appBundleURL: URL, provisioningProfileURL: URL? = nil) throws -> VerificationReport {
        try verifyAppBundle(at: appBundleURL, provisioningProfileURL: provisioningProfileURL)
    }

    // MARK: - Bundle verification

    private func verifyAppBundle(at appBundleURL: URL, provisioningProfileURL: URL?) throws -> VerificationReport {
        var checks: [VerificationCheck] = []
        var errors: [String] = []
        var warnings: [String] = []
        var bundleIdentifier: String?

        func record(_ check: VerificationCheck) {
            checks.append(check)
            if !check.passed {
                errors.append(check.detail)
            }
        }

        // --- Bundle exists -------------------------------------------------------
        guard fileManager.fileExists(atPath: appBundleURL.path) else {
            throw IPAError.fileNotFound(path: appBundleURL.path)
        }
        record(VerificationCheck(name: "bundle-exists", passed: true, detail: "Bundle \(appBundleURL.lastPathComponent) exists."))

        // --- Info.plist ----------------------------------------------------------
        let plistURL = appBundleURL.appendingPathComponent("Info.plist")
        var infoPlist: [String: Any] = [:]
        if fileManager.fileExists(atPath: plistURL.path) {
            do {
                infoPlist = try plistReader.readDictionary(at: plistURL)
                bundleIdentifier = plistReader.string(infoPlist, "CFBundleIdentifier")
                let hasExecutable = plistReader.string(infoPlist, "CFBundleExecutable") != nil
                let bundleIDValid: Bool
                if let bundleID = bundleIdentifier, !bundleID.isEmpty, hasExecutable {
                    bundleIDValid = true
                } else {
                    bundleIDValid = false
                }
                record(VerificationCheck(
                    name: "info-plist-valid",
                    passed: bundleIDValid,
                    detail: bundleIdentifier.map { "Info.plist valid for \($0)." }
                        ?? "Info.plist has no CFBundleIdentifier."
                ))
            } catch {
                record(VerificationCheck(name: "info-plist-valid", passed: false, detail: "Info.plist cannot be parsed: \(error.localizedDescription)"))
            }
        } else {
            record(VerificationCheck(name: "info-plist-valid", passed: false, detail: "Info.plist is missing."))
        }

        // --- Executable exists + Mach-O ------------------------------------------
        var machO: MachOFile?
        if let executableName = plistReader.string(infoPlist, "CFBundleExecutable") {
            let executableURL = appBundleURL.appendingPathComponent(executableName)
            if fileManager.fileExists(atPath: executableURL.path) {
                record(VerificationCheck(name: "executable-exists", passed: true, detail: "Executable \(executableName) exists."))
                do {
                    let parsed = try machOEngine.parseMachO(at: executableURL)
                    machO = parsed
                    let archNames = machOEngine.architectures(of: parsed)
                    record(VerificationCheck(
                        name: "executable-arm64",
                        passed: machOEngine.isARM64Only(parsed),
                        detail: "Executable architectures: \(archNames.joined(separator: ", "))."
                    ))
                    if parsed.isEncrypted {
                        warnings.append("Executable is FairPlay-encrypted (cryptid != 0).")
                    }
                    record(VerificationCheck(
                        name: "code-signature-load-command",
                        passed: parsed.hasCodeSignature,
                        detail: parsed.hasCodeSignature
                            ? "LC_CODE_SIGNATURE present (offset \(parsed.codeSignatureOffset ?? 0), size \(parsed.codeSignatureSize ?? 0))."
                            : "No LC_CODE_SIGNATURE load command in the executable."
                    ))
                } catch {
                    record(VerificationCheck(name: "executable-arm64", passed: false, detail: "Cannot parse executable: \(error.localizedDescription)"))
                    record(VerificationCheck(name: "code-signature-load-command", passed: false, detail: "Cannot parse executable load commands."))
                }
            } else {
                record(VerificationCheck(name: "executable-exists", passed: false, detail: "Executable \(executableName) listed in Info.plist is missing."))
            }
        } else {
            record(VerificationCheck(name: "executable-exists", passed: false, detail: "Info.plist has no CFBundleExecutable."))
        }

        // --- _CodeSignature / CodeResources --------------------------------------
        let codeSignatureDir = appBundleURL.appendingPathComponent("_CodeSignature", isDirectory: true)
        let codeResourcesURL = codeSignatureDir.appendingPathComponent("CodeResources")
        if fileManager.fileExists(atPath: codeResourcesURL.path) {
            do {
                let resources = try plistReader.readDictionary(at: codeResourcesURL)
                let hasFiles = (resources["files"] as? [String: Any]) != nil
                    || (resources["files2"] as? [String: Any]) != nil
                record(VerificationCheck(
                    name: "code-resources",
                    passed: hasFiles,
                    detail: hasFiles
                        ? "_CodeSignature/CodeResources exists and lists signed files."
                        : "_CodeSignature/CodeResources exists but lists no signed files."
                ))
            } catch {
                record(VerificationCheck(name: "code-resources", passed: false, detail: "CodeResources cannot be parsed: \(error.localizedDescription)"))
            }
        } else {
            record(VerificationCheck(name: "code-resources", passed: false, detail: "_CodeSignature/CodeResources is missing."))
        }

        // --- Provisioning profile -------------------------------------------------
        let embeddedProfileURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        let profileURL = provisioningProfileURL ?? (fileManager.fileExists(atPath: embeddedProfileURL.path) ? embeddedProfileURL : nil)
        var profileEntitlements: [String: Any] = [:]
        var profileDictionary: [String: Any] = [:]
        if let profileURL {
            do {
                profileDictionary = try entitlementsEngine.provisioningProfileDictionary(at: profileURL)
                profileEntitlements = try entitlementsEngine.entitlementsFromProvisioningProfile(at: profileURL)
                record(VerificationCheck(name: "provisioning-profile-present", passed: true, detail: "Provisioning profile found at \(profileURL.lastPathComponent)."))

                // Expiration check.
                if let expiration = profileDictionary["ExpirationDate"] as? Date {
                    let expired = expiration < Date()
                    record(VerificationCheck(
                        name: "provisioning-profile-not-expired",
                        passed: !expired,
                        detail: expired
                            ? "Provisioning profile expired on \(expiration)."
                            : "Provisioning profile expires on \(expiration)."
                    ))
                } else {
                    warnings.append("Provisioning profile has no ExpirationDate.")
                }

                // Bundle-identifier consistency: the profile's
                // application-identifier is "<TeamID>.<bundle-id>" (or with
                // a wildcard); the app's bundle id must match its suffix.
                if let bundleID = bundleIdentifier,
                   let appID = entitlementsEngine.stringValue(profileEntitlements, key: "application-identifier") {
                    let matches = bundleIdentifierMatches(appID: appID, bundleID: bundleID)
                    record(VerificationCheck(
                        name: "bundle-id-matches-profile",
                        passed: matches,
                        detail: matches
                            ? "Bundle id \(bundleID) matches profile application-identifier \(appID)."
                            : "Bundle id \(bundleID) does not match profile application-identifier \(appID)."
                    ))
                } else {
                    record(VerificationCheck(name: "bundle-id-matches-profile", passed: false, detail: "Cannot compare bundle id with profile (missing application-identifier or bundle id)."))
                }
            } catch {
                record(VerificationCheck(name: "provisioning-profile-present", passed: false, detail: "Provisioning profile cannot be parsed: \(error.localizedDescription)"))
            }
        } else {
            record(VerificationCheck(name: "provisioning-profile-present", passed: false, detail: "No embedded.mobileprovision in the bundle and none was supplied."))
        }

        // --- Entitlements vs. provisioning ---------------------------------------
        if !profileEntitlements.isEmpty {
            do {
                let appEntitlements = try entitlementsEngine.entitlementsForApp(at: appBundleURL)
                // The app's own entitlements are the profile's entitlements
                // when read from the profile; compare the app's declared
                // entitlements (if a standalone .entitlements file exists)
                // against the profile instead.
                let standaloneURL = appBundleURL.appendingPathComponent("\(appBundleURL.deletingPathExtension().lastPathComponent).entitlements")
                if fileManager.fileExists(atPath: standaloneURL.path) {
                    let declared = try entitlementsEngine.parseEntitlements(at: standaloneURL)
                    let allowance = entitlementsEngine.allowedEntitlements(required: declared, allowed: profileEntitlements)
                    record(VerificationCheck(
                        name: "entitlements-allowed-by-profile",
                        passed: allowance.allAllowed,
                        detail: allowance.allAllowed
                            ? "All \(allowance.allowed.count) requested entitlements are allowed by the provisioning profile."
                            : "Entitlements not allowed by the provisioning profile: \(allowance.denied.joined(separator: ", "))."
                    ))
                } else {
                    _ = appEntitlements
                    record(VerificationCheck(
                        name: "entitlements-allowed-by-profile",
                        passed: true,
                        detail: "No standalone entitlements file; app uses the provisioning profile's entitlements."
                    ))
                }
            } catch {
                record(VerificationCheck(name: "entitlements-allowed-by-profile", passed: false, detail: "Cannot compare entitlements: \(error.localizedDescription)"))
            }
        }

        // --- Extensions / nested bundles ------------------------------------------
        let plugInsURL = appBundleURL.appendingPathComponent("PlugIns", isDirectory: true)
        if let plugIns = try? fileManager.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil), !plugIns.isEmpty {
            var nestedFailed: [String] = []
            for extensionURL in plugIns where extensionURL.pathExtension.lowercased() == "appex" {
                let nestedPlist = extensionURL.appendingPathComponent("Info.plist")
                if !fileManager.fileExists(atPath: nestedPlist.path) {
                    nestedFailed.append(extensionURL.lastPathComponent)
                }
            }
            record(VerificationCheck(
                name: "extensions-valid",
                passed: nestedFailed.isEmpty,
                detail: nestedFailed.isEmpty
                    ? "\(plugIns.count) app extension(s) present with Info.plist files."
                    : "Extensions missing Info.plist: \(nestedFailed.joined(separator: ", "))."
            ))
        }

        _ = machO
        let passed = errors.isEmpty
        return VerificationReport(
            targetURL: appBundleURL,
            bundleIdentifier: bundleIdentifier,
            passed: passed,
            checks: checks,
            errors: errors,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private func failedReport(target: URL, bundleIdentifier: String?, checks: [VerificationCheck]) -> VerificationReport {
        VerificationReport(
            targetURL: target,
            bundleIdentifier: bundleIdentifier,
            passed: false,
            checks: checks,
            errors: checks.filter { !$0.passed }.map(\.detail),
            warnings: []
        )
    }

    /// True when `appID` (form `TEAMID.bundle.id` or `TEAMID.*`) covers
    /// `bundleID`.
    private func bundleIdentifierMatches(appID: String, bundleID: String) -> Bool {
        let components = appID.split(separator: ".", maxSplits: 1)
        guard components.count == 2 else { return false }
        let suffix = String(components[1])
        if suffix == "*" { return true }
        if suffix.hasSuffix(".*") {
            let prefix = String(suffix.dropLast(2))
            return bundleID.hasPrefix(prefix + ".") || bundleID == prefix
        }
        return suffix == bundleID
    }
}

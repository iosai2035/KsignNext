import Foundation

// MARK: - Diff types

/// One changed entitlement key: old value vs. new value, as plist text.
public struct EntitlementChange: Equatable {
    public var key: String
    public var oldValue: String?
    public var newValue: String?
    public var oldValueDescription: String
    public var newValueDescription: String

    public init(key: String, oldValue: Any?, newValue: Any?) {
        self.key = key
        self.oldValue = oldValue as? String
        self.newValue = newValue as? String
        self.oldValueDescription = EntitlementsEngine.describePlistValue(oldValue)
        self.newValueDescription = EntitlementsEngine.describePlistValue(newValue)
    }
}

/// Result of comparing two entitlement sets.
public struct EntitlementsDiff: Equatable {
    public var added: [String]
    public var removed: [String]
    public var changed: [EntitlementChange]
    /// Keys present in both sets with different *types* (e.g. Bool vs.
    /// String) — usually a real conflict, not a harmless edit.
    public var typeConflicts: [String]

    public init(added: [String] = [], removed: [String] = [], changed: [EntitlementChange] = [], typeConflicts: [String] = []) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.typeConflicts = typeConflicts
    }

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && typeConflicts.isEmpty
    }
}

/// Result of checking required entitlements against the provisioning
/// profile's allowed set.
public struct EntitlementsAllowance {
    public var allowed: [String]
    public var denied: [String]

    public init(allowed: [String] = [], denied: [String] = []) {
        self.allowed = allowed
        self.denied = denied
    }

    public var allAllowed: Bool { denied.isEmpty }
}

// MARK: - Engine

/// Parses, serializes, validates, and compares app entitlements.
///
/// Sources supported:
/// - a standalone `.entitlements` plist file (XML or binary);
/// - the `Entitlements` dictionary inside an `embedded.mobileprovision`
///   file (the provisioning profile is a CMS-signed blob wrapping a plist;
///   this engine locates the embedded plist by scanning for the XML plist
///   header instead of pretending to verify the CMS signature).
///
/// This engine never grants an entitlement: `allowedEntitlements(required:allowed:)`
/// only reports which requested keys the provisioning profile actually
/// permits, and signing must refuse the denied ones.
public final class EntitlementsEngine {

    private let plistReader = PlistReader()

    public init() {}

    // MARK: - Parsing

    /// Parses an entitlements plist file (`.entitlements`, XML or binary).
    public func parseEntitlements(at url: URL) throws -> [String: Any] {
        let dict = try plistReader.readDictionary(at: url)
        try validateEntitlementTypes(dict)
        return dict
    }

    /// Parses entitlements from in-memory plist data.
    public func parseEntitlements(data: Data) throws -> [String: Any] {
        let dict = try plistReader.readDictionary(data: data)
        try validateEntitlementTypes(dict)
        return dict
    }

    /// Extracts the `Entitlements` dictionary from a provisioning profile
    /// (`embedded.mobileprovision`). The profile is a PKCS#7/CMS blob whose
    /// payload is a plist; this scans the file bytes for the plist XML
    /// header (`<?xml`) and parses from there, which works without any
    /// CMS verification. It does NOT verify the profile's signature —
    /// that is the signing engine's job.
    public func entitlementsFromProvisioningProfile(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IPAError.fileNotFound(path: url.path)
        }
        return try entitlementsFromProvisioningProfile(data: data)
    }

    /// Same as above, from in-memory profile bytes.
    public func entitlementsFromProvisioningProfile(data: Data) throws -> [String: Any] {
        guard let plistData = extractEmbeddedPlist(from: data) else {
            throw IPAError.invalidEntitlements("No plist payload found inside the provisioning profile.")
        }
        let dict = try plistReader.readDictionary(data: plistData)
        guard let entitlements = dict["Entitlements"] as? [String: Any] else {
            throw IPAError.invalidEntitlements("Provisioning profile has no Entitlements dictionary.")
        }
        try validateEntitlementTypes(entitlements)
        return entitlements
    }

    /// Extracts the whole provisioning-profile plist (not just
    /// entitlements): app ID, team, expiration, provisioned devices, etc.
    public func provisioningProfileDictionary(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IPAError.fileNotFound(path: url.path)
        }
        guard let plistData = extractEmbeddedPlist(from: data) else {
            throw IPAError.invalidEntitlements("No plist payload found inside the provisioning profile.")
        }
        return try plistReader.readDictionary(data: plistData)
    }

    /// Locates an XML plist inside arbitrary bytes (e.g. a CMS blob) by
    /// scanning for the `<?xml` header, then takes everything up to the
    /// closing `</plist>` tag. Returns nil when no plist is found.
    /// Binary plists inside a CMS blob are not located this way; such a
    /// profile is reported as unsupported rather than guessed at.
    public func extractEmbeddedPlist(from data: Data) -> Data? {
        let header = Data("<?xml".utf8)
        guard let start = data.range(of: header)?.lowerBound else {
            return nil
        }
        let footer = Data("</plist>".utf8)
        let searchRange = start..<data.count
        guard let footerRange = data.range(of: footer, options: [], in: searchRange) else {
            return nil
        }
        return data.subdata(in: start..<footerRange.upperBound)
    }

    /// Reads entitlements from an .app bundle: prefers
    /// `embedded.mobileprovision`, then a sibling `<App>.entitlements`
    /// file, then nothing (returns an empty dictionary).
    public func entitlementsForApp(at appBundleURL: URL) throws -> [String: Any] {
        let profileURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: profileURL.path) {
            return try entitlementsFromProvisioningProfile(at: profileURL)
        }
        let name = appBundleURL.deletingPathExtension().lastPathComponent
        let entitlementsURL = appBundleURL.appendingPathComponent("\(name).entitlements")
        if FileManager.default.fileExists(atPath: entitlementsURL.path) {
            return try parseEntitlements(at: entitlementsURL)
        }
        return [:]
    }

    // MARK: - Serialization

    /// Serializes entitlements to an XML plist string.
    public func xmlString(from entitlements: [String: Any]) throws -> String {
        try plistReader.xmlString(from: entitlements)
    }

    /// Serializes entitlements to XML plist data.
    public func xmlData(from entitlements: [String: Any]) throws -> Data {
        try plistReader.xmlData(from: entitlements)
    }

    /// Serializes entitlements to binary plist data.
    public func binaryData(from entitlements: [String: Any]) throws -> Data {
        try plistReader.binaryData(from: entitlements)
    }

    /// Serializes entitlements to JSON data (sorted keys, pretty printed).
    /// Non-JSON plist values (Data, Date) are converted to strings first.
    public func jsonData(from entitlements: [String: Any]) throws -> Data {
        let jsonSafe = jsonSafeValue(entitlements)
        do {
            return try JSONSerialization.data(withJSONObject: jsonSafe, options: [.sortedKeys, .prettyPrinted])
        } catch {
            throw IPAError.invalidEntitlements("Cannot serialize entitlements to JSON: \(error.localizedDescription)")
        }
    }

    /// Serializes entitlements to a JSON string.
    public func jsonString(from entitlements: [String: Any]) throws -> String {
        let data = try jsonData(from: entitlements)
        guard let string = String(data: data, encoding: .utf8) else {
            throw IPAError.invalidEntitlements("Serialized entitlements JSON is not valid UTF-8.")
        }
        return string
    }

    // MARK: - Validation

    /// Validates that every entitlement value is a plist-native type
    /// (String, Bool, Int/NSNumber, Data, Date, Array, Dictionary).
    /// Throws `IPAError.invalidEntitlements` on the first bad value.
    public func validateEntitlementTypes(_ entitlements: [String: Any]) throws {
        for (key, value) in entitlements {
            try validatePlistValue(value, keyPath: key)
        }
    }

    private func validatePlistValue(_ value: Any, keyPath: String) throws {
        switch value {
        case is String, is Bool, is NSNumber, is Data, is Date:
            return
        case let array as [Any]:
            for (index, element) in array.enumerated() {
                try validatePlistValue(element, keyPath: "\(keyPath)[\(index)]")
            }
        case let dict as [String: Any]:
            for (key, element) in dict {
                try validatePlistValue(element, keyPath: "\(keyPath).\(key)")
            }
        default:
            throw IPAError.invalidEntitlements("Entitlement '\(keyPath)' has unsupported value type \(type(of: value)).")
        }
    }

    /// Typed accessors. Each returns nil when the key is missing *or* the
    /// value has the wrong type — never a crash, never a silent coercion
    /// (except NSNumber-backed integers, which plist decoding produces).
    public func stringValue(_ entitlements: [String: Any], key: String) -> String? {
        entitlements[key] as? String
    }

    public func boolValue(_ entitlements: [String: Any], key: String) -> Bool? {
        entitlements[key] as? Bool
    }

    public func stringArrayValue(_ entitlements: [String: Any], key: String) -> [String]? {
        entitlements[key] as? [String]
    }

    public func dictionaryValue(_ entitlements: [String: Any], key: String) -> [String: Any]? {
        entitlements[key] as? [String: Any]
    }

    /// Well-known entitlement keys and the type they must have. Used by
    /// `validateKnownKeys(_:)` to catch type mistakes early.
    public static let knownKeyTypes: [String: String] = [
        "application-identifier": "String",
        "keychain-access-groups": "[String]",
        "get-task-allow": "Bool",
        "com.apple.developer.team-identifier": "String",
        "com.apple.developer.associated-domains": "[String]",
        "com.apple.developer.push-notifications": "Bool",
        "com.apple.developer.icloud-container-identifiers": "[String]",
        "com.apple.developer.icloud-services": "[String]",
        "com.apple.developer.healthkit": "Bool",
        "com.apple.developer.homekit": "Bool",
        "com.apple.developer.siri": "Bool",
        "com.apple.developer.networking.wifi-info": "Bool",
        "com.apple.developer.applesignin": "[String]",
        "com.apple.developer.default-data-protection": "String",
        "com.apple.security.application-groups": "[String]",
        "com.apple.developer.nfc.readersession.formats": "[String]",
        "beta-reports-active": "Bool",
        "aps-environment": "String",
    ]

    /// Checks well-known keys against their expected types. Returns a list
    /// of human-readable problems (empty when all known keys are well-typed).
    public func validateKnownKeys(_ entitlements: [String: Any]) -> [String] {
        var problems: [String] = []
        for (key, expected) in Self.knownKeyTypes {
            guard let value = entitlements[key] else { continue }
            let ok: Bool
            switch expected {
            case "String": ok = value is String
            case "Bool": ok = value is Bool
            case "[String]": ok = value is [String]
            default: ok = true
            }
            if !ok {
                problems.append("Entitlement '\(key)' should be \(expected) but is \(type(of: value)).")
            }
        }
        return problems
    }

    // MARK: - Comparison

    /// Compares two entitlement sets and reports added / removed /
    /// changed keys, plus keys whose *type* changed between the sets.
    public func diff(_ old: [String: Any], _ new: [String: Any]) -> EntitlementsDiff {
        let oldKeys = Set(old.keys)
        let newKeys = Set(new.keys)
        let added = Array(newKeys.subtracting(oldKeys)).sorted()
        let removed = Array(oldKeys.subtracting(newKeys)).sorted()
        var changed: [EntitlementChange] = []
        var typeConflicts: [String] = []
        for key in oldKeys.intersection(newKeys).sorted() {
            let oldValue = old[key]
            let newValue = new[key]
            if !plistValuesEqual(oldValue, newValue) {
                changed.append(EntitlementChange(key: key, oldValue: oldValue, newValue: newValue))
            }
            if type(of: oldValue as Any) != type(of: newValue as Any) {
                // NSNumber vs Bool is a plist decoding artefact, not a real
                // conflict: both decode as NSNumber on some paths.
                let oldIsBool = oldValue is Bool
                let newIsBool = newValue is Bool
                if oldIsBool != newIsBool {
                    typeConflicts.append(key)
                }
            }
        }
        return EntitlementsDiff(added: added, removed: removed, changed: changed, typeConflicts: typeConflicts)
    }

    /// Compares required entitlements against the provisioning profile's
    /// allowed set. Only keys present in `allowed` are permitted; every
    /// other requested key is denied. A required key whose *value* differs
    /// from the allowed value (e.g. a different application-identifier
    /// prefix) is also denied.
    ///
    /// This function never grants anything — it is a filter, and the
    /// caller must refuse to sign with the denied keys.
    public func allowedEntitlements(required: [String: Any], allowed: [String: Any]) -> EntitlementsAllowance {
        var permitted: [String] = []
        var denied: [String] = []
        for key in required.keys.sorted() {
            guard let allowedValue = allowed[key] else {
                denied.append(key)
                continue
            }
            if plistValuesEqual(required[key], allowedValue) {
                permitted.append(key)
            } else if isWildcardMatch(required: required[key], allowed: allowedValue) {
                permitted.append(key)
            } else {
                denied.append(key)
            }
        }
        return EntitlementsAllowance(allowed: permitted, denied: denied)
    }

    /// True when an allowed entitlement value covers the required one via
    /// a wildcard: allowed `TEAMID.*` covers required `TEAMID.com.example`,
    /// and an allowed array covers a required value contained in it.
    private func isWildcardMatch(required: Any?, allowed: Any?) -> Bool {
        if let allowedString = allowed as? String,
           let requiredString = required as? String,
           allowedString.hasSuffix(".*") {
            let prefix = String(allowedString.dropLast(2))
            return requiredString.hasPrefix(prefix + ".") || requiredString == prefix
        }
        if let allowedArray = allowed as? [String],
           let requiredString = required as? String {
            return allowedArray.contains(requiredString)
        }
        return false
    }

    // MARK: - Helpers

    /// Deep equality for plist values (bridged NSArray/NSDictionary compare
    /// by value via NSObject.isEqual where available).
    public func plistValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        case let (left as NSObject, right as NSObject):
            return left.isEqual(right)
        default:
            return String(describing: lhs as Any) == String(describing: rhs as Any)
        }
    }

    /// Human-readable description of a plist value for diffs / logs.
    public static func describePlistValue(_ value: Any?) -> String {
        guard let value else { return "<missing>" }
        if let data = value as? Data {
            return "<\(data.count) bytes>"
        }
        if let array = value as? [Any] {
            return "[\(array.map { describePlistValue($0) }.joined(separator: ", "))]"
        }
        if let dict = value as? [String: Any] {
            let pairs = dict.keys.sorted().map { "\($0)=\(describePlistValue(dict[$0]))" }
            return "{\(pairs.joined(separator: ", "))}"
        }
        return String(describing: value)
    }

    /// Converts plist values to JSON-safe values (Data -> base64 string,
    /// Date -> ISO-8601 string, other types pass through).
    private func jsonSafeValue(_ value: Any) -> Any {
        switch value {
        case let data as Data:
            return data.base64EncodedString()
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let array as [Any]:
            return array.map { jsonSafeValue($0) }
        case let dict as [String: Any]:
            return dict.mapValues { jsonSafeValue($0) }
        default:
            return value
        }
    }
}

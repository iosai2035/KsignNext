import Foundation

/// Validates entitlements against what a provisioning profile allows.
/// Never grants an entitlement the profile does not allow; any
/// mismatch is reported as a typed error or a conflict list.
public enum EntitlementsValidator {
    public struct Conflict: Codable, Equatable, Identifiable {
        public let id: UUID
        public var key: String
        public var appValue: String?
        public var profileValue: String?
        public var message: String

        public init(id: UUID = UUID(), key: String, appValue: String? = nil, profileValue: String? = nil, message: String) {
            self.id = id
            self.key = key
            self.appValue = appValue
            self.profileValue = profileValue
            self.message = message
        }
    }

    /// Returns conflicts between the app's entitlements and the
    /// profile's entitlements. An empty list means they agree.
    public static func conflicts(
        app: EntitlementsModel,
        profile: EntitlementsModel
    ) -> [Conflict] {
        var result: [Conflict] = []
        for key in app.keys {
            guard let profileValue = profile.values[key] else {
                result.append(Conflict(
                    key: key,
                    appValue: app.values[key]?.displayString,
                    profileValue: nil,
                    message: "The app requests “\(key)” but the provisioning profile does not grant it."
                ))
                continue
            }
            if app.values[key] != profileValue {
                result.append(Conflict(
                    key: key,
                    appValue: app.values[key]?.displayString,
                    profileValue: profileValue.displayString,
                    message: "The value of “\(key)” differs between the app and the provisioning profile."
                ))
            }
        }
        return result
    }

    /// Throws when the app requests an entitlement the profile does
    /// not grant. The first unsupported key is named in the error.
    public static func validate(app: EntitlementsModel, profile: EntitlementsModel) throws {
        for conflict in conflicts(app: app, profile: profile) {
            guard conflict.profileValue != nil else {
                throw AppError.signing(.unsupportedEntitlement(key: conflict.key))
            }
        }
    }

    /// Builds a model from a parsed plist dictionary. String, Bool,
    /// integer, string-array and string-dictionary values map to
    /// their typed cases; anything else is kept as its description
    /// so the validator can still compare keys.
    public static func model(fromPlistDictionary dict: [String: Any],
                             source: EntitlementsModel.Source) -> EntitlementsModel {
        var values: [String: EntitlementValue] = [:]
        for (key, value) in dict {
            switch value {
            case let string as String: values[key] = .string(string)
            case let bool as Bool: values[key] = .bool(bool)
            case let number as NSNumber: values[key] = .integer(number.intValue)
            case let array as [String]: values[key] = .array(array)
            case let dict as [String: String]: values[key] = .dictionary(dict)
            case let dict as [String: Any]:
                values[key] = .dictionary(dict.mapValues { String(describing: $0) })
            default: values[key] = .string(String(describing: value))
            }
        }
        return EntitlementsModel(values: values, source: source)
    }

    /// Builds a model from a provisioning profile's raw string
    /// entitlements (`ProvisioningModel.entitlements`).
    public static func model(fromStringDictionary dict: [String: String],
                             source: EntitlementsModel.Source) -> EntitlementsModel {
        EntitlementsModel(values: dict.mapValues { EntitlementValue.string($0) }, source: source)
    }

    /// Checks the application-identifier / team identifiers agree.
    public static func validateIdentifiers(app: EntitlementsModel, profile: ProvisioningModel) throws {
        if let appTeam = app.teamIdentifier, appTeam != profile.teamIdentifier {
            throw AppError.signing(.teamIdentifierMismatch(expected: profile.teamIdentifier, found: appTeam))
        }
    }
}

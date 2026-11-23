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

    /// Checks the application-identifier / team identifiers agree.
    public static func validateIdentifiers(app: EntitlementsModel, profile: ProvisioningModel) throws {
        if let appTeam = app.teamIdentifier, appTeam != profile.teamIdentifier {
            throw AppError.signing(.teamIdentifierMismatch(expected: profile.teamIdentifier, found: appTeam))
        }
    }
}

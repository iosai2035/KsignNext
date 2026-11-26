import Foundation

// MARK: - Developer-service models (Phase 2)
//
// Plain value types parsed from the Rust dev FFI JSON (see
// `AppleRefreshBridge.h` and `RustCore/apple_refresh/src/dev.rs`).
// Every `from(json:)` tolerates missing keys the way
// `TwoFactorPrompt.from(json:)` does — the server omits null
// fields, and a missing field must degrade to nil, not crash.
// Dates arrive as ISO 8601 strings ("2026-12-03T13:00:00Z").
// Binary blobs arrive base64-encoded.

/// Parses the ISO 8601 date strings the Rust core emits
/// (`plist::Date::to_xml_format`, e.g. "2026-12-03T13:00:00Z").
enum DeveloperDate {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return formatter.date(from: text)
    }
}

public struct DeveloperTeam: Equatable, Sendable {
    public let teamID: String
    public let name: String?
    public let type: String?
    public let status: String?

    public static func from(json: [String: Any]) -> DeveloperTeam {
        DeveloperTeam(
            teamID: json["team_id"] as? String ?? "",
            name: json["name"] as? String,
            type: json["type"] as? String,
            status: json["status"] as? String
        )
    }
}

public struct DeveloperDevice: Equatable, Sendable {
    public let deviceID: String?
    /// The UDID (`device_number` in Apple's response).
    public let deviceNumber: String
    public let name: String?
    public let status: String?

    public static func from(json: [String: Any]) -> DeveloperDevice {
        DeveloperDevice(
            deviceID: json["device_id"] as? String,
            deviceNumber: json["device_number"] as? String ?? "",
            name: json["name"] as? String,
            status: json["status"] as? String
        )
    }
}

public struct DeveloperAppID: Equatable, Sendable {
    public let appID: String
    public let identifier: String
    public let name: String
    public let expirationDate: Date?

    public static func from(json: [String: Any]) -> DeveloperAppID {
        DeveloperAppID(
            appID: json["app_id_id"] as? String ?? "",
            identifier: json["identifier"] as? String ?? "",
            name: json["name"] as? String ?? "",
            expirationDate: DeveloperDate.parse(json["expiration_date"])
        )
    }
}

public struct DeveloperAppIDList: Equatable, Sendable {
    public let appIDs: [DeveloperAppID]
    public let maxQuantity: Int?
    public let availableQuantity: Int?

    public static func from(json: [String: Any]) -> DeveloperAppIDList {
        DeveloperAppIDList(
            appIDs: (json["app_ids"] as? [[String: Any]] ?? []).map(DeveloperAppID.from(json:)),
            maxQuantity: json["max_quantity"] as? Int,
            availableQuantity: json["available_quantity"] as? Int
        )
    }
}

public struct DevelopmentCertificate: Equatable, Sendable {
    public let certificateID: String?
    public let name: String?
    /// Uppercase hex serial, leading zeros trimmed (Apple's form).
    public let serialNumber: String?
    public let machineID: String?
    public let machineName: String?
    public let status: String?
    public let statusCode: Int?
    public let expirationDate: Date?

    public static func from(json: [String: Any]) -> DevelopmentCertificate {
        DevelopmentCertificate(
            certificateID: json["certificate_id"] as? String,
            name: json["name"] as? String,
            serialNumber: json["serial_number"] as? String,
            machineID: json["machine_id"] as? String,
            machineName: json["machine_name"] as? String,
            status: json["status"] as? String,
            statusCode: json["status_code"] as? Int,
            expirationDate: DeveloperDate.parse(json["expiration_date"])
        )
    }
}

/// The result of reusing or creating the on-device development
/// certificate. `p12Data` is the complete .p12 file bytes;
/// `p12Password` is the one-time password for it — Swift must
/// store it in the Keychain immediately (via
/// `CertificateEngine.importP12`) and never log or display it.
public struct CreatedCertificate: Equatable, Sendable {
    public let reused: Bool
    public let machineID: String
    public let machineName: String
    public let serialNumber: String
    public let notAfter: Date?
    public let p12Data: Data
    public let p12Password: String

    public static func from(json: [String: Any]) throws -> CreatedCertificate {
        guard let p12Base64 = json["p12_base64"] as? String,
              let p12Data = Data(base64Encoded: p12Base64),
              let p12Password = json["p12_password"] as? String, !p12Password.isEmpty else {
            throw AppleRefreshError.internalError(
                reason: "Apple returned no certificate archive for create_certificate.")
        }
        return CreatedCertificate(
            reused: json["reused"] as? Bool ?? false,
            machineID: json["machine_id"] as? String ?? "",
            machineName: json["machine_name"] as? String ?? "",
            serialNumber: json["serial_number"] as? String ?? "",
            notAfter: DeveloperDate.parse(json["not_after"]),
            p12Data: p12Data,
            p12Password: p12Password
        )
    }
}

/// A downloaded team provisioning profile. `encodedProfile` is the
/// raw .mobileprovision file bytes.
public struct DeveloperProfile: Equatable, Sendable {
    public let provisioningProfileID: String
    public let name: String
    public let status: String
    public let type: String
    public let distributionMethod: String
    public let uuid: String
    public let dateExpire: Date?
    public let appID: String
    public let filename: String
    public let isFreeProvisioningProfile: Bool?
    public let encodedProfile: Data

    public static func from(json: [String: Any]) throws -> DeveloperProfile {
        guard let base64 = json["encoded_profile_base64"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw AppleRefreshError.internalError(
                reason: "Apple returned no profile data for download_profile.")
        }
        return DeveloperProfile(
            provisioningProfileID: json["provisioning_profile_id"] as? String ?? "",
            name: json["name"] as? String ?? "",
            status: json["status"] as? String ?? "",
            type: json["type"] as? String ?? "",
            distributionMethod: json["distribution_method"] as? String ?? "",
            uuid: json["uuid"] as? String ?? "",
            dateExpire: DeveloperDate.parse(json["date_expire"]),
            appID: json["app_id_id"] as? String ?? "",
            filename: json["filename"] as? String ?? "",
            isFreeProvisioningProfile: json["is_free_provisioning_profile"] as? Bool,
            encodedProfile: data
        )
    }
}

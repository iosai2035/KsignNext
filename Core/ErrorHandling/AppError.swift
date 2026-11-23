import Foundation

/// Typed errors for the whole app. Every case carries enough context to
/// show the user a useful message; none of them is a bare "failed".
public enum AppError: LocalizedError, Equatable {
    case signing(SigningError)
    case certificate(CertificateError)
    case ipa(IPAError)
    case download(DownloadError)
    case network(NetworkError)
    case storage(StorageError)
    case validation(ValidationError)
    case cancelled
    case unknown(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .signing(let error): return error.errorDescription
        case .certificate(let error): return error.errorDescription
        case .ipa(let error): return error.errorDescription
        case .download(let error): return error.errorDescription
        case .network(let error): return error.errorDescription
        case .storage(let error): return error.errorDescription
        case .validation(let error): return error.errorDescription
        case .cancelled: return "The operation was cancelled."
        case .unknown(let underlying): return "An unexpected error occurred: \(underlying)"
        }
    }
}

public enum SigningError: LocalizedError, Equatable {
    case invalidIPA(reason: String)
    case invalidCertificate(reason: String)
    case invalidPassword
    case missingProvisioningProfile
    case bundleIdentifierMismatch(expected: String, found: String)
    case teamIdentifierMismatch(expected: String, found: String)
    case unsupportedEntitlement(key: String)
    case unsupportedArchitecture(String)
    case dependencyMissing(name: String)
    case signingFailed(reason: String)
    case verificationFailed(reason: String)
    case packagingFailed(reason: String)
    case cancelled
    case zsignBackendUnavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidIPA(let reason): return "The IPA file is invalid: \(reason)"
        case .invalidCertificate(let reason): return "The certificate is invalid: \(reason)"
        case .invalidPassword: return "The certificate password is incorrect."
        case .missingProvisioningProfile: return "No provisioning profile was provided for signing."
        case .bundleIdentifierMismatch(let expected, let found):
            return "Bundle identifier mismatch: the provisioning profile expects “\(expected)” but the app uses “\(found)”."
        case .teamIdentifierMismatch(let expected, let found):
            return "Team identifier mismatch: expected “\(expected)” but found “\(found)”."
        case .unsupportedEntitlement(let key): return "The entitlement “\(key)” is not supported by this certificate or provisioning profile."
        case .unsupportedArchitecture(let arch): return "The architecture “\(arch)” is not supported for signing on this device."
        case .dependencyMissing(let name): return "A required dependency is missing: \(name)."
        case .signingFailed(let reason): return "Signing failed: \(reason)"
        case .verificationFailed(let reason): return "Signature verification failed: \(reason)"
        case .packagingFailed(let reason): return "Repackaging the signed IPA failed: \(reason)"
        case .cancelled: return "Signing was cancelled."
        case .zsignBackendUnavailable(let reason): return "The signing backend is unavailable: \(reason)"
        }
    }
}

public enum CertificateError: LocalizedError, Equatable {
    case invalidFormat(reason: String)
    case wrongPassword
    case expired(expirationDate: Date)
    case notYetValid(notBefore: Date)
    case revoked
    case missingPrivateKey
    case keychainFailure(reason: String)
    case provisioningInvalid(reason: String)
    case provisioningExpired(expirationDate: Date)
    case provisioningMismatch(reason: String)
    case unsupportedType(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let reason): return "The certificate file could not be read: \(reason)"
        case .wrongPassword: return "The password for this certificate file is incorrect."
        case .expired(let date): return "The certificate expired on \(date)."
        case .notYetValid(let date): return "The certificate is not valid until \(date)."
        case .revoked: return "The certificate has been revoked."
        case .missingPrivateKey: return "The certificate file contains no private key."
        case .keychainFailure(let reason): return "The secure keychain could not be accessed: \(reason)"
        case .provisioningInvalid(let reason): return "The provisioning profile is invalid: \(reason)"
        case .provisioningExpired(let date): return "The provisioning profile expired on \(date)."
        case .provisioningMismatch(let reason): return "The provisioning profile does not match the app or certificate: \(reason)"
        case .unsupportedType(let type): return "The certificate type “\(type)” is not supported."
        }
    }
}

public enum IPAError: LocalizedError, Equatable {
    case notAnArchive(reason: String)
    case corruptArchive(reason: String)
    case zipBombSuspected
    case pathTraversalAttempt(entry: String)
    case unsafeSymlink(entry: String)
    case tooLarge(sizeBytes: Int64, limitBytes: Int64)
    case tooManyEntries(count: Int, limit: Int)
    case missingPayload
    case noAppBundleFound
    case multipleAppsFound(count: Int)
    case missingInfoPlist
    case invalidInfoPlist(reason: String)
    case missingExecutable
    case unsupportedArchitecture(String)
    case fileNotFound(path: String)
    case unreadable(path: String)
    // Cases merged from the IPA/Mach-O engines (coordinator integration):
    // the engines throw these directly, so they live on the canonical enum.
    case notAnIPA(URL)
    case invalidZIP(String)
    case corruptZIP(String)
    case invalidPlist(String)
    case invalidMachO(String)
    case invalidEntitlements(String)
    case ioError(String)
    case unsupportedFormat(String)
    case sizeLimitExceeded(limit: Int64, actual: Int64)
    case entryCountExceeded(limit: Int, actual: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notAnArchive(let reason): return "The file is not a valid IPA archive: \(reason)"
        case .corruptArchive(let reason): return "The IPA archive is corrupt: \(reason)"
        case .zipBombSuspected: return "The archive was rejected: its decompressed size is suspiciously large for its compressed size."
        case .pathTraversalAttempt(let entry): return "The archive contains an unsafe entry that escapes the workspace: \(entry)"
        case .unsafeSymlink(let entry): return "The archive contains an unsafe symbolic link: \(entry)"
        case .tooLarge(let size, let limit): return "The file is \(size) bytes, which exceeds the \(limit) byte limit."
        case .tooManyEntries(let count, let limit): return "The archive contains \(count) entries, which exceeds the limit of \(limit)."
        case .missingPayload: return "The IPA contains no Payload folder."
        case .noAppBundleFound: return "The IPA contains no app bundle."
        case .multipleAppsFound(let count): return "The IPA contains \(count) apps; exactly one is expected."
        case .missingInfoPlist: return "The app bundle contains no Info.plist."
        case .invalidInfoPlist(let reason): return "The app Info.plist is invalid: \(reason)"
        case .missingExecutable: return "The app bundle contains no executable."
        case .unsupportedArchitecture(let arch): return "The app architecture “\(arch)” is not supported."
        case .fileNotFound(let path): return "File not found: \(path)"
        case .unreadable(let path): return "The file could not be read: \(path)"
        case .notAnIPA(let url): return "Not an IPA file: \(url.lastPathComponent)"
        case .invalidZIP(let detail): return "Invalid ZIP archive: \(detail)"
        case .corruptZIP(let detail): return "Corrupt ZIP archive: \(detail)"
        case .invalidPlist(let detail): return "Invalid property list: \(detail)"
        case .invalidMachO(let detail): return "Invalid Mach-O file: \(detail)"
        case .invalidEntitlements(let detail): return "Invalid entitlements: \(detail)"
        case .ioError(let detail): return "I/O error: \(detail)"
        case .unsupportedFormat(let detail): return "Unsupported format: \(detail)"
        case .sizeLimitExceeded(let limit, let actual): return "File size \(actual) bytes exceeds the limit of \(limit) bytes."
        case .entryCountExceeded(let limit, let actual): return "Archive has \(actual) entries, exceeding the limit of \(limit)."
        case .cancelled: return "Operation was cancelled."
        }
    }
}

public enum DownloadError: LocalizedError, Equatable {
    case invalidURL(String)
    case insecureURL(String)
    case httpStatus(Int)
    case contentLengthMismatch(expected: Int64, actual: Int64)
    case noData
    case checksumMismatch(expected: String, actual: String)
    case insufficientSpace(requiredBytes: Int64)
    case cancelled
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "The download URL is invalid: \(url)"
        case .insecureURL(let url): return "Downloads require HTTPS; the URL “\(url)” is not secure."
        case .httpStatus(let code): return "The server returned HTTP status \(code)."
        case .contentLengthMismatch(let expected, let actual): return "Download size mismatch: expected \(expected) bytes, received \(actual) bytes."
        case .noData: return "The download finished but returned no data."
        case .checksumMismatch(let expected, let actual): return "Checksum mismatch: expected \(expected), received \(actual)."
        case .insufficientSpace(let required): return "Not enough free space: \(required) bytes are required."
        case .cancelled: return "The download was cancelled."
        case .underlying(let message): return "Download failed: \(message)"
        }
    }
}

public enum NetworkError: LocalizedError, Equatable {
    case offline
    case timeout
    case invalidResponse
    case httpStatus(Int)
    case tlsFailure(reason: String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .offline: return "No network connection is available."
        case .timeout: return "The request timed out."
        case .invalidResponse: return "The server returned an invalid response."
        case .httpStatus(let code): return "The server returned HTTP status \(code)."
        case .tlsFailure(let reason): return "The secure connection failed: \(reason)"
        case .underlying(let message): return "Network error: \(message)"
        }
    }
}

public enum StorageError: LocalizedError, Equatable {
    case notFound(id: String)
    case saveFailed(reason: String)
    case loadFailed(reason: String)
    case deleteFailed(reason: String)
    case migrationFailed(reason: String)
    case unavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No stored record was found with id \(id)."
        case .saveFailed(let reason): return "Saving failed: \(reason)"
        case .loadFailed(let reason): return "Loading failed: \(reason)"
        case .deleteFailed(let reason): return "Deleting failed: \(reason)"
        case .migrationFailed(let reason): return "The data store could not be migrated: \(reason)"
        case .unavailable(let reason): return "The data store is unavailable: \(reason)"
        }
    }
}

public enum ValidationError: LocalizedError, Equatable {
    case invalidBundleIdentifier(String)
    case invalidVersion(String)
    case invalidURL(String)
    case invalidFileExtension(String)
    case emptyValue(field: String)
    case outOfRange(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier(let value): return "“\(value)” is not a valid bundle identifier."
        case .invalidVersion(let value): return "“\(value)” is not a valid version string."
        case .invalidURL(let value): return "“\(value)” is not a valid URL."
        case .invalidFileExtension(let value): return "The file extension is not allowed: \(value)"
        case .emptyValue(let field): return "The field “\(field)” must not be empty."
        case .outOfRange(let field, let value): return "The value “\(value)” for “\(field)” is out of range."
        }
    }
}

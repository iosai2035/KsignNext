import Foundation
import Security

/// Keychain wrapper for secrets only: P12 passwords and certificate
/// references. No plaintext storage anywhere; items use
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they never
/// leave this device in a backup and are unavailable before first unlock.
public final class KeychainService {
    public static let shared = KeychainService()

    private let service: String

    public init(service: String = "com.ksignnext.app") {
        self.service = service
    }

    // MARK: - Generic password items (strings)

    public func savePassword(_ password: String, account: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw CertificateError.keychainFailure(reason: "The password could not be encoded.")
        }
        try save(data, account: account)
    }

    public func readPassword(account: String) throws -> String? {
        guard let data = try read(account: account) else { return nil }
        guard let password = String(data: data, encoding: .utf8) else {
            throw CertificateError.keychainFailure(reason: "The stored password could not be decoded.")
        }
        return password
    }

    // MARK: - Raw data items (e.g. certificate references / tokens)

    public func save(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery = baseQuery(account: account)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CertificateError.keychainFailure(reason: keychainMessage(for: updateStatus))
            }
            return
        }
        guard status == errSecSuccess else {
            throw CertificateError.keychainFailure(reason: keychainMessage(for: status))
        }
    }

    public func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CertificateError.keychainFailure(reason: keychainMessage(for: status))
        }
        guard let data = result as? Data else {
            throw CertificateError.keychainFailure(reason: "The keychain returned an unexpected value type.")
        }
        return data
    }

    public func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CertificateError.keychainFailure(reason: keychainMessage(for: status))
        }
    }

    public func exists(account: String) -> Bool {
        (try? read(account: account)) != nil
    }

    // MARK: - Private helpers

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func keychainMessage(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain error \(status)."
    }
}

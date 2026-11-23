import Foundation
import CryptoKit
import Security

/// CryptoKit helpers: fingerprints and secure random tokens.
/// No hashing is done on secrets for logging; fingerprints are for
/// identifying certificates, not for storing passwords.
public enum CryptoHelper {
    /// SHA-256 fingerprint, lowercase hex.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-1 fingerprint, lowercase hex (kept for certificate
    /// fingerprints, which are conventionally SHA-1 in tooling).
    public static func sha1Hex(of data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 fingerprint of a file's contents, streamed in chunks so
    /// large IPAs are not loaded into memory at once.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Cryptographically secure random token, URL-safe base64 without padding.
    public static func randomToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard result == errSecSuccess else {
            // Extremely unlikely; fall back to a UUID-based token rather
            // than failing the caller.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison, for comparing hashes / tokens.
    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

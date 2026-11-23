import Foundation

/// Pure validation helpers. All functions are side-effect free and
/// usable from Domain validation as well as the UI.
public enum Validators {
    // MARK: - Bundle ID

    /// Reverse-DNS bundle identifier: at least two dot-separated
    /// components, each starting with a letter and containing only
    /// letters, digits, hyphens and underscores.
    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for component in components {
            guard let first = component.first, first.isLetter else { return false }
            guard component.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return true
    }

    // MARK: - Version

    /// `1`, `1.2` or `1.2.3` (optionally more numeric components).
    public static func isValidVersion(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy(\.isNumber) && component.count <= 6
        }
    }

    // MARK: - URL

    public static func isValidURL(_ value: String, requireHTTPS: Bool = false) -> Bool {
        guard let url = URL(string: value), url.host != nil else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        if requireHTTPS { return scheme == "https" }
        return scheme == "https" || scheme == "http"
    }

    public static func isHTTPSURL(_ value: String) -> Bool {
        isValidURL(value, requireHTTPS: true)
    }

    // MARK: - File extensions

    public static func hasAllowedExtension(_ fileName: String, allowed: Set<String>) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return allowed.contains(ext)
    }

    public static let ipaExtensions: Set<String> = ["ipa"]
    public static let certificateExtensions: Set<String> = ["p12", "pfx", "pem", "der", "cer", "crt"]
    public static let provisioningExtensions: Set<String> = ["mobileprovision"]
    public static let tweakExtensions: Set<String> = ["dylib", "deb", "framework", "bundle"]

    // MARK: - Misc

    public static func isNonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Team ID: exactly 10 uppercase letters/digits (Apple format).
    public static func isValidTeamIdentifier(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber }
            && value == value.uppercased()
    }
}

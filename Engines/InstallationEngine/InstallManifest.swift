import Foundation

// MARK: - InstallManifest
//
// Model + plist generation for over-the-air installation via
// `itms-services://?action=download-manifest&url=...`.
//
// The manifest is a real `itms-services` plist, built with
// `PropertyListSerialization`:
//   items: [
//     {
//       assets: [
//         { kind: "software-package", url: "<ipa url>" },
//         { kind: "display-image",  url: "<57x57 icon url>" },
//         { kind: "full-size-image", url: "<512x512 icon url>" }
//       ],
//       metadata: {
//         "bundle-identifier": "<bundle id>",
//         "bundle-version": "<version>",
//         kind: "software",
//         title: "<display title>"
//       }
//     }
//   ]
// The image assets are optional; the software-package asset is required.

/// Failures while building or writing an install manifest.
public enum InstallManifestError: Error, LocalizedError, Equatable {
    case invalidBundleIdentifier
    case invalidVersion
    case invalidTitle
    case invalidPackageURL(URL)
    case invalidManifestURL(URL)
    case plistGenerationFailed(String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier:
            return "Bundle identifier must not be empty."
        case .invalidVersion:
            return "Bundle version must not be empty."
        case .invalidTitle:
            return "App title must not be empty."
        case .invalidPackageURL(let url):
            return "Package URL must use http or https: \(url.absoluteString)"
        case .invalidManifestURL(let url):
            return "Manifest URL must use http or https: \(url.absoluteString)"
        case .plistGenerationFailed(let detail):
            return "Could not generate the install manifest plist: \(detail)"
        case .writeFailed(let url, let detail):
            return "Could not write the install manifest to \(url.lastPathComponent): \(detail)"
        }
    }
}

/// An over-the-air install manifest for one app version.
public struct InstallManifest: Sendable, Equatable {
    public let bundleIdentifier: String
    public let bundleVersion: String
    public let title: String
    public let packageURL: URL
    public let displayImageURL: URL?
    public let fullSizeImageURL: URL?

    /// - Throws: `InstallManifestError` when the bundle identifier,
    ///   version, or title is empty, or when the package URL is not
    ///   http/https.
    public init(
        bundleIdentifier: String,
        bundleVersion: String,
        title: String,
        packageURL: URL,
        displayImageURL: URL? = nil,
        fullSizeImageURL: URL? = nil
    ) throws {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallManifestError.invalidBundleIdentifier
        }
        guard !bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallManifestError.invalidVersion
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallManifestError.invalidTitle
        }
        guard let scheme = packageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw InstallManifestError.invalidPackageURL(packageURL)
        }
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.title = title
        self.packageURL = packageURL
        self.displayImageURL = displayImageURL
        self.fullSizeImageURL = fullSizeImageURL
    }

    /// The manifest as XML plist data, ready to serve or write to disk.
    public func plistData() throws -> Data {
        var assets: [[String: String]] = [
            ["kind": "software-package", "url": packageURL.absoluteString]
        ]
        if let displayImageURL {
            assets.append(["kind": "display-image", "url": displayImageURL.absoluteString])
        }
        if let fullSizeImageURL {
            assets.append(["kind": "full-size-image", "url": fullSizeImageURL.absoluteString])
        }
        let metadata: [String: String] = [
            "bundle-identifier": bundleIdentifier,
            "bundle-version": bundleVersion,
            "kind": "software",
            "title": title
        ]
        let plist: [String: Any] = [
            "items": [["assets": assets, "metadata": metadata]]
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            throw InstallManifestError.plistGenerationFailed(error.localizedDescription)
        }
    }

    /// Writes the manifest plist into `directory` (created if needed) and
    /// returns the file URL. Defaults to `manifest.plist`.
    public func write(to directory: URL, fileName: String = "manifest.plist") throws -> URL {
        let target = directory.appendingPathComponent(fileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plistData().write(to: target, options: [.atomic])
            return target
        } catch let error as InstallManifestError {
            throw error
        } catch {
            throw InstallManifestError.writeFailed(target, error.localizedDescription)
        }
    }
}

// MARK: - Install URL

/// Builds `itms-services://` install URLs from a served manifest URL.
public enum InstallManifestURL {

    /// Returns `itms-services://?action=download-manifest&url=<manifest>`,
    /// or nil when the manifest URL is not http/https or cannot be encoded.
    /// The manifest URL is percent-encoded with `&`, `=`, and `+` removed
    /// from the allowed set so it cannot break out of the `url` parameter.
    public static func installURL(manifestURL: URL) -> URL? {
        guard let scheme = manifestURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        guard let encoded = manifestURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "itms-services://?action=download-manifest&url=\(encoded)")
    }
}

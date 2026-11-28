import Foundation

/// The `itms-services` manifest plist served by the local install
/// server, and the `itms-services://` URL that opens it.
///
/// Manifest shape (the OTA install contract): `items[0].assets`
/// holds the software-package URL plus the display-image and
/// full-size-image URLs when given; `items[0].metadata` holds
/// bundle-identifier, bundle-version, kind = "software", and title.
public enum InstallManifest {

    /// Builds the manifest plist bytes. Throws for an empty bundle
    /// id / version / title, or a package URL that is not http(s).
    public static func plistData(packageURL: URL, bundleIdentifier: String, bundleVersion: String,
                                 title: String, displayImageURL: URL?, fullSizeImageURL: URL?) throws -> Data {
        guard !bundleIdentifier.isEmpty else {
            throw AppError.validation(.emptyValue(field: "bundleIdentifier"))
        }
        guard !bundleVersion.isEmpty else {
            throw AppError.validation(.emptyValue(field: "bundleVersion"))
        }
        guard !title.isEmpty else {
            throw AppError.validation(.emptyValue(field: "title"))
        }
        guard let scheme = packageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AppError.validation(.invalidURL(packageURL.absoluteString))
        }
        var assets: [[String: String]] = [
            ["kind": "software-package", "url": packageURL.absoluteString]
        ]
        if let displayImageURL {
            assets.append(["kind": "display-image", "url": displayImageURL.absoluteString])
        }
        if let fullSizeImageURL {
            assets.append(["kind": "full-size-image", "url": fullSizeImageURL.absoluteString])
        }
        let plist: [String: Any] = [
            "items": [[
                "assets": assets,
                "metadata": [
                    "bundle-identifier": bundleIdentifier,
                    "bundle-version": bundleVersion,
                    "kind": "software",
                    "title": title,
                ] as [String: String],
            ] as [String: Any]],
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            throw AppError.ipa(.invalidPlist(error.localizedDescription))
        }
    }

    /// `itms-services://?action=download-manifest&url=<manifest>`.
    /// The manifest URL is percent-encoded with `&=+` removed from
    /// the allowed set, so a manifest URL carrying its own query
    /// survives intact as one parameter.
    public static func installURL(manifestURL: URL) throws -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        guard let encoded = manifestURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
            throw AppError.validation(.invalidURL(manifestURL.absoluteString))
        }
        return url
    }

    /// Writes the manifest plist atomically to a file inside
    /// `directory` and returns its URL.
    public static func write(packageURL: URL, bundleIdentifier: String, bundleVersion: String,
                             title: String, displayImageURL: URL?, fullSizeImageURL: URL?,
                             to directory: URL, fileName: String = "manifest.plist") throws -> URL {
        let data = try plistData(packageURL: packageURL, bundleIdentifier: bundleIdentifier,
                                 bundleVersion: bundleVersion, title: title,
                                 displayImageURL: displayImageURL, fullSizeImageURL: fullSizeImageURL)
        let destination = directory.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

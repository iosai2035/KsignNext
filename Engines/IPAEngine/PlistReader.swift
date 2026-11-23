import Foundation

/// Safe property-list reader (XML and binary formats).
///
/// All reads go through `PropertyListSerialization` with a hard size cap so
/// a malicious plist cannot exhaust memory. Nothing here force-unwraps a
/// user-supplied path or value; every failure is a typed `IPAError`.
public struct PlistReader {

    /// Maximum plist size accepted. Info.plist / entitlements files are
    /// normally a few kilobytes; 16 MB leaves ample headroom while still
    /// bounding memory use.
    public static let maxPlistSize: Int64 = 16 * 1024 * 1024

    public init() {}

    // MARK: - Reading

    /// Reads and deserializes the plist at `url`.
    /// - Returns: The top-level plist object (usually `[String: Any]`).
    public func readPlist(at url: URL) throws -> Any {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw IPAError.fileNotFound(path: url.path)
        }
        if let size = attributes[.size] as? NSNumber, size.int64Value > Self.maxPlistSize {
            throw IPAError.sizeLimitExceeded(limit: Self.maxPlistSize, actual: size.int64Value)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw IPAError.ioError("Cannot read plist at \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try readPlist(data: data)
    }

    /// Deserializes plist `data` (XML or binary).
    public func readPlist(data: Data) throws -> Any {
        guard !data.isEmpty else {
            throw IPAError.invalidPlist("Empty plist data.")
        }
        guard data.count <= Self.maxPlistSize else {
            throw IPAError.sizeLimitExceeded(limit: Self.maxPlistSize, actual: Int64(data.count))
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        do {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            )
        } catch {
            throw IPAError.invalidPlist(error.localizedDescription)
        }
    }

    /// Reads the plist at `url` and requires a dictionary at the top level.
    public func readDictionary(at url: URL) throws -> [String: Any] {
        let value = try readPlist(at: url)
        guard let dict = value as? [String: Any] else {
            throw IPAError.invalidPlist("Top-level object in \(url.lastPathComponent) is not a dictionary.")
        }
        return dict
    }

    /// Deserializes plist `data` and requires a dictionary at the top level.
    public func readDictionary(data: Data) throws -> [String: Any] {
        let value = try readPlist(data: data)
        guard let dict = value as? [String: Any] else {
            throw IPAError.invalidPlist("Top-level plist object is not a dictionary.")
        }
        return dict
    }

    // MARK: - Serializing

    /// Serializes a dictionary to XML plist data.
    public func xmlData(from dictionary: [String: Any]) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .xml,
                options: []
            )
        } catch {
            throw IPAError.invalidPlist("Cannot serialize plist: \(error.localizedDescription)")
        }
    }

    /// Serializes a dictionary to binary plist data.
    public func binaryData(from dictionary: [String: Any]) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .binary,
                options: []
            )
        } catch {
            throw IPAError.invalidPlist("Cannot serialize plist: \(error.localizedDescription)")
        }
    }

    /// Serializes a dictionary to an XML plist string.
    public func xmlString(from dictionary: [String: Any]) throws -> String {
        let data = try xmlData(from: dictionary)
        guard let string = String(data: data, encoding: .utf8) else {
            throw IPAError.invalidPlist("Serialized plist is not valid UTF-8.")
        }
        return string
    }

    // MARK: - Typed accessors (never crash on a wrong-typed value)

    public func string(_ dict: [String: Any], _ key: String) -> String? {
        dict[key] as? String
    }

    public func stringArray(_ dict: [String: Any], _ key: String) -> [String]? {
        dict[key] as? [String]
    }

    public func bool(_ dict: [String: Any], _ key: String) -> Bool? {
        dict[key] as? Bool
    }

    public func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? NSNumber { return value.intValue }
        return nil
    }

    public func dictionary(_ dict: [String: Any], _ key: String) -> [String: Any]? {
        dict[key] as? [String: Any]
    }

    public func array(_ dict: [String: Any], _ key: String) -> [Any]? {
        dict[key] as? [Any]
    }

    public func data(_ dict: [String: Any], _ key: String) -> Data? {
        dict[key] as? Data
    }

    public func date(_ dict: [String: Any], _ key: String) -> Date? {
        dict[key] as? Date
    }
}

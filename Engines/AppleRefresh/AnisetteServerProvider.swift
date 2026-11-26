import Foundation

/// The public anisette-v3 servers the sign-in flow can use, plus the
/// user's custom server. The anisette server never sees the Apple ID,
/// password, or 2FA code — it only provisions a device identity and
/// returns the headers the sign-in needs (research doc §3.2).
///
/// Policy (design Q10): default is `mac-ani.jkcoxson.com` (a Mac-ADI
/// server, because the sign-in claim must be a Mac claim for the
/// app-token step); at most 2 servers are tried per sign-in, and a
/// rejected password or 2FA failure is never retried on another
/// server. The remote list at servers.sidestore.io is a convenience
/// — its exact JSON shape is not documented, so parsing is defensive.
public struct AnisetteServerProvider: Sendable {

    public static let defaultServer = "https://mac-ani.jkcoxson.com"

    /// Built-in servers, in try order (research doc, Nov 2026).
    public static let builtInServers = [
        "https://mac-ani.jkcoxson.com",
        "https://ani.jkcoxson.com",
        "https://ani2.stikstore.app",
        "https://new.ani.sidestore.io",
        "https://ani.sidestore.zip",
        "https://ani.iloader.app",
    ]

    public static let remoteListURL = URL(string: "https://servers.sidestore.io/servers.json")!

    private static let customServerKey = "ksign.appleid.anisetteServer"
    private static let remoteServersKey = "ksign.appleid.remoteServers"
    private static let remoteServersDateKey = "ksign.appleid.remoteServersDate"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Selection

    /// The server the user picked (custom URL) or the default.
    public var selectedServer: String {
        get { defaults.string(forKey: Self.customServerKey) ?? Self.defaultServer }
        set {
            if newValue == Self.defaultServer {
                defaults.removeObject(forKey: Self.customServerKey)
            } else {
                defaults.set(newValue, forKey: Self.customServerKey)
            }
        }
    }

    public var isCustomServer: Bool {
        defaults.string(forKey: Self.customServerKey) != nil
    }

    /// Up to `maxAttempts` servers for one sign-in: the selected
    /// server first, then the first built-in that differs from it.
    public func serversToTry(maxAttempts: Int = 2) -> [String] {
        var servers = [selectedServer]
        for candidate in Self.builtInServers where candidate != selectedServer {
            if servers.count >= maxAttempts { break }
            servers.append(candidate)
        }
        return Array(servers.prefix(maxAttempts))
    }

    // MARK: - Validation

    /// A usable anisette server URL: https, with a host.
    public static func isValidServerURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              url.scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    // MARK: - Remote list

    /// Fetches the public server list and caches it for a day.
    /// Returns the cached list (or the built-ins) when the fetch
    /// fails — sign-in never depends on this list being fresh.
    public func fetchRemoteServers() async -> [String] {
        if let cached = cachedRemoteServers(), !cached.isEmpty { return cached }
        do {
            var request = URLRequest(url: Self.remoteListURL)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return Self.builtInServers
            }
            let servers = Self.parseRemoteList(data: data)
            if !servers.isEmpty {
                defaults.set(servers, forKey: Self.remoteServersKey)
                defaults.set(Date(), forKey: Self.remoteServersDateKey)
                return servers
            }
        } catch {
            // Offline or the list is down: fall back silently.
        }
        return Self.builtInServers
    }

    private func cachedRemoteServers() -> [String]? {
        guard let date = defaults.object(forKey: Self.remoteServersDateKey) as? Date,
              Date().timeIntervalSince(date) < 24 * 60 * 60 else { return nil }
        return defaults.stringArray(forKey: Self.remoteServersKey)
    }

    /// Defensive parser: accepts `{"servers": [{"url": …}]}`,
    /// `{"servers": ["…"]}`, a bare `["…"]`, and objects with a
    /// `"server"` key. Anything else yields an empty list.
    static func parseRemoteList(data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: [Any] = []
        if let dict = json as? [String: Any], let servers = dict["servers"] as? [Any] {
            raw = servers
        } else if let array = json as? [Any] {
            raw = array
        }
        var servers: [String] = []
        for item in raw {
            if let url = item as? String {
                servers.append(url)
            } else if let dict = item as? [String: Any],
                      let url = (dict["url"] as? String) ?? (dict["server"] as? String) {
                servers.append(url)
            }
        }
        return servers.filter(isValidServerURL)
    }
}

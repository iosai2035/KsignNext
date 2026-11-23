import Foundation

// MARK: - Backend protocol

/// The only way the signing engine talks to zsign. The concrete
/// implementation is supplied at build time (see ZsignBridge.h); this
/// protocol keeps the engine testable and keeps every zsign call in
/// one place. All paths are absolute file-system paths.
public protocol ZsignBackend: Sendable {
    func sign(
        appPath: String,
        provisionPath: String?,
        p12Path: String?,
        p12Password: String?,
        entitlementsPath: String?,
        bundleIdentifier: String?,
        bundleName: String?,
        bundleVersion: String?,
        adhoc: Bool
    ) async throws

    func removeDylibs(appExecutable: String, dylibNames: [String]) async throws
    func injectDylib(appExecutable: String, dylibPath: String) async throws
    func changeDylibPath(appExecutable: String, oldPath: String, newPath: String) async throws
}

// MARK: - Adapter

/// Thin wrapper around a `ZsignBackend`. The signing and injection
/// engines depend on this type, never on a concrete backend, so the
/// backend can be swapped (real zsign, unavailable stub, test double)
/// without touching engine code.
public struct ZsignAdapter: Sendable {
    public let backend: any ZsignBackend

    public init(backend: any ZsignBackend) {
        self.backend = backend
    }

    public func sign(
        appPath: String,
        provisionPath: String? = nil,
        p12Path: String? = nil,
        p12Password: String? = nil,
        entitlementsPath: String? = nil,
        bundleIdentifier: String? = nil,
        bundleName: String? = nil,
        bundleVersion: String? = nil,
        adhoc: Bool = false
    ) async throws {
        try await backend.sign(
            appPath: appPath,
            provisionPath: provisionPath,
            p12Path: p12Path,
            p12Password: p12Password,
            entitlementsPath: entitlementsPath,
            bundleIdentifier: bundleIdentifier,
            bundleName: bundleName,
            bundleVersion: bundleVersion,
            adhoc: adhoc
        )
    }

    public func removeDylibs(appExecutable: String, dylibNames: [String]) async throws {
        guard !dylibNames.isEmpty else { return }
        try await backend.removeDylibs(appExecutable: appExecutable, dylibNames: dylibNames)
    }

    public func injectDylib(appExecutable: String, dylibPath: String) async throws {
        try await backend.injectDylib(appExecutable: appExecutable, dylibPath: dylibPath)
    }

    public func changeDylibPath(appExecutable: String, oldPath: String, newPath: String) async throws {
        try await backend.changeDylibPath(appExecutable: appExecutable, oldPath: oldPath, newPath: newPath)
    }
}

// MARK: - Unavailable backend

/// Stand-in used when the zsign library has not been linked into the
/// build (for example in a target built without the build-time zsign
/// dependency). Every call fails loudly with a clear message instead
/// of silently doing nothing or pretending to sign.
public struct UnavailableZsignBackend: ZsignBackend, Sendable {
    public init() {}

    public static let message =
        "The zsign signing backend is not available in this build. " +
        "Add the MIT-licensed zsign library (claration/zsign) as a build-time " +
        "dependency and link it against ZsignBridge.h, then rebuild. " +
        "No signing, injection, or dylib-path change can run without it."

    public func sign(
        appPath: String,
        provisionPath: String?,
        p12Path: String?,
        p12Password: String?,
        entitlementsPath: String?,
        bundleIdentifier: String?,
        bundleName: String?,
        bundleVersion: String?,
        adhoc: Bool
    ) async throws {
        throw SigningError.zsignBackendUnavailable(reason: Self.message)
    }

    public func removeDylibs(appExecutable: String, dylibNames: [String]) async throws {
        throw SigningError.zsignBackendUnavailable(reason: Self.message)
    }

    public func injectDylib(appExecutable: String, dylibPath: String) async throws {
        throw SigningError.zsignBackendUnavailable(reason: Self.message)
    }

    public func changeDylibPath(appExecutable: String, oldPath: String, newPath: String) async throws {
        throw SigningError.zsignBackendUnavailable(reason: Self.message)
    }
}

// MARK: - Real backend (zsign, linked at build time)

/// `ZsignBackend` implemented against the C functions in ZsignBridge.h,
/// which are defined by `zsign/zsign_bridge.cpp` on top of the vendored
/// MIT-licensed zsign library. This is the backend the app uses: with it
/// wired in, signing, injection and dylib-path changes really run.
/// The C functions are synchronous and copy every string they are given,
/// so passing Swift strings as C strings is safe for the call duration.
public struct ZsignBridgeBackend: ZsignBackend, Sendable {
    public init() {}

    private static func cString(_ value: String?) -> UnsafePointer<CChar>? {
        guard let value else { return nil }
        return (value as NSString).utf8String
    }

    public func sign(
        appPath: String,
        provisionPath: String?,
        p12Path: String?,
        p12Password: String?,
        entitlementsPath: String?,
        bundleIdentifier: String?,
        bundleName: String?,
        bundleVersion: String?,
        adhoc: Bool
    ) async throws {
        let code = ksignnext_zsign_sign(
            Self.cString(appPath),
            Self.cString(provisionPath),
            Self.cString(p12Path),
            Self.cString(p12Password),
            Self.cString(entitlementsPath),
            Self.cString(bundleIdentifier),
            Self.cString(bundleName),
            Self.cString(bundleVersion),
            adhoc ? 1 : 0
        )
        guard code == 0 else {
            throw SigningError.signingFailed(
                reason: "zsign failed (code \(code)) while signing \(appPath).")
        }
    }

    public func removeDylibs(appExecutable: String, dylibNames: [String]) async throws {
        let cNames: [UnsafePointer<CChar>?] = dylibNames.map { Self.cString($0) }
        let code = cNames.withUnsafeBufferPointer { buffer in
            ksignnext_zsign_remove_dylibs(
                Self.cString(appExecutable),
                buffer.baseAddress,
                Int32(dylibNames.count)
            )
        }
        guard code == 0 else {
            throw SigningError.signingFailed(
                reason: "zsign failed (code \(code)) while removing dylibs from \(appExecutable).")
        }
    }

    public func injectDylib(appExecutable: String, dylibPath: String) async throws {
        let code = ksignnext_zsign_inject_dylib(
            Self.cString(appExecutable), Self.cString(dylibPath))
        guard code == 0 else {
            throw SigningError.signingFailed(
                reason: "zsign failed (code \(code)) while injecting \(dylibPath) into \(appExecutable).")
        }
    }

    public func changeDylibPath(appExecutable: String, oldPath: String, newPath: String) async throws {
        let code = ksignnext_zsign_change_dylib_path(
            Self.cString(appExecutable), Self.cString(oldPath), Self.cString(newPath))
        guard code == 0 else {
            let why = code == 4 ? "the old install name was not found"
                : code == 5 ? "the new install name does not fit in the load command"
                : "code \(code)"
            throw SigningError.signingFailed(
                reason: "Could not change dylib path in \(appExecutable) (\(why)).")
        }
    }
}

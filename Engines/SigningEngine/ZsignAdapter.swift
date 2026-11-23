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

// MARK: - Wiring note

/// The real backend is provided by the build: implement `ZsignBackend`
/// against the C functions in ZsignBridge.h (linked from the
/// MIT-licensed zsign library at build time) and pass it to
/// `ZsignAdapter(backend:)`. No C function is called from Swift here,
/// so this file compiles with or without the zsign dependency linked;
/// with only `UnavailableZsignBackend` wired in, every signing call
/// fails loudly instead of silently doing nothing.

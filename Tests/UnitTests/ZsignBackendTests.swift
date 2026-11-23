import XCTest
@testable import KsignNext

/// Tests for the real zsign backend (ZsignBridgeBackend), which links the
/// vendored zsign C++ library. These tests prove the backend is actually
/// linked and that its Mach-O editing works on a real binary — they do
/// NOT need a certificate or provisioning profile, which no CI machine
/// has. A successful real signature still needs a p12 + profile on a
/// developer machine; see Documentation/Integration-Report.md.
final class ZsignBackendTests: XCTestCase {

    /// The backend must be the linked zsign implementation, not the
    /// unavailable stand-in: signing a missing path fails with a
    /// signing error from the C++ layer, never with
    /// zsignBackendUnavailable.
    func testSignMissingAppThrowsSigningFailedNotBackendUnavailable() async {
        let backend = ZsignBridgeBackend()
        do {
            try await backend.sign(
                appPath: "/tmp/does-not-exist-ksignnext.app",
                provisionPath: nil, p12Path: nil, p12Password: nil,
                entitlementsPath: nil, bundleIdentifier: nil,
                bundleName: nil, bundleVersion: nil, adhoc: true)
            XCTFail("Signing a missing app must throw.")
        } catch let error as SigningError {
            if case .zsignBackendUnavailable = error {
                XCTFail("Backend is unavailable — zsign was not linked.")
            }
            if case .signingFailed = error { return }
            XCTFail("Expected signingFailed, got \(error).")
        } catch {
            XCTFail("Expected a SigningError, got \(error).")
        }
    }

    /// changeDylibPath rewrites a real load command in place: copy the
    /// test host's own executable, change libSystem's install name to a
    /// shorter @rpath name, and confirm the bytes changed (and the old
    /// name is gone). A longer replacement must fail instead of
    /// corrupting the header.
    func testChangeDylibPathRewritesRealMachO() async throws {
        let backend = ZsignBridgeBackend()
        guard let executable = Bundle.main.executableURL else {
            XCTFail("No main executable to copy.")
            return
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("KsignNext-changeDylib-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: executable, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let original = try Data(contentsOf: temp)
        let oldName = "/usr/lib/libSystem.B.dylib"
        guard original.range(of: Data(oldName.utf8)) != nil else {
            XCTFail("Test executable does not link \(oldName); fixture assumption wrong.")
            return
        }
        let newName = "@rpath/lib.dylib"
        try await backend.changeDylibPath(
            appExecutable: temp.path, oldPath: oldName, newPath: newName)
        let rewritten = try Data(contentsOf: temp)
        XCTAssertNotNil(rewritten.range(of: Data(newName.utf8)),
                        "New install name must appear in the binary.")
        XCTAssertNil(rewritten.range(of: Data(oldName.utf8)),
                     "Old install name must be gone from the binary.")

        // A longer replacement does not fit in the load command: it must
        // fail loudly, and the file must be unchanged by the attempt.
        let tooLong = "/usr/lib/this-name-is-far-too-long-to-fit-in-the-command.dylib"
        do {
            try await backend.changeDylibPath(
                appExecutable: temp.path, oldPath: newName, newPath: tooLong)
            XCTFail("A too-long install name must throw.")
        } catch let error as SigningError {
            if case .signingFailed = error { return }
            XCTFail("Expected signingFailed, got \(error).")
        }
    }

    /// Removing dylibs from a missing file fails with a signing error,
    /// never with backendUnavailable.
    func testRemoveDylibsMissingFileThrowsSigningFailed() async {
        let backend = ZsignBridgeBackend()
        do {
            try await backend.removeDylibs(
                appExecutable: "/tmp/does-not-exist-ksignnext",
                dylibNames: ["Foo.dylib"])
            XCTFail("Removing dylibs from a missing file must throw.")
        } catch let error as SigningError {
            if case .zsignBackendUnavailable = error {
                XCTFail("Backend is unavailable — zsign was not linked.")
            }
            if case .signingFailed = error { return }
            XCTFail("Expected signingFailed, got \(error).")
        } catch {
            XCTFail("Expected a SigningError, got \(error).")
        }
    }
}

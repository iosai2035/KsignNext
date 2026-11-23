import XCTest
@testable import KsignNext


// The view models under test are @MainActor, so the whole test class
// runs on the main actor and may call their init, properties and methods directly.
@MainActor
final class SigningStateTests: XCTestCase {

    func testUnavailableBackendThrowsHonestError() async {
        let service = UnavailableSigningService()
        do {
            _ = try await service.sign(appURL: URL(fileURLWithPath: "/tmp/App.ipa"), certificateName: "cert", bundleID: "com.example.app")
            XCTFail("Signing must not fake success when the backend is not linked")
        } catch let error as SigningBackendError {
            XCTAssertEqual(error, .backendNotLinked)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testWizardReportsBackendErrorOnStart() async {
        let vm = SigningCenterViewModel()
        vm.selectedAppName = "Missing.ipa"
        await vm.startSigning()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isSigning)
    }

    func testWizardStepOrder() {
        var step = SigningStep.app
        XCTAssertEqual(step.rawValue, 1)
        step = .export
        XCTAssertEqual(step.rawValue, 12)
    }

    func testVerificationFailsWithoutOutput() {
        let vm = SigningCenterViewModel()
        vm.verifySignedApp()
        XCTAssertEqual(vm.verificationPassed, false)
    }
}

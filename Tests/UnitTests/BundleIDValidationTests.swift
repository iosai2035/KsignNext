import XCTest
@testable import KsignNext


final class BundleIDValidationTests: XCTestCase {

    func testValidBundleIDs() {
        XCTAssertTrue(WizardBundleIDValidator.isValid("com.example.app"))
        XCTAssertTrue(WizardBundleIDValidator.isValid("com.ksignnext.app"))
        XCTAssertTrue(WizardBundleIDValidator.isValid("io.github.user.my-app_2"))
    }

    func testInvalidBundleIDs() {
        XCTAssertFalse(WizardBundleIDValidator.isValid(""))
        XCTAssertFalse(WizardBundleIDValidator.isValid("single"))
        XCTAssertFalse(WizardBundleIDValidator.isValid("com."))
        XCTAssertFalse(WizardBundleIDValidator.isValid(".com.example"))
        XCTAssertFalse(WizardBundleIDValidator.isValid("com.1example.app"), "A label must not start with a digit")
        XCTAssertFalse(WizardBundleIDValidator.isValid("com.exa mple.app"), "Spaces are not allowed")
        XCTAssertFalse(WizardBundleIDValidator.isValid("com.example/app"), "Slashes are not allowed")
    }

    func testWizardBlocksInvalidBundleID() {
        let vm = SigningCenterViewModel()
        vm.bundleID = "not a bundle id"
        XCTAssertFalse(vm.canAdvance(from: .bundleID))
        XCTAssertNotNil(vm.validationMessage(for: .bundleID))
        vm.bundleID = "com.example.app"
        XCTAssertTrue(vm.canAdvance(from: .bundleID))
    }

    func testWizardRequiresAppAndCertificate() {
        let vm = SigningCenterViewModel()
        XCTAssertFalse(vm.canAdvance(from: .app))
        XCTAssertFalse(vm.canAdvance(from: .certificate))
        vm.selectedAppName = "App.ipa"
        XCTAssertTrue(vm.canAdvance(from: .app))
        vm.selectedCertificateName = "cert.p12"
        XCTAssertTrue(vm.canAdvance(from: .certificate))
    }

    func testWizardHasTwelveSteps() {
        XCTAssertEqual(SigningStep.allCases.count, 12)
        XCTAssertEqual(SigningStep.app.rawValue, 1)
        XCTAssertEqual(SigningStep.export.rawValue, 12)
    }
}

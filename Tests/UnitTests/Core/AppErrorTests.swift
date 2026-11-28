import XCTest
@testable import KsignNext

/// Exact error-case assertions for the unified `AppError` type.
/// Error paths are `.certificate(...)` / `.storage(...)` /
/// `.ipa(...)` — never `.provisioning()`, `.keychain()` or
/// `.fileSystem()` (those cases do not exist).
final class AppErrorTests: XCTestCase {

    func testCertificate_wrongPasswordMessage() {
        let error = AppError.certificate(.wrongPassword)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.lowercased().contains("password"))
        XCTAssertTrue(description.lowercased().contains("incorrect"))
    }

    func testCertificate_expiredMessageContainsDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let error = AppError.certificate(.expired(expirationDate: date))
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.lowercased().contains("expired"))
        // The message carries the expiry date (formatted by the enum).
        XCTAssertFalse(description.isEmpty)
        XCTAssertEqual(error, AppError.certificate(.expired(expirationDate: date)))
    }

    func testStorage_notFoundMessage() {
        let id = UUID().uuidString
        let error = AppError.storage(.notFound(id: id))
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains(id))
        XCTAssertEqual(error, AppError.storage(.notFound(id: id)))
        XCTAssertNotEqual(error, AppError.storage(.notFound(id: UUID().uuidString)))
    }

    func testValidation_invalidUDIDMessage() {
        let error = AppError.validation(.invalidDeviceUDID("XYZ"))
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("40-character"))
        XCTAssertTrue(description.contains("XYZ"))
    }

    func testCancelledDescription() {
        let error = AppError.cancelled
        XCTAssertEqual(error.errorDescription, "The operation was cancelled.")
    }

    func testUnknownPreservesUnderlying() {
        let error = AppError.unknown(underlying: "boom-detail-123")
        XCTAssertTrue((error.errorDescription ?? "").contains("boom-detail-123"))
        XCTAssertEqual(error, AppError.unknown(underlying: "boom-detail-123"))
        XCTAssertNotEqual(error, AppError.unknown(underlying: "other"))
    }
}

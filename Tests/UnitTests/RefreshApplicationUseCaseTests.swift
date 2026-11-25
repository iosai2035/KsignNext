import XCTest
@testable import KsignNext

/// Refresh planning gates: the use case must refuse before touching
/// any IPA when the signing record or the certificate is missing.
/// The happy path (full re-sign of a real signed IPA) is covered by
/// the signing engine tests and the loopback install test; the live
/// proof is a real refresh on device.
final class RefreshApplicationUseCaseTests: XCTestCase {

    // MARK: - Stubs

    final class StubSignedRepository: SignedApplicationRepository {
        var results: [SigningResult] = []
        func fetchAll() async throws -> [SigningResult] { results }
        func fetch(id: UUID) async throws -> SigningResult? { results.first { $0.id == id } }
        func save(_ result: SigningResult) async throws { results.append(result) }
        func delete(id: UUID) async throws { results.removeAll { $0.id == id } }
    }

    final class StubCertificateRepository: CertificateRepository {
        var certificates: [CertificateModel] = []
        func fetchAll() async throws -> [CertificateModel] { certificates }
        func fetch(id: UUID) async throws -> CertificateModel? { certificates.first { $0.id == id } }
        func fetch(fingerprint: String) async throws -> CertificateModel? { certificates.first { $0.fingerprint == fingerprint } }
        func save(_ certificate: CertificateModel) async throws { certificates.append(certificate) }
        func delete(id: UUID) async throws { certificates.removeAll { $0.id == id } }
    }

    private func makeUseCase(
        signed: StubSignedRepository = StubSignedRepository(),
        certificates: StubCertificateRepository = StubCertificateRepository()
    ) -> RefreshApplicationUseCase {
        RefreshApplicationUseCase(
            signedRepository: signed,
            certificateRepository: certificates,
            provisioningEngine: ProvisioningEngine(),
            ipaEngine: IPAEngine()
        )
    }

    private func signedResult(fileName: String, certificateID: UUID? = UUID()) -> SigningResult {
        SigningResult(
            operationID: UUID(),
            importedIPAID: UUID(),
            signedFileURL: URL(fileURLWithPath: "/Documents/SignedApps/\(fileName)"),
            bundleIdentifier: "com.example.app",
            version: "1.0",
            certificateID: certificateID
        )
    }

    // MARK: - Tests

    func testPlanThrowsNoSigningRecordWhenUnknown() async {
        let useCase = makeUseCase()
        do {
            _ = try await useCase.plan(signedIPAURL: URL(fileURLWithPath: "/Documents/SignedApps/Unknown.ipa"))
            XCTFail("plan must throw when there is no signing record")
        } catch let error as RefreshError {
            XCTAssertEqual(error, .noSigningRecord("Unknown.ipa"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testPlanThrowsCertificateNotFoundWhenCertificateGone() async {
        let signed = StubSignedRepository()
        let record = signedResult(fileName: "App.ipa")
        signed.results = [record]
        // The certificate repository is empty: the certificate used to
        // sign this app is no longer imported.
        let useCase = makeUseCase(signed: signed, certificates: StubCertificateRepository())
        do {
            _ = try await useCase.plan(signedIPAURL: record.signedFileURL)
            XCTFail("plan must throw when the certificate is gone")
        } catch let error as RefreshError {
            XCTAssertEqual(error, .certificateNotFound)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

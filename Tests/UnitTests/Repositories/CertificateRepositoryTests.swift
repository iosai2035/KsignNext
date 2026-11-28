import XCTest
@testable import KsignNext

/// CoreDataCertificateRepository against an in-memory store
/// (`NSInMemoryStoreType`). Upsert by id; fetch-missing returns nil;
/// delete-missing throws the exact `AppError.storage(.notFound(id:))`.
final class CertificateRepositoryTests: XCTestCase {

    private var stack: InMemoryCoreDataStack!
    private var repository: CoreDataCertificateRepository!

    override func setUp() {
        super.setUp()
        stack = InMemoryCoreDataStack()
        repository = CoreDataCertificateRepository(context: stack.viewContext)
    }

    override func tearDown() {
        repository = nil
        stack = nil
        super.tearDown()
    }

    func testSaveFetch_roundTrip() async throws {
        let model = FixtureBuilder.makeCertificateModel()
        try await repository.save(model)
        let fetched = try await repository.fetch(id: model.id)
        XCTAssertEqual(fetched, model)
        XCTAssertEqual(try await repository.fetchAll().count, 1)
    }

    func testFetch_missingReturnsNil() async throws {
        XCTAssertNil(try await repository.fetch(id: UUID()))
        XCTAssertNil(try await repository.fetch(fingerprint: String(repeating: "f", count: 64)))
    }

    func testFetchByFingerprint() async throws {
        let first = FixtureBuilder.makeCertificateModel(fingerprint: String(repeating: "1", count: 64))
        let second = FixtureBuilder.makeCertificateModel(fingerprint: String(repeating: "2", count: 64))
        try await repository.save(first)
        try await repository.save(second)
        XCTAssertEqual(try await repository.fetch(fingerprint: String(repeating: "2", count: 64)), second)
        XCTAssertNil(try await repository.fetch(fingerprint: String(repeating: "9", count: 64)))
    }

    func testSave_upsertsById() async throws {
        let id = UUID()
        let original = FixtureBuilder.makeCertificateModel(id: id, name: "Original")
        try await repository.save(original)
        let updated = FixtureBuilder.makeCertificateModel(id: id, name: "Updated")
        try await repository.save(updated)
        XCTAssertEqual(try await repository.fetchAll().count, 1)
        XCTAssertEqual(try await repository.fetch(id: id)?.name, "Updated")
    }

    func testDelete_removesRecord() async throws {
        let model = FixtureBuilder.makeCertificateModel()
        try await repository.save(model)
        try await repository.delete(id: model.id)
        XCTAssertNil(try await repository.fetch(id: model.id))
        XCTAssertTrue(try await repository.fetchAll().isEmpty)
    }

    func testDelete_missingThrowsNotFound() async throws {
        let id = UUID()
        do {
            try await repository.delete(id: id)
            XCTFail("Expected AppError.storage(.notFound(id:))")
        } catch {
            XCTAssertEqual(error as? AppError, AppError.storage(.notFound(id: id.uuidString)))
        }
    }
}

import XCTest
@testable import KsignNext

/// CoreDataProvisioningProfileRepository against an in-memory store
/// (`NSInMemoryStoreType`). Same contract as the certificate
/// repository, with `fetch(uuid:)` in place of `fetch(fingerprint:)`.
final class ProvisioningProfileRepositoryTests: XCTestCase {

    private var stack: InMemoryCoreDataStack!
    private var repository: CoreDataProvisioningProfileRepository!

    override func setUp() {
        super.setUp()
        stack = InMemoryCoreDataStack()
        repository = CoreDataProvisioningProfileRepository(context: stack.viewContext)
    }

    override func tearDown() {
        repository = nil
        stack = nil
        super.tearDown()
    }

    func testSaveFetch_roundTrip() async throws {
        let model = FixtureBuilder.makeProvisioningModel()
        try await repository.save(model)
        let fetched = try await repository.fetch(id: model.id)
        XCTAssertEqual(fetched, model)
        XCTAssertEqual(try await repository.fetchAll().count, 1)
    }

    func testFetch_missingReturnsNil() async throws {
        XCTAssertNil(try await repository.fetch(id: UUID()))
        XCTAssertNil(try await repository.fetch(uuid: "00000000-0000-0000-0000-000000000000"))
    }

    func testFetchByUUID() async throws {
        let first = FixtureBuilder.makeProvisioningModel(
            uuid: "11111111-2222-3333-4444-555555555555")
        let second = FixtureBuilder.makeProvisioningModel(
            uuid: "22222222-3333-4444-5555-666666666666")
        try await repository.save(first)
        try await repository.save(second)
        XCTAssertEqual(
            try await repository.fetch(uuid: "22222222-3333-4444-5555-666666666666"), second)
        XCTAssertNil(try await repository.fetch(uuid: "99999999-9999-9999-9999-999999999999"))
    }

    func testSave_upsertsById() async throws {
        let id = UUID()
        let original = FixtureBuilder.makeProvisioningModel(id: id, name: "Original")
        try await repository.save(original)
        let updated = FixtureBuilder.makeProvisioningModel(id: id, name: "Updated")
        try await repository.save(updated)
        XCTAssertEqual(try await repository.fetchAll().count, 1)
        XCTAssertEqual(try await repository.fetch(id: id)?.name, "Updated")
    }

    func testDelete_removesRecord() async throws {
        let model = FixtureBuilder.makeProvisioningModel()
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

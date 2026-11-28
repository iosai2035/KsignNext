import XCTest
@testable import KsignNext

/// FileSystemManager: workspace confinement, atomic writes, managed
/// temp dirs. Every test uses its own temp workspace root.
final class FileSystemManagerTests: XCTestCase {

    private var tempDir: URL!
    private var manager: FileSystemManager!

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        manager = FileSystemManager(workspaceRoot: tempDir)
        try? manager.ensureWorkspaceExists()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        manager = nil
        super.tearDown()
    }

    func testWriteAtomically_roundTrip() throws {
        let url = try manager.folder(.certificates).appendingPathComponent("note.txt")
        let data = Data("hello workspace".utf8)
        try manager.writeAtomically(data, to: url)
        XCTAssertEqual(try manager.readData(at: url), data)
        XCTAssertEqual(try manager.fileSize(at: url), Int64(data.count))
    }

    func testWriteAtomically_rejectsPathTraversal() throws {
        XCTAssertThrowsError(try manager.validatedURL(forRelativePath: "../escape.txt")) { error in
            guard case AppError.ipa(.pathTraversalAttempt) = error else {
                return XCTFail("Expected AppError.ipa(.pathTraversalAttempt), got \(error)")
            }
        }
        XCTAssertThrowsError(try manager.validatedURL(forRelativePath: "Certificates/../../escape.txt")) { error in
            guard case AppError.ipa(.pathTraversalAttempt) = error else {
                return XCTFail("Expected AppError.ipa(.pathTraversalAttempt), got \(error)")
            }
        }
    }

    func testValidatedURL_rejectsEscapingSymlink() throws {
        let outside = tempDir.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = try manager.folder(.certificates).appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.validatedURL(link)) { error in
            guard case AppError.ipa(.pathTraversalAttempt) = error else {
                return XCTFail("Expected AppError.ipa(.pathTraversalAttempt), got \(error)")
            }
        }
    }

    func testListDirectory_throwsOnMissing() throws {
        let missing = tempDir.appendingPathComponent("NoSuchFolder", isDirectory: true)
        XCTAssertThrowsError(try manager.listDirectory(at: missing)) { error in
            // A read error must throw — never a silent empty list (W-11).
            XCTAssertTrue(error is AppError, "Expected AppError, got \(error)")
        }
    }

    func testCreateTempDirectory_insideWorkspaceTemp() throws {
        let temp = try manager.createTempDirectory(named: "import-\(UUID().uuidString)")
        let workspaceTemp = try manager.folder(.temp)
        XCTAssertTrue(FileSystemManager.isPath(temp, inside: workspaceTemp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
        manager.cleanupTempDirectory(temp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testCleanupStaleTempDirectories_removesOldKeepsNew() throws {
        let oldDir = try manager.createTempDirectory(named: "old-\(UUID().uuidString)")
        let newDir = try manager.createTempDirectory(named: "new-\(UUID().uuidString)")
        let oldDate = Date().addingTimeInterval(-2 * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: oldDir.path)
        manager.cleanupStaleTempDirectories(maxAge: 86_400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path))
        manager.cleanupTempDirectory(newDir)
    }

    func testFreeSpaceBytes_returnsValueOrNil() {
        // Never throws; nil means unknown, a value must be positive.
        let free = manager.freeSpaceBytes()
        if let free { XCTAssertGreaterThan(free, 0) }
    }

    func testMove_replacesDestination() throws {
        let folder = try manager.folder(.certificates)
        let source = folder.appendingPathComponent("source.txt")
        let destination = folder.appendingPathComponent("destination.txt")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: source)
        try manager.move(from: source, to: destination)
        XCTAssertEqual(try manager.readData(at: destination), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
}

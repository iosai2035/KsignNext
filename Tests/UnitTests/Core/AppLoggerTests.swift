import XCTest
@testable import KsignNext

/// AppLogger is the ONE log source (W-4). All tests use a throwaway
/// log file under a per-test temp directory — never the shared log.
final class AppLoggerTests: XCTestCase {

    private var tempDir: URL!
    private var logFileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FixtureBuilder.temporaryDirectory()
        logFileURL = tempDir.appendingPathComponent("logs.jsonl")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        logFileURL = nil
        super.tearDown()
    }

    func testSingleSource_twoReadersSeeIdenticalEntries() async {
        let logger = AppLogger(fileURL: logFileURL)
        await logger.info("first entry")
        await logger.warning("second entry")
        let firstRead = await logger.allEntries()
        let secondRead = await logger.allEntries()
        XCTAssertEqual(firstRead.count, 2)
        XCTAssertEqual(firstRead, secondRead)
        XCTAssertEqual(firstRead.map(\.message), ["first entry", "second entry"])
    }

    func testRingBuffer_capsAt1000() async {
        let logger = AppLogger(fileURL: logFileURL)
        for index in 0..<(AppLogger.maxInMemoryEntries + 5) {
            await logger.info("entry \(index)")
        }
        let entries = await logger.allEntries()
        XCTAssertEqual(entries.count, AppLogger.maxInMemoryEntries)
        XCTAssertEqual(entries.first?.message, "entry 5")
        XCTAssertEqual(entries.last?.message, "entry \(AppLogger.maxInMemoryEntries + 4)")
    }

    func testRedactsPasswordKeyInMessage() {
        let redacted = AppLogger.redact("password=hunter2 and token=abc")
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertTrue(redacted.contains("password"))
    }

    func testRedactsTokenInMetadata() {
        let redacted = AppLogger.redactMetadata([
            "token": "secret-token-value",
            "operation": "import",
        ])
        XCTAssertNotEqual(redacted["token"], "secret-token-value")
        XCTAssertFalse(redacted["token"]?.contains("secret-token-value") ?? false)
        XCTAssertEqual(redacted["operation"], "import")
    }

    func testPersistAndLoad_roundTrip() async {
        let writer = AppLogger(fileURL: logFileURL)
        await writer.info("persisted entry")
        await writer.error("persisted failure")
        // Give the actor a chance to flush the persisted lines.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let reader = AppLogger(fileURL: logFileURL)
        await reader.loadPersistedEntries()
        let entries = await reader.allEntries()
        XCTAssertTrue(entries.contains { $0.message == "persisted entry" })
        XCTAssertTrue(entries.contains { $0.message == "persisted failure" })
    }

    func testExportJSON_roundTrip() async throws {
        let logger = AppLogger(fileURL: logFileURL)
        await logger.info("json entry")
        await logger.warning("json warning")
        let data = try await logger.exportJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([LogEntry].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.map(\.message), ["json entry", "json warning"])
    }

    func testExportText_containsEntries() async {
        let logger = AppLogger(fileURL: logFileURL)
        await logger.info("text entry one")
        await logger.error("text entry two")
        let text = await logger.exportText()
        XCTAssertTrue(text.contains("text entry one"))
        XCTAssertTrue(text.contains("text entry two"))
    }

    func testClear_removesMemoryAndFile() async throws {
        let logger = AppLogger(fileURL: logFileURL)
        await logger.info("to be cleared")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(await logger.allEntries().isEmpty)
        try await logger.clear()
        XCTAssertTrue(await logger.allEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFileURL.path))
    }

    func testEntriesFilteredByLevel() async {
        let logger = AppLogger(fileURL: logFileURL)
        await logger.debug("debug entry")
        await logger.info("info entry")
        await logger.warning("warning entry")
        await logger.error("error entry")
        await logger.critical("critical entry")
        let errorsAndAbove = await logger.entries(matchingLevel: .error)
        XCTAssertEqual(errorsAndAbove.map(\.message), ["error entry", "critical entry"])
        let warningsAndAbove = await logger.entries(matchingLevel: .warning)
        XCTAssertEqual(warningsAndAbove.count, 3)
        let all = await logger.entries(matchingLevel: .debug)
        XCTAssertEqual(all.count, 5)
    }

    func testEntriesForOperation() async {
        let logger = AppLogger(fileURL: logFileURL)
        let operationID = UUID()
        let otherID = UUID()
        await logger.info("in operation", operationID: operationID)
        await logger.info("other operation", operationID: otherID)
        await logger.info("no operation")
        let entries = await logger.entries(forOperation: operationID)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.message, "in operation")
    }
}

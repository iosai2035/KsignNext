import XCTest
@testable import KsignNext


final class PlistTests: XCTestCase {

    func testValidXMLPlistRoundTrip() throws {
        let dict: [String: Any] = ["CFBundleIdentifier": "com.example.app", "CFBundleVersion": "1.0", "Flag": true, "Count": 3]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(decoded?["CFBundleIdentifier"] as? String, "com.example.app")
        XCTAssertEqual(decoded?["Flag"] as? Bool, true)
        XCTAssertEqual(decoded?["Count"] as? Int, 3)
    }

    func testBinaryPlistRoundTrip() throws {
        let dict: [String: Any] = ["Key": "Value"]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        XCTAssertEqual(data.prefix(6), Data("bplist".utf8))
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(decoded?["Key"] as? String, "Value")
    }

    func testCorruptPlistThrows() {
        let bad = Data("this is not a plist at all {{{".utf8)
        XCTAssertThrowsError(try PropertyListSerialization.propertyList(from: bad, options: [], format: nil))
    }

    func testTruncatedXMLPlistThrows() {
        let bad = Data("<?xml version=\"1.0\"?><plist><dict><key>Foo".utf8)
        XCTAssertThrowsError(try PropertyListSerialization.propertyList(from: bad, options: [], format: nil))
    }

    func testViewModelRefusesInvalidSave() {
        let vm = PlistEditorViewModel()
        vm.root = ["A": "1"]
        XCTAssertTrue(vm.validate())
        // A non-plist value (e.g. a raw NSObject that is not a plist type) must fail validation.
        vm.root = ["Bad": NSObject()]
        XCTAssertFalse(vm.validate())
        XCTAssertFalse(vm.save())
        XCTAssertNotNil(vm.lastValidationError)
    }

    func testViewModelAddDeleteKey() {
        let vm = PlistEditorViewModel()
        vm.root = [:]
        vm.addKey("NewKey", value: "hello")
        XCTAssertEqual(vm.root["NewKey"] as? String, "hello")
        vm.addKey("NewKey", value: "dup")
        XCTAssertEqual(vm.root["NewKey"] as? String, "hello", "Duplicate keys must not overwrite")
        vm.deleteKey("NewKey")
        XCTAssertNil(vm.root["NewKey"])
    }

    func testViewModelUndoRedo() {
        let vm = PlistEditorViewModel()
        vm.root = ["K": "1"]
        vm.setValue(key: "K", value: "2")
        XCTAssertEqual(vm.root["K"] as? String, "2")
        vm.undo()
        XCTAssertEqual(vm.root["K"] as? String, "1")
        vm.redo()
        XCTAssertEqual(vm.root["K"] as? String, "2")
    }
}

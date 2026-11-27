import XCTest
@testable import KsignNext

/// Source JSON parsing (SourcesEngine): real public sources do not
/// all use one shape. The AltStore source carries `appPermissions`
/// as ARRAYS — `privacy: [{name, usageDescription}]`,
/// `entitlements: [{name}]` — while older sources use dictionaries
/// for the same fields. One malformed app, version, or news item
/// must never fail the whole source: the good entries stay listed.
final class SourcesEngineTests: XCTestCase {

    /// A compact document modelled on the real AltStore source
    /// (cdn.altstore.io/file/altstore/apps.json, fetched 2026-11-27):
    /// array-form permissions, a dict-form privacy, one bad version,
    /// one app missing its bundle identifier, one app whose
    /// `appPermissions` is a bare string, and one bad news item.
    private var fixture: String {
        """
        {
          "name": "AltStore",
          "identifier": "com.rileytestut.AltStore",
          "iconURL": "not a url :::",
          "apps": [
            {
              "name": "AltStore",
              "bundleIdentifier": "com.rileytestut.AltStore",
              "developerName": "Riley Testut",
              "iconURL": "https://cdn.altstore.io/file/altstore/icon.png",
              "versions": [
                {
                  "version": "2.0",
                  "date": "2024-01-15T10:30:00Z",
                  "downloadURL": "https://cdn.altstore.io/file/altstore/altstore.ipa",
                  "size": 12345678
                },
                {
                  "version": "broken",
                  "date": "not-a-date",
                  "downloadURL": "https://cdn.altstore.io/file/altstore/altstore.ipa",
                  "size": 1
                }
              ],
              "appPermissions": {
                "entitlements": [
                  { "name": "get-task-allow" },
                  { "name": "com.apple.security.application-groups" }
                ],
                "privacy": [
                  {
                    "name": "LocalNetwork",
                    "usageDescription": "AltStore uses the local network to find and communicate with AltServer."
                  }
                ]
              }
            },
            {
              "name": "Delta",
              "bundleIdentifier": "com.rileytestut.Delta",
              "developerName": "Riley Testut",
              "iconURL": "https://cdn.altstore.io/file/altstore/delta.png",
              "versions": [
                {
                  "version": "1.6",
                  "date": "2024-02-01T09:00:00Z",
                  "downloadURL": "https://cdn.altstore.io/file/altstore/delta.ipa",
                  "size": 87654321
                }
              ],
              "appPermissions": {
                "entitlements": [{ "name": "get-task-allow" }],
                "privacy": {
                  "NSCameraUsageDescription": "Delta uses the camera to scan QR codes."
                }
              }
            },
            {
              "name": "Nameless",
              "developerName": "Nobody",
              "iconURL": "https://example.com/icon.png",
              "versions": []
            },
            {
              "name": "Clip",
              "bundleIdentifier": "com.rileytestut.Clip",
              "developerName": "Riley Testut",
              "iconURL": "https://cdn.altstore.io/file/altstore/clip.png",
              "versions": [
                {
                  "version": "1.0",
                  "date": "2024-03-01T09:00:00Z",
                  "downloadURL": "https://cdn.altstore.io/file/altstore/clip.ipa",
                  "size": 1111
                }
              ],
              "appPermissions": "garbage"
            }
          ],
          "news": [
            {
              "identifier": "news-1",
              "title": "AltStore 2.0 is out",
              "caption": "A big release.",
              "date": "2024-01-15T10:30:00Z"
            },
            {
              "identifier": "news-broken",
              "title": "Broken",
              "caption": "Bad date.",
              "date": "yesterday"
            }
          ]
        }
        """
    }

    private func decodeFixture() throws -> AltSource {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AltSource.self, from: Data(fixture.utf8))
    }

    func testAltStoreRealShapeParsesAndKeepsGoodApps() throws {
        let source = try decodeFixture()
        XCTAssertEqual(source.name, "AltStore")
        XCTAssertEqual(source.identifier, "com.rileytestut.AltStore")
        // The app without a bundle identifier is dropped; the other
        // three stay — including the one with garbage permissions.
        XCTAssertEqual(source.apps.map(\.name), ["AltStore", "Delta", "Clip"])
        // A malformed top-level icon URL degrades to nil, not a failure.
        XCTAssertNil(source.iconURL)
    }

    func testPrivacyArrayShape() throws {
        let source = try decodeFixture()
        let altstore = try XCTUnwrap(source.apps.first { $0.name == "AltStore" })
        let permissions = try XCTUnwrap(altstore.appPermissions)
        XCTAssertEqual(permissions.entitlements?.map(\.name),
                       ["get-task-allow", "com.apple.security.application-groups"])
        XCTAssertEqual(permissions.privacy?.count, 1)
        XCTAssertEqual(permissions.privacy?.first?.name, "LocalNetwork")
        XCTAssertEqual(
            permissions.privacy?.first?.description,
            "AltStore uses the local network to find and communicate with AltServer.")
    }

    func testPrivacyDictionaryShape() throws {
        let source = try decodeFixture()
        let delta = try XCTUnwrap(source.apps.first { $0.name == "Delta" })
        let privacy = try XCTUnwrap(delta.appPermissions?.privacy)
        XCTAssertEqual(privacy.count, 1)
        XCTAssertEqual(privacy.first?.name, "NSCameraUsageDescription")
        XCTAssertEqual(privacy.first?.description, "Delta uses the camera to scan QR codes.")
    }

    func testBadVersionDroppedNotApp() throws {
        let source = try decodeFixture()
        let altstore = try XCTUnwrap(source.apps.first { $0.name == "AltStore" })
        XCTAssertEqual(altstore.versions.count, 1)
        XCTAssertEqual(altstore.versions.first?.version, "2.0")
        XCTAssertEqual(altstore.latestVersion?.version, "2.0")
    }

    func testGarbagePermissionsYieldNilNotDroppedApp() throws {
        let source = try decodeFixture()
        let clip = try XCTUnwrap(source.apps.first { $0.name == "Clip" })
        XCTAssertNil(clip.appPermissions)
        XCTAssertEqual(clip.versions.count, 1)
    }

    func testBadNewsItemDroppedNotSource() throws {
        let source = try decodeFixture()
        XCTAssertEqual(source.news?.count, 1)
        XCTAssertEqual(source.news?.first?.identifier, "news-1")
    }

    func testDecodedSourceRoundTrips() throws {
        let source = try decodeFixture()
        let encoder = JSONEncoder()
        let data = try encoder.encode(source)
        let decoded = try JSONDecoder().decode(AltSource.self, from: data)
        XCTAssertEqual(decoded, source)
    }

    /// The exact failure the user hit on the real AltStore source:
    /// `privacy` as an array used to throw
    /// "Type mismatch: expected Dictionary<String, Any>", which
    /// failed the whole source and showed zero apps.
    func testRealAltStorePrivacyArrayDoesNotThrow() throws {
        let json = """
        {
          "name": "AltStore",
          "identifier": "com.rileytestut.AltStore",
          "apps": [
            {
              "name": "AltStore",
              "bundleIdentifier": "com.rileytestut.AltStore",
              "developerName": "Riley Testut",
              "iconURL": "https://cdn.altstore.io/file/altstore/icon.png",
              "versions": [
                {
                  "version": "2.0",
                  "date": "2024-01-15T10:30:00Z",
                  "downloadURL": "https://cdn.altstore.io/file/altstore/altstore.ipa",
                  "size": 12345678
                }
              ],
              "appPermissions": {
                "entitlements": [{ "name": "get-task-allow" }],
                "privacy": [{ "name": "LocalNetwork", "usageDescription": "AltStore uses the local network." }]
              }
            }
          ]
        }
        """
        let source = try JSONDecoder().decode(AltSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.apps.count, 1)
        XCTAssertEqual(source.apps.first?.appPermissions?.privacy?.first?.name, "LocalNetwork")
    }
}

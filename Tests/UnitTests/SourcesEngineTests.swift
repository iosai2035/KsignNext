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

    /// A malformed app icon URL must not drop the app: the icon is
    /// display metadata, so it degrades to nil and the app stays
    /// listed (the old strict decode threw and lost the app).
    func testMalformedAppIconURLDegradesToNilNotDroppedApp() throws {
        let json = """
        {
          "name": "Test",
          "identifier": "com.example.test",
          "apps": [
            {
              "name": "Good Icon",
              "bundleIdentifier": "com.example.good",
              "developerName": "Example",
              "iconURL": "https://example.com/good.png",
              "versions": [
                {
                  "version": "1.0",
                  "date": "2024-01-15T10:30:00Z",
                  "downloadURL": "https://example.com/good.ipa",
                  "size": 100
                }
              ]
            },
            {
              "name": "Bad Icon",
              "bundleIdentifier": "com.example.bad",
              "developerName": "Example",
              "iconURL": "not a url :::",
              "versions": [
                {
                  "version": "1.0",
                  "date": "2024-01-15T10:30:00Z",
                  "downloadURL": "https://example.com/bad.ipa",
                  "size": 100
                }
              ]
            },
            {
              "name": "No Icon",
              "bundleIdentifier": "com.example.noicon",
              "developerName": "Example",
              "versions": [
                {
                  "version": "1.0",
                  "date": "2024-01-15T10:30:00Z",
                  "downloadURL": "https://example.com/noicon.ipa",
                  "size": 100
                }
              ]
            }
          ]
        }
        """
        let source = try JSONDecoder().decode(AltSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.apps.map(\.name), ["Good Icon", "Bad Icon", "No Icon"])
        XCTAssertEqual(source.apps.first { $0.name == "Good Icon" }?.iconURL?.absoluteString, "https://example.com/good.png")
        XCTAssertNil(source.apps.first { $0.name == "Bad Icon" }?.iconURL)
        XCTAssertNil(source.apps.first { $0.name == "No Icon" }?.iconURL)
    }

    /// Non-AltStore wire shapes must decode (deep dive Pass 2,
    /// SRC-2): date-only, space-separated and epoch dates; Double,
    /// digits-string and missing sizes. An unparseable size such as
    /// "12.5MB" degrades to 0 rather than a wrong unit.
    func testNonAltStoreVersionShapesDecode() throws {
        let json = """
        {
          "name": "Test",
          "identifier": "com.example.test",
          "apps": [
            {
              "name": "Odd Shapes",
              "bundleIdentifier": "com.example.odd",
              "developerName": "Example",
              "versions": [
                {
                  "version": "1.0",
                  "date": "2024-01-15",
                  "downloadURL": "https://example.com/odd-1.0.ipa",
                  "size": 100
                },
                {
                  "version": "1.1",
                  "date": "2024-01-15 10:30:00",
                  "downloadURL": "https://example.com/odd-1.1.ipa",
                  "size": 123.45
                },
                {
                  "version": "1.2",
                  "date": 1705400000,
                  "downloadURL": "https://example.com/odd-1.2.ipa",
                  "size": "12345"
                },
                {
                  "version": "1.3",
                  "date": "1705320600",
                  "downloadURL": "https://example.com/odd-1.3.ipa",
                  "size": "12.5MB"
                },
                {
                  "version": "1.4",
                  "date": "2024-01-15T10:30:00Z",
                  "downloadURL": "https://example.com/odd-1.4.ipa"
                }
              ]
            }
          ]
        }
        """
        let source = try JSONDecoder().decode(AltSource.self, from: Data(json.utf8))
        let app = try XCTUnwrap(source.apps.first { $0.name == "Odd Shapes" })
        XCTAssertEqual(app.versions.count, 5)
        XCTAssertEqual(app.versions.map(\.size), [100, 123, 12345, 0, 0])
        let expectedDayStart = ISO8601DateFormatter().date(from: "2024-01-15T00:00:00Z")
        XCTAssertEqual(app.versions.first { $0.version == "1.0" }?.date, expectedDayStart)
        XCTAssertEqual(app.latestVersion?.version, "1.2")
    }

    /// A genuinely unparseable date still drops the version (the
    /// existing testBadVersionDroppedNotApp behavior is preserved);
    /// tolerance is for unusual-but-valid shapes, not garbage.
    func testUnparseableDateStillDropsVersion() throws {
        let json = """
        {
          "name": "Test",
          "identifier": "com.example.test",
          "apps": [
            {
              "name": "Bad Date",
              "bundleIdentifier": "com.example.baddate",
              "developerName": "Example",
              "versions": [
                {
                  "version": "1.0",
                  "date": "not-a-date",
                  "downloadURL": "https://example.com/bad.ipa",
                  "size": 100
                },
                {
                  "version": "1.1",
                  "date": "2024-01-15T10:30:00Z",
                  "downloadURL": "https://example.com/missing.ipa",
                  "size": 100
                }
              ]
            }
          ]
        }
        """
        let source = try JSONDecoder().decode(AltSource.self, from: Data(json.utf8))
        let app = try XCTUnwrap(source.apps.first { $0.name == "Bad Date" })
        // Only the ISO-dated version survives; the "not-a-date"
        // version is dropped (it is the second entry in the JSON,
        // so the surviving one is the 1.1 version).
        XCTAssertEqual(app.versions.count, 1)
        XCTAssertEqual(app.versions.first?.version, "1.1")
    }
}

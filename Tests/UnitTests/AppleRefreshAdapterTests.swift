import XCTest
@testable import KsignNext

/// Pure-Swift coverage of the Apple-refresh adapter: error mapping,
/// claim presets, session-config JSON, and the 2FA prompt/response
/// shapes. No FFI call is made here — the Rust core is exercised by
/// CI's simulator build and, ultimately, by the on-device sign-in.
final class AppleRefreshAdapterTests: XCTestCase {

    // MARK: - Error mapping

    func testAppleAuth22410MapsWithExplanation() {
        let error = AppleRefreshError.from(json: [
            "ok": false,
            "error": ["code": "apple_auth", "step": "login",
                      "apple_ec": -22410,
                      "apple_em": "This action could not be completed",
                      "http_status": NSNull(),
                      "message": "GrandSlam error -22410"] as [String: Any],
        ], step: "login")
        guard case .appleAuth(let ec, _, _) = error else {
            return XCTFail("Expected appleAuth, got \(error)")
        }
        XCTAssertEqual(ec, -22410)
        XCTAssertTrue(error.errorDescription?.contains("-22410") == true)
    }

    func testAccountLockedMapsFrom20209() {
        let error = AppleRefreshError.from(json: [
            "ok": false,
            "error": ["code": "account_locked", "step": "login",
                      "apple_ec": -20209, "apple_em": NSNull(),
                      "http_status": NSNull(), "message": "locked"] as [String: Any],
        ], step: "login")
        XCTAssertEqual(error, .accountLocked)
    }

    func testUnknownCodeMapsToInternal() {
        let error = AppleRefreshError.from(json: [
            "ok": false,
            "error": ["code": "something_new", "step": "login",
                      "apple_ec": NSNull(), "apple_em": NSNull(),
                      "http_status": NSNull(), "message": "boom"] as [String: Any],
        ], step: "login")
        XCTAssertEqual(error, .internalError(reason: "boom"))
    }

    // MARK: - Claims

    func testSideinstallerClaimStringsAreExact() {
        XCTAssertEqual(
            AppleRefreshClaim.sideinstaller.clientInfo,
            "<MacBookPro16,1> <Mac OS X;10.15.7;19H2> <com.apple.AuthKit/1 (com.apple.akd/1.0)>")
        XCTAssertEqual(
            AppleRefreshClaim.sideinstaller.userAgent,
            "akd/1.0 CFNetwork/1121.1.2 Darwin/19.7.0")
    }

    func testApparitionClaimStringsAreExact() {
        XCTAssertEqual(
            AppleRefreshClaim.apparition.clientInfo,
            "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>")
        XCTAssertEqual(
            AppleRefreshClaim.apparition.userAgent,
            "akd/1.0 CFNetwork/808.1.4")
    }

    func testCustomClaimRejectsControlCharacters() {
        XCTAssertThrowsError(
            try AppleRefreshClaim.custom(clientInfo: "bad\ninfo", userAgent: "ok").jsonObject())
        XCTAssertThrowsError(
            try AppleRefreshClaim.custom(clientInfo: "", userAgent: "ok").jsonObject())
        XCTAssertNoThrow(
            try AppleRefreshClaim.custom(clientInfo: "<Mac1,1> <Mac OS X;10.15.7;19H2> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
                                         userAgent: "akd/1.0").jsonObject())
    }

    func testServerClaimHasNoClientInfo() {
        XCTAssertNil(AppleRefreshClaim.server.clientInfo)
        XCTAssertNil(AppleRefreshClaim.server.userAgent)
        XCTAssertEqual(AppleRefreshClaim.server.presetName, "server")
    }

    // MARK: - Session config JSON

    func testSessionConfigJSON() throws {
        let config = AppleRefreshSessionConfig(
            anisetteServerURL: "https://mac-ani.jkcoxson.com",
            storageDirectory: URL(fileURLWithPath: "/tmp/AppleRefresh"),
            signInClaim: .sideinstaller)
        let text = try config.jsonString()
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Config JSON is not a JSON object: \(text)")
        }
        XCTAssertEqual(json["anisette_server_url"] as? String,
                       "https://mac-ani.jkcoxson.com")
        XCTAssertEqual(json["serial_number"] as? String, "0")
        XCTAssertEqual(json["err_429_retries"] as? Int, 10)
        let claim = json["sign_in_claim"] as? [String: Any]
        XCTAssertEqual(claim?["preset"] as? String, "sideinstaller")
    }

    // MARK: - 2FA shapes

    func testPollPromptDecoding() {
        // The real isideload shape: TwoFactorCallbackParams carries
        // #[serde(rename_all = "camelCase")] on its own fields, while
        // its nested TrustedNumber has no rename, so the number
        // fields stay snake_case. A fixture in one case only would
        // pass while the live prompt lost fields.
        let json: [String: Any] = [
            "pending": true,
            "prompt": [
                "unknown": false, "sms": true, "lastError": NSNull(),
                "numbers": [["id": 2, "number_with_dial_code": "+1 ••• ••• 68",
                             "last_two_digits": "68", "push_mode": "sms"]],
                "selectedNumberId": NSNull(),
            ] as [String: Any],
        ]
        guard let prompt = TwoFactorPrompt.from(json: json) else {
            return XCTFail("Prompt did not decode")
        }
        XCTAssertTrue(prompt.sms)
        XCTAssertEqual(prompt.numbers.count, 1)
        XCTAssertEqual(prompt.numbers[0].id, 2)
        XCTAssertEqual(prompt.numbers[0].numberWithDialCode, "+1 ••• ••• 68")
        XCTAssertEqual(prompt.numbers[0].lastTwoDigits, "68")
        XCTAssertNil(prompt.lastError)
        XCTAssertNil(prompt.selectedNumberID)
    }

    func testPollPromptDecodingSMSState() {
        // After choosing SMS, isideload re-prompts with sms: true, a
        // selected number, and a lastError when a previous code was
        // wrong — all three must survive decoding.
        let json: [String: Any] = [
            "pending": true,
            "prompt": [
                "unknown": false, "sms": true, "lastError": "Incorrect verification code",
                "numbers": [["id": 2, "number_with_dial_code": "+1 ••• ••• 68",
                             "last_two_digits": "68", "push_mode": "sms"]],
                "selectedNumberId": 2,
            ] as [String: Any],
        ]
        guard let prompt = TwoFactorPrompt.from(json: json) else {
            return XCTFail("Prompt did not decode")
        }
        XCTAssertTrue(prompt.sms)
        XCTAssertEqual(prompt.lastError, "Incorrect verification code")
        XCTAssertEqual(prompt.selectedNumberID, 2)
        XCTAssertEqual(prompt.numbers[0].lastTwoDigits, "68")
    }

    func testTwoFactorResponseJSON() throws {
        let code = try TwoFactorResponse.code("123456").jsonString()
        XCTAssertTrue(code.contains("\"code\""))
        XCTAssertTrue(code.contains("123456"))
        let sms = try TwoFactorResponse.sms(id: 2).jsonString()
        XCTAssertTrue(sms.contains("\"sms\""))
        XCTAssertThrowsError(try TwoFactorResponse.code("12345").jsonString())
        XCTAssertThrowsError(try TwoFactorResponse.code("12345a").jsonString())
        XCTAssertNoThrow(try TwoFactorResponse.abort.jsonString())
    }

    func testLoginResultDecoding() {
        let result = AppleIDLoginResult.from(json: [
            "ok": true, "email": "test@example.com",
            "first_name": "Test", "last_name": "User", "adsid": "abc-123",
        ])
        XCTAssertEqual(result.email, "test@example.com")
        XCTAssertEqual(result.firstName, "Test")
        XCTAssertEqual(result.adsid, "abc-123")
    }
}

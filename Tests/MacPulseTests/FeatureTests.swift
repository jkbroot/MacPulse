import XCTest
@testable import MacPulse

final class PublicIPTests: XCTestCase {
    func testParsesValidResponse() {
        let i = PublicIPService.parse(Data(#"{"ip":"8.8.8.8","country":"US","org":"AS15169 Google LLC"}"#.utf8))
        XCTAssertEqual(i?.ip, "8.8.8.8"); XCTAssertEqual(i?.countryCode, "US")
        XCTAssertEqual(PublicIPService.parse(Data(#"{"ip":"2001:4860:4860::8888","country":"SA"}"#.utf8))?.countryCode, "SA")
    }

    /// A compromised or spoofed endpoint must not be able to put arbitrary text in the menu bar.
    func testRejectsHostileResponses() {
        XCTAssertNil(PublicIPService.parse(Data(#"{"ip":"<script>alert(1)</script>"}"#.utf8)))
        XCTAssertNil(PublicIPService.parse(Data(#"{"ip":"1.2.3.4 evil"}"#.utf8)))
        XCTAssertNil(PublicIPService.parse(Data(String(repeating: "a", count: 9000).utf8)))
        let bad = PublicIPService.parse(Data(#"{"ip":"1.2.3.4","country":"🏴‍☠️X","org":"a\u0000\u001bb"}"#.utf8))
        XCTAssertNil(bad?.countryCode)
        XCTAssertEqual(bad?.org, "ab")
    }

    func testFlag() {
        XCTAssertEqual(flagEmoji("SA"), "🇸🇦")
        XCTAssertEqual(flagEmoji("us"), "🇺🇸")
    }
}

final class MCPToolTests: XCTestCase {
    func testAllToolsAreReadOnly() {
        for t in Tools.definitions {
            let a = t["annotations"] as? [String: Any]
            XCTAssertEqual(a?["readOnlyHint"] as? Bool, true, "\(t["name"] ?? "")")
            XCTAssertEqual(a?["destructiveHint"] as? Bool, false)
        }
    }

    func testRejectsInvalidArguments() {
        XCTAssertThrowsError(try Tools.call("get_top_apps", ["range": "; DROP TABLE app_hour"]))
        XCTAssertThrowsError(try Tools.call("get_top_apps", ["sort_by": "name; --"]))
        XCTAssertThrowsError(try Tools.call("run_shell", [:]))
        XCTAssertEqual(Tools.clamp(1e308, 1, 50, 15), 50)
        XCTAssertEqual(Tools.clamp("x", 1, 50, 15), 15)
    }
}

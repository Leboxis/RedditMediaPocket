import Foundation
import XCTest
@testable import MediaCore

final class XWebNavigationTests: XCTestCase {
    func testDirectSignInOpensLoginFlow() {
        XCTAssertEqual(XWebNavigation.loginURL.absoluteString, "https://x.com/i/flow/login")
    }

    func testPopupsStayOnApprovedXHosts() {
        XCTAssertTrue(XWebNavigation.allowsPopup(URL(string: "https://x.com/i/flow/login")!))
        XCTAssertTrue(XWebNavigation.allowsPopup(URL(string: "https://accounts.x.com/")!))
        XCTAssertFalse(XWebNavigation.allowsPopup(URL(string: "https://x.com.attacker.example/")!))
        XCTAssertFalse(XWebNavigation.allowsPopup(URL(string: "https://example.com/login")!))
        XCTAssertFalse(XWebNavigation.allowsPopup(URL(string: "http://x.com/")!))
    }

    func testDirectLoginStaysOnApprovedXHost() {
        XCTAssertTrue(XTwitterCookiePolicy.allows(XWebNavigation.loginURL))
    }
}

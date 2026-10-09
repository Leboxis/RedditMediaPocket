import Foundation
import XCTest
@testable import MediaCore

final class XWebNavigationTests: XCTestCase {
    func testSignInOpensLandingPageBeforeLoginFlow() {
        XCTAssertEqual(XWebNavigation.initialURL(for: .signIn).absoluteString, "https://x.com/")
        XCTAssertEqual(XWebNavigation.loginURL.absoluteString, "https://x.com/i/flow/login")
    }

    func testFeedOpensHomeWhileKeepingSeparateLoginFallback() {
        XCTAssertEqual(XWebNavigation.initialURL(for: .feed).absoluteString, "https://x.com/home")
    }

    func testPopupsStayOnApprovedXHosts() {
        XCTAssertTrue(XWebNavigation.allowsPopup(URL(string: "https://x.com/i/flow/login")!))
        XCTAssertTrue(XWebNavigation.allowsPopup(URL(string: "https://accounts.x.com/")!))
        XCTAssertFalse(XWebNavigation.allowsPopup(URL(string: "https://x.com.attacker.example/")!))
        XCTAssertFalse(XWebNavigation.allowsPopup(URL(string: "https://example.com/login")!))
        XCTAssertFalse(XWebNavigation.allowsPopup(URL(string: "http://x.com/")!))
    }

    func testRecoveryURLsStayOnXAndNotThirdPartyDomains() {
        XCTAssertTrue(XTwitterCookiePolicy.allows(XWebNavigation.initialURL(for: .signIn)))
        XCTAssertTrue(XTwitterCookiePolicy.allows(XWebNavigation.loginURL))
        XCTAssertTrue(XTwitterCookiePolicy.allows(XWebNavigation.initialURL(for: .feed)))
    }
}

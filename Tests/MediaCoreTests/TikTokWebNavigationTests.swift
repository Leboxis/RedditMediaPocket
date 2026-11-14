import XCTest
@testable import MediaCore

final class TikTokWebNavigationTests: XCTestCase {
    func testLoginURLIsTikTokHomepage() {
        XCTAssertEqual(TikTokWebNavigation.loginURL.absoluteString, "https://www.tiktok.com/")
    }

    func testAllowsTikTokHosts() {
        XCTAssertTrue(TikTokWebNavigation.allowsLogin(URL(string: "https://www.tiktok.com/")!))
        XCTAssertTrue(TikTokWebNavigation.allowsLogin(URL(string: "https://sso.tiktok.com/oidc/")!))
    }

    func testAllowsSocialSignInProviders() {
        XCTAssertTrue(TikTokWebNavigation.allowsLogin(URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=abc")!))
        XCTAssertTrue(TikTokWebNavigation.allowsLogin(URL(string: "https://accounts.youtube.com/")!))
        XCTAssertTrue(TikTokWebNavigation.allowsLogin(URL(string: "https://www.facebook.com/login/")!))
        XCTAssertTrue(TikTokWebNavigation.allowsLogin(URL(string: "https://m.facebook.com/")!))
        XCTAssertTrue(TikTokWebNavigation.allowsLogin(URL(string: "https://appleid.apple.com/auth/authorize")!))
        XCTAssertTrue(TikTokWebNavigation.allowsPopup(URL(string: "https://accounts.google.com/")!))
    }

    func testRejectsOtherDomains() {
        XCTAssertFalse(TikTokWebNavigation.allowsLogin(URL(string: "https://example.com/login")!))
        XCTAssertFalse(TikTokWebNavigation.allowsLogin(URL(string: "https://tiktok.com.attacker.example/")!))
        XCTAssertFalse(TikTokWebNavigation.allowsLogin(URL(string: "https://google.com/")!))
        XCTAssertFalse(TikTokWebNavigation.allowsLogin(URL(string: "https://accounts.google.com.evil.example/")!))
    }

    func testRejectsNonHTTPS() {
        XCTAssertFalse(TikTokWebNavigation.allowsLogin(URL(string: "http://accounts.google.com/")!))
        XCTAssertFalse(TikTokWebNavigation.allowsLogin(URL(string: "http://www.tiktok.com/")!))
    }

    func testSessionCookiesNeverReachSignInProviders() {
        XCTAssertFalse(TikTokCookiePolicy.allows(URL(string: "https://accounts.google.com/")!))
        XCTAssertFalse(TikTokCookiePolicy.allows(URL(string: "https://www.facebook.com/login/")!))
        XCTAssertFalse(TikTokCookiePolicy.allows(URL(string: "https://appleid.apple.com/")!))
    }
}

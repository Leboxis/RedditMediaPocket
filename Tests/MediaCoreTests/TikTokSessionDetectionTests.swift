import Foundation
import XCTest
@testable import MediaCore

final class TikTokSessionDetectionTests: XCTestCase {
    private func cookie(_ name: String, _ domain: String = ".tiktok.com",
                        expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "example", .domain: domain, .path: "/"
        ]
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    func testRecognizesLoginBeforeDeviceTokenIsIssued() throws {
        let session = try cookie("sessionid")
        XCTAssertTrue(TikTokCookiePolicy.hasLoginCookie(cookies: [session]))
        XCTAssertFalse(TikTokCookiePolicy.hasCredentials(cookies: [session]))
        XCTAssertNil(TikTokCookiePolicy.msToken(cookies: [session]))
    }

    func testCredentialsRequireSessionAndDeviceCookie() throws {
        let both = [try cookie("sessionid"), try cookie("ttwid")]
        XCTAssertTrue(TikTokCookiePolicy.hasCredentials(cookies: both))
        XCTAssertFalse(TikTokCookiePolicy.hasCredentials(cookies: [try cookie("ttwid")]))
    }

    func testRejectsOnlyDeviceTokenOrUnrelatedCookie() throws {
        XCTAssertFalse(TikTokCookiePolicy.hasLoginCookie(cookies: [try cookie("ttwid")]))
        XCTAssertFalse(TikTokCookiePolicy.hasLoginCookie(cookies: [try cookie("sessionid", ".reddit.com")]))
        XCTAssertFalse(TikTokCookiePolicy.hasLoginCookie(cookies: [try cookie("sessionid", ".x.com")]))
    }

    func testRejectsExpiredLoginCookie() throws {
        let expired = try cookie("sessionid", expires: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(TikTokCookiePolicy.hasLoginCookie(cookies: [expired]))
    }

    func testCookieHeaderStaysOnTikTokHosts() throws {
        let session = try cookie("sessionid")
        let allowed = URL(string: "https://www.tiktok.com/@nasa")!
        let denied = URL(string: "https://v16-webapp-prime.tiktokcdn.com/video/a.mp4")!
        XCTAssertNotNil(TikTokCookiePolicy.header(cookies: [session], for: allowed))
        XCTAssertNil(TikTokCookiePolicy.header(cookies: [session], for: denied))
        XCTAssertFalse(TikTokCookiePolicy.allows(denied))
        XCTAssertFalse(TikTokCookiePolicy.allows(URL(string: "http://www.tiktok.com/")!))
        XCTAssertFalse(TikTokCookiePolicy.allows(URL(string: "https://tiktok.com.attacker.example/")!))
    }
}

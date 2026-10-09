import Foundation
import XCTest
@testable import MediaCore

final class XSessionDetectionTests: XCTestCase {
    private func cookie(_ name: String, _ domain: String = ".x.com",
                        expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "example", .domain: domain, .path: "/"
        ]
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    func testRecognizesLoginBeforeCSRFIsIssued() throws {
        let auth = try cookie("auth_token")
        XCTAssertTrue(XTwitterCookiePolicy.hasLoginCookie(cookies: [auth]))
        XCTAssertFalse(XTwitterCookiePolicy.hasCredentials(cookies: [auth]))
        XCTAssertNil(XTwitterCookiePolicy.csrfToken(cookies: [auth]))
    }

    func testRejectsOnlyCSRFOrUnrelatedCookie() throws {
        XCTAssertFalse(XTwitterCookiePolicy.hasLoginCookie(cookies: [try cookie("ct0")]))
        XCTAssertFalse(XTwitterCookiePolicy.hasLoginCookie(cookies: [try cookie("auth_token", ".reddit.com")]))
    }

    func testRejectsExpiredLoginCookie() throws {
        let expired = try cookie("auth_token", expires: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(XTwitterCookiePolicy.hasLoginCookie(cookies: [expired]))
    }
}

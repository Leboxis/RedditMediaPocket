import Foundation
import XCTest
@testable import MediaCore

final class XSessionDetectionTests: XCTestCase {
    func testRecognizesLoginBeforeCSRFIsIssued() throws {
        let auth = try XCTUnwrap(HTTPCookie(properties: [
            .name: "auth_token",
            .value: "example",
            .domain: ".x.com",
            .path: "/"
        ]))
        XCTAssertTrue(XTwitterCookiePolicy.hasCredentials(cookies: [auth]))
        XCTAssertNil(XTwitterCookiePolicy.csrfToken(cookies: [auth]))
    }
}

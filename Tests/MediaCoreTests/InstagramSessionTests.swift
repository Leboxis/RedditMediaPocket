import XCTest
@testable import MediaCore
import Foundation

/// Politique de cookies de la session Instagram et en-têtes qu'elle produit.
final class InstagramSessionTests: XCTestCase {
    private func cookie(_ name: String, _ value: String = "v", domain: String = ".instagram.com",
                        expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: "/"
        ]
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    func testLoginCookieDetection() throws {
        XCTAssertFalse(InstagramCookiePolicy.hasLoginCookie(cookies: []))
        XCTAssertTrue(InstagramCookiePolicy.hasLoginCookie(cookies: [try cookie("sessionid")]))
        // Un cookie homonyme d'un autre domaine ne vaut pas session Instagram.
        XCTAssertFalse(InstagramCookiePolicy.hasLoginCookie(cookies: [try cookie("sessionid", "v", domain: ".reddit.com")]))
        XCTAssertFalse(InstagramCookiePolicy.hasLoginCookie(cookies: [try cookie("csrftoken")]))
        let expired = try cookie("sessionid", expires: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(InstagramCookiePolicy.hasLoginCookie(cookies: [expired]))
    }

    /// `csrftoken` accompagne `sessionid` : sans lui, l'appel GraphQL est refusé.
    func testCredentialsNeedCsrfToken() throws {
        let session = try cookie("sessionid")
        XCTAssertFalse(InstagramCookiePolicy.hasCredentials(cookies: [session]))
        let both = [session, try cookie("csrftoken", "abc-DEF_1")]
        XCTAssertTrue(InstagramCookiePolicy.hasCredentials(cookies: both))
    }

    func testCookieHeaderScopedToInstagram() throws {
        let cookies = [try cookie("sessionid", "secret"), try cookie("csrftoken", "csrf-value")]
        let header = try XCTUnwrap(InstagramCookiePolicy.header(
            cookies: cookies, for: InstagramAPI.profilePageURL(username: "nasa")))
        XCTAssertTrue(header.contains("sessionid=secret"))
        XCTAssertTrue(header.contains("csrftoken=csrf-value"))
        // Les CDN de médias et les autres sites ne reçoivent jamais la session.
        let cdn = try XCTUnwrap(URL(string: "https://scontent.cdninstagram.com/v/t51/x.jpg"))
        XCTAssertNil(InstagramCookiePolicy.header(cookies: cookies, for: cdn))
        let foreign = try XCTUnwrap(URL(string: "https://www.reddit.com/"))
        XCTAssertNil(InstagramCookiePolicy.header(cookies: cookies, for: foreign))
    }

    func testNavigationAllowsInstagramAndItsProviders() throws {
        XCTAssertEqual(InstagramWebNavigation.loginURL.absoluteString, "https://www.instagram.com/accounts/login/")
        XCTAssertTrue(InstagramWebNavigation.allowsLogin(InstagramWebNavigation.loginURL))
        XCTAssertTrue(InstagramWebNavigation.allowsPopup(InstagramWebNavigation.loginURL))
        let provider = try XCTUnwrap(URL(string: "https://www.facebook.com/dialog/oauth"))
        XCTAssertTrue(InstagramWebNavigation.allowsLogin(provider))
        // Un domaine qui imite Instagram reste refusé.
        let hostile = try XCTUnwrap(URL(string: "https://instagram.com.attacker.example/login"))
        XCTAssertFalse(InstagramWebNavigation.allowsLogin(hostile))
        XCTAssertFalse(InstagramWebNavigation.allowsPopup(hostile))
    }

    /// La session remplace les jetons anonymes : son cookie complet part dans
    /// `Cookie` et son `csrftoken` dans `X-CSRF-Token`.
    func testGraphQLHeadersUseSession() throws {
        let tokens = InstagramAPI.Tokens(lsd: "LSD123", csrf: "cookie-csrf")
        let url = InstagramAPI.profilePageURL(username: "nasa")

        let anonymous = InstagramAPI.graphqlHeaders(tokens: tokens, referer: url)
        XCTAssertEqual(anonymous["Cookie"], "csrftoken=cookie-csrf")
        XCTAssertEqual(anonymous["X-CSRF-Token"], "cookie-csrf")

        let session = InstagramAPI.graphqlHeaders(tokens: tokens, referer: url,
                                                  sessionCookies: "sessionid=abc; csrftoken=sess-csrf")
        XCTAssertEqual(session["Cookie"], "sessionid=abc; csrftoken=sess-csrf")
        XCTAssertEqual(session["X-CSRF-Token"], "sess-csrf")
        XCTAssertEqual(session["X-FB-LSD"], "LSD123")
    }

    func testPageHeadersCarrySessionCookie() throws {
        let url = InstagramAPI.profilePageURL(username: "nasa")
        XCTAssertNil(InstagramAPI.pageHeaders(referer: url)["Cookie"])
        XCTAssertEqual(InstagramAPI.pageHeaders(referer: url, sessionCookies: "sessionid=abc")["Cookie"],
                       "sessionid=abc")
    }
}

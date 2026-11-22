import XCTest
@testable import RedditMediaPocket

/// Les cookies ne doivent jamais quitter le domaine de leur site, et doivent
/// survivre à un aller-retour JSON sans perdre les attributs utiles à WebKit.
final class CookieSyncTests: XCTestCase {
    func testFiltreDeDomaine() {
        XCTAssertTrue(SiteSession.reddit.accepte(domain: ".reddit.com"))
        XCTAssertTrue(SiteSession.reddit.accepte(domain: "www.reddit.com"))
        XCTAssertFalse(SiteSession.reddit.accepte(domain: "reddit.com.attacker.example"))
        XCTAssertFalse(SiteSession.reddit.accepte(domain: "redd.it"))

        XCTAssertTrue(SiteSession.x.accepte(domain: ".twitter.com"))
        XCTAssertTrue(SiteSession.x.accepte(domain: "x.com"))
        XCTAssertFalse(SiteSession.x.accepte(domain: "pbs.twimg.com"))

        XCTAssertTrue(SiteSession.tiktok.accepte(domain: "v16-webapp-prime.tiktok.com"))
        XCTAssertFalse(SiteSession.tiktok.accepte(domain: "tiktokcdn.com"))

        XCTAssertTrue(SiteSession.instagram.accepte(domain: ".instagram.com"))
        XCTAssertFalse(SiteSession.instagram.accepte(domain: "scontent.cdninstagram.com"))
    }

    func testAllerRetourHTTPCookie() throws {
        let expiration = Date().addingTimeInterval(3_600)
        let original = HTTPCookie(properties: [
            .name: "reddit_session",
            .value: "valeur-de-test",
            .domain: ".reddit.com",
            .path: "/",
            .expires: expiration,
            .secure: true,
            .httpOnly: true,
            .version: 0,
        ])!
        let record = try XCTUnwrap(CookieRecord(cookie: original))
        let reconstruit = try XCTUnwrap(record.makeCookie())

        XCTAssertEqual(reconstruit.name, original.name)
        XCTAssertEqual(reconstruit.value, original.value)
        XCTAssertEqual(reconstruit.domain, original.domain)
        XCTAssertEqual(reconstruit.path, original.path)
        XCTAssertEqual(reconstruit.isSecure, original.isSecure)
        XCTAssertEqual(reconstruit.isHTTPOnly, original.isHTTPOnly)
        XCTAssertEqual(
            reconstruit.expiresDate?.timeIntervalSinceReferenceDate ?? 0,
            expiration.timeIntervalSinceReferenceDate,
            accuracy: 1
        )
    }

    func testCookieExpireEstIgnore() {
        var record = CookieRecord(
            name: "ancien",
            value: "x",
            domain: ".reddit.com",
            path: "/",
            expires: Date().addingTimeInterval(-60)
        )
        XCTAssertNil(record.makeCookie())
        record.expires = nil
        XCTAssertNotNil(record.makeCookie())
    }

    func testDecodageSauvegardeServeur() throws {
        let json = """
        {"sites":{"reddit":[{"name":"reddit_session","value":"v","domain":".reddit.com",\
        "path":"/","expires":null,"secure":true,"httpOnly":true,"version":0}]},\
        "updated_at":"2026-11-22 09:00:00"}
        """
        let sauvegarde = try JSONDecoder().decode(CookiesBackup.self, from: Data(json.utf8))
        XCTAssertEqual(sauvegarde.sites["reddit"]?.count, 1)
        XCTAssertEqual(sauvegarde.sites["reddit"]?.first?.name, "reddit_session")
        XCTAssertEqual(sauvegarde.updatedAt, "2026-11-22 09:00:00")
    }
}

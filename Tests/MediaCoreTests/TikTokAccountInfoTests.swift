import XCTest
@testable import MediaCore

/// Identité du compte connecté TikTok.
///
/// Le nom d'une collection `ts/…` ne doit venir que de `/passport/web/account/info/`,
/// la route que le site appelle lui-même. Le grattage du DOM avait produit une
/// collection `ts/<créateur du fil>` : le premier lien `/@` d'une page de fil
/// n'est jamais le compte connecté.
final class TikTokAccountInfoTests: XCTestCase {
    func testReadsWrappedAccountInfo() throws {
        let json = #"""
        {"message":"success","data":{"username":"alxx","sec_uid":"MS4wLjABAAAAxyz","user_id":"123"}}
        """#
        let account = try XCTUnwrap(TikTokAPI.parseAccountInfo(Data(json.utf8)))
        XCTAssertEqual(account.username, "alxx")
        XCTAssertEqual(account.secUid, "MS4wLjABAAAAxyz")
    }

    /// Certaines générations servent les champs à la racine, sans `data`.
    func testReadsTopLevelAccountInfo() throws {
        let json = #"{"username":"bob","secUid":"MS4wLjABAAAAabc"}"#
        let account = try XCTUnwrap(TikTokAPI.parseAccountInfo(Data(json.utf8)))
        XCTAssertEqual(account.username, "bob")
        XCTAssertEqual(account.secUid, "MS4wLjABAAAAabc")
    }

    /// Hors session, le site répond `user_id: "0"` et aucun pseudo : ce n'est
    /// pas un compte nommé « 0 », c'est l'absence de compte.
    func testSignedOutResponseYieldsNoAccount() {
        let json = #"{"message":"success","data":{"user_id":"0"}}"#
        XCTAssertNil(TikTokAPI.parseAccountInfo(Data(json.utf8)))
    }

    func testErrorEnvelopeYieldsNoAccount() {
        XCTAssertNil(TikTokAPI.parseAccountInfo(Data(#"{"message":"error","data":{}}"#.utf8)))
        XCTAssertNil(TikTokAPI.parseAccountInfo(Data("not json".utf8)))
    }

    /// Un nom d'affichage n'est pas un pseudo : il peut contenir des espaces
    /// et des accents, et ne serait pas utilisable dans `/@…`.
    func testInvalidUsernameIsRejected() {
        XCTAssertNil(TikTokAPI.parseAccountInfo(Data(#"{"data":{"username":"bad name!"}}"#.utf8)))
        XCTAssertNil(TikTokAPI.parseAccountInfo(Data(#"{"data":{"username":"trailing."}}"#.utf8)))
        XCTAssertNil(TikTokAPI.parseAccountInfo(Data(#"{"data":{"username":""}}"#.utf8)))
    }

    func testSecUidIsOptional() throws {
        let json = #"{"data":{"unique_id":"dave"}}"#
        let account = try XCTUnwrap(TikTokAPI.parseAccountInfo(Data(json.utf8)))
        XCTAssertEqual(account.username, "dave")
        XCTAssertEqual(account.secUid, "")
    }

    func testAccountInfoRouteIsThePassportOne() {
        let url = TikTokAPI.accountInfoURL()
        XCTAssertEqual(url.host, "www.tiktok.com")
        // `URL.path` retire le slash final : c'est l'adresse complète qui doit
        // le porter, la route TikTok étant servie sous sa forme barrée.
        XCTAssertEqual(url.absoluteString,
                       "https://www.tiktok.com/passport/web/account/info/?aid=1988")
    }
}

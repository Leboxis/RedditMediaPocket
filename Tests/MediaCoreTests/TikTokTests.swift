import XCTest
@testable import MediaCore

final class TikTokTests: XCTestCase {

    // MARK: - Pseudo

    func testUsernameValidation() throws {
        XCTAssertEqual(try TikTokAPI.username("nasa"), "nasa")
        XCTAssertEqual(try TikTokAPI.username(" tt/NASA "), "NASA")
        XCTAssertEqual(try TikTokAPI.username("@nasa"), "nasa")
        XCTAssertEqual(try TikTokAPI.username("tiktok.com/@nasa"), "nasa")
        XCTAssertEqual(try TikTokAPI.username("https://www.tiktok.com/@nasa?lang=fr"), "nasa")
        // Les points et underscores font partie des pseudos TikTok.
        XCTAssertNoThrow(try TikTokAPI.username("some.name_24"))
        XCTAssertThrowsError(try TikTokAPI.username(""))
        XCTAssertThrowsError(try TikTokAPI.username("nasa web"))
        // Un nom d'affichage collé n'est pas une adresse de profil.
        XCTAssertThrowsError(try TikTokAPI.username("Nasa Web"))
        // Un point final n'existe pas dans un pseudo TikTok.
        XCTAssertThrowsError(try TikTokAPI.username("nasa."))
        // Au-delà de 24 caractères, ce n'est plus un pseudo.
        XCTAssertThrowsError(try TikTokAPI.username(String(repeating: "a", count: 25)))
    }

    func testParseTikTokForms() throws {
        XCTAssertEqual(try FeedSource.parse("tt/nasa"), .tiktokUser("nasa"))
        XCTAssertEqual(try FeedSource.parse("https://www.tiktok.com/@nasa"), .tiktokUser("nasa"))
        // `@` reste X : le préfixe `tt/` est le seul à déclencher TikTok.
        XCTAssertEqual(try FeedSource.parse("@nasa"), .twitterUser("nasa"))
        // Une vidéo isolée est refusée avec un message dédié, pas une erreur
        // de pseudo.
        XCTAssertThrowsError(try FeedSource.parse("https://www.tiktok.com/@nasa/video/7301")) { error in
            XCTAssertTrue(error is TikTokError)
        }
        // `x/` reste X-Fetish.
        XCTAssertEqual(try FeedSource.parse("x/someone"), .xFetish(XFetishAlbums.Target(model: "someone", videos: [], albums: [])))
    }

    func testTikTokMapping() {
        let source = FeedSource.tiktokUser("nasa")
        XCTAssertEqual(source.id, "tt/nasa")
        XCTAssertEqual(source.folderName, "tk.nasa")
        XCTAssertEqual(source.displayName, "tt/nasa")
        XCTAssertEqual(source.feedURL(), TikTokAPI.profileURL(username: "nasa"))
    }

    /// `tk.nasa` ne doit jamais être confondu avec `tw.nasa` (X), `x.nasa`
    /// (X-Fetish) ni avec un profil Reddit nu.
    func testFolderNoCollision() {
        XCTAssertNotEqual(FeedSource.tiktokUser("nasa").folderName,
                          FeedSource.twitterUser("nasa").folderName)
        XCTAssertNotEqual(FeedSource.tiktokUser("nasa").folderName,
                          FeedSource.xFetish(XFetishAlbums.Target(model: "nasa", videos: [], albums: [])).folderName)
        XCTAssertNotEqual(FeedSource.tiktokUser("nasa").folderName,
                          FeedSource.user("nasa").folderName)
    }

    func testKDriveFolderNameForTikTok() {
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("tt/nasa"), "Nasa - TikTok")
        // Distinct de `tw/nasa` : les deux portent le même pseudo.
        XCTAssertNotEqual(FilenamePolicy.kDriveFolderName("tt/nasa"),
                          FilenamePolicy.kDriveFolderName("tw/nasa"))
    }

    func testSourceKindCycleReachesTikTok() {
        XCTAssertEqual(SourceKind.twitter.next, .tiktok)
        XCTAssertEqual(SourceKind.tiktok.next, .user)
        XCTAssertEqual(SourceKind.tiktok.rawValue, "tt")
    }

    // MARK: - URLs

    func testItemListURLs() {
        let first = TikTokAPI.itemListURL(secUid: "SEC1", cursor: nil, msToken: nil)
        XCTAssertTrue(first.absoluteString.hasPrefix("https://www.tiktok.com/api/post/item_list/?"))
        XCTAssertTrue(first.absoluteString.contains("secUid=SEC1"))
        XCTAssertFalse(first.absoluteString.contains("cursor"))

        let second = TikTokAPI.itemListURL(secUid: "SEC1", cursor: "20", msToken: "TOK")
        XCTAssertTrue(second.absoluteString.contains("cursor=20"))
        XCTAssertTrue(second.absoluteString.contains("msToken=TOK"))
    }

    func testHeadersCarryBrowserIdentity() {
        let headers = TikTokAPI.headers(referer: TikTokAPI.profileURL(username: "nasa"))
        XCTAssertEqual(headers["Referer"], "https://www.tiktok.com/@nasa")
        XCTAssertEqual(headers["User-Agent"], TikTokAPI.userAgent)
        let media = TikTokAPI.mediaHeaders()
        XCTAssertEqual(media["Referer"], "https://www.tiktok.com/")
        XCTAssertEqual(media["User-Agent"], TikTokAPI.userAgent)
    }

    // MARK: - Profil

    private func profileHTML(_ payload: String) -> Data {
        Data(("<!DOCTYPE html><html><head>"
              + "<script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\" type=\"application/json\">"
              + payload + "</script></head><body></body></html>").utf8)
    }

    func testParseProfileResolvesSecUid() throws {
        let payload = #"{"__DEFAULT_SCOPE__":{"webapp.user-detail":{"userInfo":{"user":{"secUid":"SEC1","uniqueId":"nasa"}},"itemList":[]}}}"#
        let profile = try TikTokWeb.parseProfile(profileHTML(payload))
        XCTAssertEqual(profile.secUid, "SEC1")
        XCTAssertTrue(profile.items.isEmpty)
    }

    /// Un compte inexistant ou privé arrive sans `userInfo` : l'erreur doit
    /// dire « compte introuvable », pas « fil illisible ».
    func testParseProfileRejectsUnknownAccount() {
        let payload = #"{"__DEFAULT_SCOPE__":{"webapp.user-detail":{"statusCode":10216}}}"#
        XCTAssertThrowsError(try TikTokWeb.parseProfile(profileHTML(payload))) { error in
            XCTAssertEqual(error as? TikTokError, .unknownAccount)
        }
    }

    func testParseProfileRejectsPageWithoutData() {
        XCTAssertThrowsError(try TikTokWeb.parseProfile(Data("<html></html>".utf8))) { error in
            XCTAssertEqual(error as? TikTokError, .invalidTimeline)
        }
    }

    // MARK: - Publications

    private let itemListJSON = #"""
    {"itemList":[
      {"id":"7301","desc":"Une vidéo","createTime":"1700000000",
       "video":{"playAddr":"https://v16-webapp-prime.tiktok.com/video/tos/a.mp4?mime_type=video_mp4"}},
      {"id":"7302","desc":"Un diaporama","createTime":"1700000100",
       "imagePost":{"images":[
         {"imageURL":{"urlList":["https://p16-sign-va.tiktokcdn.com/img1.jpeg"]}},
         {"imageURL":{"urlList":["https://p16-sign-va.tiktokcdn.com/img2.jpeg"]}}]}},
      {"id":"7303","desc":"Texte seul"}
    ],"hasMore":1,"cursor":"20"}
    """#

    func testParseItemListExtractsMedia() throws {
        let page = try TikTokWeb.parseItemList(Data(itemListJSON.utf8))
        XCTAssertEqual(page.posts.count, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "20")

        let video = page.posts[0]
        XCTAssertEqual(video.id, "7301")
        XCTAssertEqual(video.media.count, 1)
        XCTAssertEqual(video.media[0].kind, .video)
        XCTAssertEqual(video.media[0].storageKey, "tkv-7301")
        XCTAssertEqual(video.publishedAt, Date(timeIntervalSince1970: 1_700_000_000))

        let slideshow = page.posts[1]
        XCTAssertEqual(slideshow.media.map(\.storageKey), ["tkm-7302-1", "tkm-7302-2"])
        XCTAssertEqual(slideshow.media.map(\.kind), [.image, .image])
    }

    /// TikTok sérialise parfois `/` en `\u002F` : l'URL doit rester lisible.
    func testParseItemListUnescapesURLs() throws {
        let json = #"{"itemList":[{"id":"7301","desc":"","video":{"playAddr":"https:\/\/v16-webapp-prime.tiktok.com\/video\/a.mp4"}}],"hasMore":0}"#
        let page = try TikTokWeb.parseItemList(Data(json.utf8))
        XCTAssertEqual(page.posts.first?.media.first?.url.absoluteString,
                       "https://v16-webapp-prime.tiktok.com/video/a.mp4")
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    /// Une URL d'hôte tiers dans la réponse ne doit jamais devenir un média.
    func testParseItemListRejectsForeignHosts() throws {
        let json = #"{"itemList":[{"id":"7301","desc":"","video":{"playAddr":"https://evil.example/a.mp4"}}],"hasMore":0}"#
        let page = try TikTokWeb.parseItemList(Data(json.utf8))
        XCTAssertTrue(page.posts.isEmpty)
    }

    /// Une page de vérification (HTML, pas JSON) doit être signalée comme un
    /// fil illisible, pas faire planter le parcours.
    func testParseItemListRejectsHTML() {
        XCTAssertThrowsError(try TikTokWeb.parseItemList(Data("<html>captcha</html>".utf8))) { error in
            XCTAssertEqual(error as? TikTokError, .invalidTimeline)
        }
    }

    // MARK: - Noms de fichiers

    func testTikTokMediaIDRoundTrip() {
        XCTAssertEqual(FilenamePolicy.tikTokMediaID(inFileName: "Une vidéo - tkv-7301.mp4"), "tkv-7301")
        XCTAssertEqual(FilenamePolicy.tikTokMediaID(inFileName: "tkv-7301.mp4"), "tkv-7301")
        XCTAssertEqual(FilenamePolicy.tikTokMediaID(inFileName: "Un diaporama 2 - tkm-7302-2.jpg"), "tkm-7302-2")
        XCTAssertEqual(FilenamePolicy.tikTokMediaID(inFileName: "tkm-7302-1.jpeg"), "tkm-7302-1")
        // Un suffixe de collision `-2` derrière une clé vidéo n'est pas une clé.
        XCTAssertNil(FilenamePolicy.tikTokMediaID(inFileName: "Une vidéo - tkv-7301-2.mp4"))
        // Les clés X et X-Fetish ne sont pas des clés TikTok.
        XCTAssertNil(FilenamePolicy.tikTokMediaID(inFileName: "Titre - xm-123.jpg"))
        XCTAssertNil(FilenamePolicy.tikTokMediaID(inFileName: "Titre - xfv-12-3.mp4"))
        // Un fragment de titre ne doit pas être accepté comme clé.
        XCTAssertNil(FilenamePolicy.tikTokMediaID(inFileName: "tkv-abc.mp4"))
    }
}

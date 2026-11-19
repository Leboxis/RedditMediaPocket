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
        XCTAssertEqual(SourceKind.tiktok.next, .tiktokSaved)
        XCTAssertEqual(SourceKind.tiktokSaved.next, .instagram)
        XCTAssertEqual(SourceKind.tiktok.rawValue, "tt")
        XCTAssertEqual(SourceKind.tiktokSaved.rawValue, "ts")
    }

    // MARK: - URLs

    func testHeadersCarryBrowserIdentity() {
        let headers = TikTokAPI.headers(referer: TikTokAPI.profileURL(username: "nasa"))
        XCTAssertEqual(headers["Referer"], "https://www.tiktok.com/@nasa")
        XCTAssertEqual(headers["User-Agent"], TikTokAPI.userAgent)
        let media = TikTokAPI.mediaHeaders()
        XCTAssertEqual(media["Referer"], "https://www.tiktok.com/")
        XCTAssertEqual(media["User-Agent"], TikTokAPI.userAgent)
        // Les nœuds `*-webapp-prime` refusent (403) un transfert sans
        // requête média segmentée ni origine de la page.
        XCTAssertEqual(media["Range"], "bytes=0-")
        XCTAssertEqual(media["Origin"], "https://www.tiktok.com")
    }

    /// Chaque entrée de `urlList` est un miroir CDN du même contenu : la
    /// première devient l'URL primaire, les suivantes des secours — un 403
    /// du nœud `v16-` ne doit pas condamner le transfert si `v19-` passe.
    func testParseItemListCollectsAllCDNMirrors() throws {
        let json = #"""
        {"itemList":[{"id":"7301","desc":"","video":{"bitrateInfo":[
          {"Bitrate":2445819,"GearName":"adapt_lower_720_1",
           "PlayAddr":{"urlList":["https://v16-webapp-prime.tiktok.com/video/a.mp4?sig=1",
                                  "https://v19-webapp-prime.tiktok.com/video/a.mp4?sig=2",
                                  "https://www.tiktok.com/aweme/v1/play/?sig=3"]}}}]}],"hasMore":0}
        """#
        let page = try TikTokWeb.parseItemList(Data(json.utf8))
        let media = try XCTUnwrap(page.posts.first?.media.first)
        XCTAssertEqual(media.url.absoluteString,
                       "https://v16-webapp-prime.tiktok.com/video/a.mp4?sig=1")
        XCTAssertEqual(media.mirrors.map { $0.absoluteString },
                       ["https://v19-webapp-prime.tiktok.com/video/a.mp4?sig=2",
                        "https://www.tiktok.com/aweme/v1/play/?sig=3"])
    }

    /// Sans variante `bitrateInfo`, `playAddr` devient l'URL primaire et
    /// `downloadAddr` son miroir, jamais un second média.
    func testParseItemListUsesDownloadAddrAsMirror() throws {
        let json = #"""
        {"itemList":[{"id":"7301","desc":"","video":{
          "playAddr":"https://v16-webapp-prime.tiktok.com/video/a.mp4",
          "downloadAddr":"https://v19-webapp-prime.tiktok.com/video/a.mp4?watermark=1"}}],"hasMore":0}
        """#
        let page = try TikTokWeb.parseItemList(Data(json.utf8))
        let post = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(post.media.count, 1)
        let media = try XCTUnwrap(post.media.first)
        XCTAssertEqual(media.url.absoluteString,
                       "https://v16-webapp-prime.tiktok.com/video/a.mp4")
        XCTAssertEqual(media.mirrors.map { $0.absoluteString },
                       ["https://v19-webapp-prime.tiktok.com/video/a.mp4?watermark=1"])
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
        XCTAssertTrue(profile.posts.isEmpty)
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

    // MARK: - Sauvegardés TikTok (ts/)

    func testSavedSourceParsing() throws {
        XCTAssertEqual(try FeedSource.parse("ts/nasa"), .tiktokSaved("nasa"))
        XCTAssertEqual(FeedSource.tiktokSaved("nasa").id, "ts/nasa")
        XCTAssertEqual(FeedSource.tiktokSaved("nasa").folderName, "ts.nasa")
        XCTAssertEqual(TikTokAPI.savedURL().absoluteString, "https://www.tiktok.com/saved")
    }

    /// Le pseudo vient du chemin de page (`/@pseudo`), jamais d'un fil :
    /// un premier lien `@` d'accueil dsigne un crateur, pas le compte connect.
    func testUsernameFromProfilePath() {
        XCTAssertEqual(TikTokAPI.usernameFromProfilePath("/@nasa"), "nasa")
        XCTAssertEqual(TikTokAPI.usernameFromProfilePath("/@some.name_24"), "some.name_24")
        XCTAssertEqual(TikTokAPI.usernameFromProfilePath("/@nasa/video/7301"), "nasa")
        XCTAssertNil(TikTokAPI.usernameFromProfilePath("/foryou"))
        XCTAssertNil(TikTokAPI.usernameFromProfilePath("/upload"))
        XCTAssertNil(TikTokAPI.usernameFromProfilePath(""))
        // Un point final n'existe pas dans un pseudo TikTok.
        XCTAssertNil(TikTokAPI.usernameFromProfilePath("/@nasa."))
    }

    /// Forme 19 chiffres attendue par les routes pagines ; son absence
    /// produit un 200 corps vide silencieux (`tt_orcas_res: 1`).
    func testWebDeviceIDShape() {
        XCTAssertEqual(TikTokAPI.webDeviceID.count, 19)
        XCTAssertTrue(TikTokAPI.webDeviceID.allSatisfy { $0.isNumber })
    }

    func testDesktopItemListCarriesDeviceID() {
        let items = URLComponents(url: TikTokAPI.desktopItemListURL(secUid: "SEC1", cursor: 0),
                                  resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains { $0.name == "device_id" && $0.value == TikTokAPI.webDeviceID })
        XCTAssertTrue(items.contains { $0.name == "secUid" && $0.value == "SEC1" })
        XCTAssertTrue(items.contains { $0.name == "cursor" && $0.value == "0" })
        XCTAssertTrue(items.contains { $0.name == "count" && $0.value == "35" })
    }

    /// Les trois routes terminales des sauvegardes portent les paramtres du
    /// client web desktop relevs sur la page (aid 1988, device_id) et leurs
    /// cls propres (secUid, collectionId, sourceType 113 pour un dossier).
    func testSavedRoutesCarrySignedClientParams() throws {
        func query(_ url: URL) throws -> [String: String] {
            var out: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems! {
                out[item.name] = item.value
            }
            return out
        }
        let foldersURL = TikTokAPI.collectionListURL(secUid: "SEC1", cursor: "0")
        let allURL = TikTokAPI.collectItemListURL(secUid: "SEC1", cursor: "7300")
        let oneURL = TikTokAPI.collectionItemListURL(collectionId: "7659011279817935649", cursor: "")
        // `URL.path` retire le slash final : vérifier l'URL complète.
        XCTAssertTrue(foldersURL.absoluteString.contains("/api/user/collection_list/"))
        XCTAssertTrue(allURL.absoluteString.contains("/api/user/collect/item_list/"))
        XCTAssertTrue(oneURL.absoluteString.contains("/api/collection/item_list/"))
        for url in [foldersURL, allURL, oneURL] {
            let items = try query(url)
            XCTAssertEqual(items["device_id"], TikTokAPI.webDeviceID)
            XCTAssertEqual(items["aid"], "1988")
            XCTAssertEqual(items["app_name"], "tiktok_web")
            XCTAssertEqual(items["device_platform"], "web_pc")
            XCTAssertEqual(items["browser_version"], "5.0 (Windows)")
        }
        let folders = try query(foldersURL)
        XCTAssertEqual(folders["secUid"], "SEC1")
        XCTAssertEqual(folders["cursor"], "0")
        XCTAssertEqual(folders["count"], "35")
        XCTAssertEqual(folders["coverFormat"], "2")
        XCTAssertEqual(folders["needPinnedItemIds"], "true")
        XCTAssertEqual(folders["publicOnly"], "false")
        let all = try query(allURL)
        XCTAssertEqual(all["secUid"], "SEC1")
        XCTAssertEqual(all["cursor"], "7300")
        XCTAssertEqual(all["post_item_list_request_type"], "0")
        let one = try query(oneURL)
        XCTAssertEqual(one["collectionId"], "7659011279817935649")
        XCTAssertEqual(one["sourceType"], "113")
        XCTAssertEqual(one["count"], "35")
    }

    /// Le JSON d'hydratation de la page profil (lu dans la WebView) sert
    /// rsoudre le `secUid` du compte connect.
    func testParseProfileDataReadsHydrationJSON() throws {
        let payload = #"{"__DEFAULT_SCOPE__":{"webapp.user-detail":{"userInfo":{"user":{"secUid":"SEC2","uniqueId":"nasa"}},"itemList":[]}}}"#
        let profile = try TikTokWeb.parseProfileData(payload)
        XCTAssertEqual(profile.secUid, "SEC2")
        XCTAssertTrue(profile.posts.isEmpty)
    }

    func testParseProfileDataRejectsEmptyPayload() {
        XCTAssertThrowsError(try TikTokWeb.parseProfileData("{}")) { error in
            XCTAssertEqual(error as? TikTokError, .invalidTimeline)
        }
    }

    func testParseCollectionListPageReturnsCursorAndEnd() throws {
        let json = #"{"collectionList":[{"collectionId":"11","name":"A","total":"1"}],"hasMore":true,"cursor":"35"}"#
        let page = try TikTokWeb.parseCollectionListPage(Data(json.utf8))
        XCTAssertEqual(page.folders.count, 1)
        XCTAssertEqual(page.nextCursor, "35")
        XCTAssertTrue(page.hasMore)
        let end = try TikTokWeb.parseCollectionListPage(Data(#"{"collectionList":[],"hasMore":false,"cursor":0}"#.utf8))
        XCTAssertTrue(end.folders.isEmpty)
        XCTAssertNil(end.nextCursor)
        XCTAssertFalse(end.hasMore)
    }

    /// Le front déplace les clés de `collection_list` à chaque génération :
    /// nœuds à `id` seule, dossiers enveloppés dans un objet `collection`,
    /// enveloppe renommée (recherche structurelle), voire tableau nu — et
    /// jamais une liste de publications prise pour des dossiers.
    func testParseCollectionListReadsAlternativeShapes() throws {
        let idOnly = #"{"collectionList":[{"id":"7685","name":"Voyages","itemCount":12}],"hasMore":false,"cursor":"35"}"#
        let pageA = try TikTokWeb.parseCollectionListPage(Data(idOnly.utf8))
        XCTAssertEqual(pageA.folders.map { $0.id }, ["7685"])
        XCTAssertEqual(pageA.folders[0].name, "Voyages")
        XCTAssertEqual(pageA.folders[0].itemCount, 12)

        let wrapped = #"[{"collection":{"id":"42","name":"Cuisine","total":"3"}}]"#
        let pageB = try TikTokWeb.parseCollectionListPage(Data(wrapped.utf8))
        XCTAssertEqual(pageB.folders.map { $0.id }, ["42"])
        XCTAssertEqual(pageB.folders[0].itemCount, 3)
        XCTAssertFalse(pageB.hasMore)

        let mined = #"{"data":{"extra":1,"list":[{"id":"99","title":"Privé","total":2}]}}"#
        let pageC = try TikTokWeb.parseCollectionListPage(Data(mined.utf8))
        XCTAssertEqual(pageC.folders.map { $0.id }, ["99"])
        XCTAssertEqual(pageC.folders[0].name, "Privé")

        let posts = #"{"itemList":[{"id":"7301","desc":"Une vidéo","video":{"playAddr":"https://v/x.mp4"}}]}"#
        let pageD = try TikTokWeb.parseCollectionListPage(Data(posts.utf8))
        XCTAssertTrue(pageD.folders.isEmpty)
    }

    func testParseCollectionListReadsFolders() throws {
        let json = """
        {"collectionList":[{"collectionId":"7659011279817935649","name":"Wanna go to","total":"49","status":1},
                           {"collectionId":"7659011279817935650","name":"Recipes","total":3}],
         "hasMore":false,"cursor":0}
        """
        let folders = try TikTokWeb.parseCollectionList(Data(json.utf8))
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(folders[0].id, "7659011279817935649")
        XCTAssertEqual(folders[0].name, "Wanna go to")
        XCTAssertEqual(folders[0].itemCount, 49)
        XCTAssertEqual(folders[1].name, "Recipes")
        XCTAssertEqual(folders[1].itemCount, 3)
    }
}

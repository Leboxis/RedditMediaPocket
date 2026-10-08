import XCTest
@testable import MediaCore

final class XTwitterTests: XCTestCase {

    // MARK: - Pseudo

    func testUsernameValidation() throws {
        XCTAssertEqual(try XTwitterAPI.username("nasa"), "nasa")
        XCTAssertEqual(try XTwitterAPI.username(" tw/NASA "), "NASA")
        XCTAssertEqual(try XTwitterAPI.username("@nasa"), "nasa")
        XCTAssertEqual(try XTwitterAPI.username("x.com/nasa"), "nasa")
        XCTAssertEqual(try XTwitterAPI.username("https://x.com/nasa/status/123"), "nasa")
        XCTAssertEqual(try XTwitterAPI.username("twitter.com/nasa/media"), "nasa")
        XCTAssertEqual(try XTwitterAPI.username("https://www.twitter.com/nasa/media"), "nasa")
        // 15 caractères au plus : au-delà, ce n'est plus un pseudo mais une adresse.
        XCTAssertNoThrow(try XTwitterAPI.username("123456789012345"))
        XCTAssertThrowsError(try XTwitterAPI.username("1234567890123456"))
        XCTAssertThrowsError(try XTwitterAPI.username(""))
        XCTAssertThrowsError(try XTwitterAPI.username("nasa web"))
        // Un caractère cyrillique visuellement identique à un « a » latin : un pseudo
        // qui le contient est refusé, sinon l'utilisateur chercherait un compte
        // qui n'existe pas.
        XCTAssertThrowsError(try XTwitterAPI.username("na\u{0441}a"))
    }

    func testParseTwitterForms() throws {
        XCTAssertEqual(try FeedSource.parse("tw/nasa"), .twitterUser("nasa"))
        XCTAssertEqual(try FeedSource.parse("@nasa"), .twitterUser("nasa"))
        XCTAssertEqual(try FeedSource.parse("https://x.com/nasa"), .twitterUser("nasa"))
        // `x/` reste X-Fetish : le préfixe `tw/` est le seul à déclencher X.
        XCTAssertEqual(try FeedSource.parse("x/someone"), .xFetish("someone"))
    }

    func testTwitterMapping() {
        let source = FeedSource.twitterUser("nasa")
        XCTAssertEqual(source.id, "tw/nasa")
        XCTAssertEqual(source.folderName, "tw.nasa")
        XCTAssertEqual(source.displayName, "tw/nasa")
    }

    /// `tw.nasa` ne doit jamais être confondu avec `x.nasa` (X-Fetish) ni avec
    /// un profil Reddit nu.
    func testFolderNoCollision() {
        XCTAssertNotEqual(FeedSource.twitterUser("nasa").folderName,
                          FeedSource.xFetish("nasa").folderName)
        XCTAssertNotEqual(FeedSource.twitterUser("nasa").folderName,
                          FeedSource.user("nasa").folderName)
    }

    func testKDriveFolderNameForTwitter() {
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("tw/nasa"), "Twnasa")
        // Distinct de `u/nasa` : les deux portent le même pseudo.
        XCTAssertNotEqual(FilenamePolicy.kDriveFolderName("tw/nasa"),
                          FilenamePolicy.kDriveFolderName("u/nasa"))
    }

    func testSourceKindCycleReachesTwitter() {
        XCTAssertEqual(SourceKind.xFetish.next, .twitter)
        XCTAssertEqual(SourceKind.twitter.next, .user)
        XCTAssertEqual(SourceKind.twitter.rawValue, "tw")
    }

    // MARK: - URLs

    func testGraphQLURLs() {
        let user = XTwitterAPI.userByScreenName(username: "nasa")
        XCTAssertTrue(user.absoluteString.hasPrefix("https://x.com/i/api/graphql/"))
        XCTAssertTrue(user.absoluteString.contains("/UserByScreenName?"))
        XCTAssertTrue(user.absoluteString.contains("screen_name"))

        let first = XTwitterAPI.userMedia(userID: "123", cursor: nil)
        XCTAssertTrue(first.absoluteString.contains("/UserMedia?"))
        XCTAssertFalse(first.absoluteString.contains("cursor"))

        let second = XTwitterAPI.userMedia(userID: "123", cursor: "DAABC")
        XCTAssertTrue(second.absoluteString.contains("cursor"))
    }

    /// Le curseur est imbriqué dans le JSON des `variables`, pas dans un
    /// paramètre de l'URL : il n'a donc pas de `queryItems` à lui. Ce qui
    /// compte est que le JSON produit reste valide et que le curseur y figure
    /// intact, échappé ou non : c'est x.com qui le décode, pas l'app.
    func testCursorIsEmbeddedInValidVariablesJSON() throws {
        let url = XTwitterAPI.userMedia(userID: "1", cursor: "a+b/c=")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let raw = try XCTUnwrap(items.first { $0.name == "variables" }?.value)
        // Rétablit le JSON après le décodage des percent-encodages de l'URL.
        let variables = try XCTUnwrap(raw.removingPercentEncoding ?? raw)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(variables.utf8))
            as? [String: Any])
        XCTAssertEqual(decoded["userId"] as? String, "1")
        XCTAssertEqual(decoded["count"] as? Int, 40)
        XCTAssertEqual(decoded["cursor"] as? String, "a+b/c=")
        // L'absence de curseur ne doit pas laisser de champ vide derrière.
        let first = try XCTUnwrap(URLComponents(url: XTwitterAPI.userMedia(userID: "1", cursor: nil),
                                                resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "variables" }?.value)
        let without = try XCTUnwrap(first.removingPercentEncoding ?? first)
        let empty = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(without.utf8)) as? [String: Any])
        XCTAssertNil(empty["cursor"])
    }

    // MARK: - Cookies

    func testCookiePolicyRejectsMediaCDN() {
        // Le CDN est public : la session ne doit jamais y aller.
        XCTAssertFalse(XTwitterCookiePolicy.allows(URL(string: "https://pbs.twimg.com/media/a.jpg")!))
        XCTAssertFalse(XTwitterCookiePolicy.allows(URL(string: "https://video.twimg.com/x.mp4")!))
        XCTAssertTrue(XTwitterCookiePolicy.allows(URL(string: "https://x.com/i/api/graphql/1/UserMedia")!))
        XCTAssertTrue(XTwitterCookiePolicy.allows(URL(string: "https://api.x.com/2/users/1")!))
        XCTAssertFalse(XTwitterCookiePolicy.allows(URL(string: "http://x.com/")!))
    }

    private func cookie(_ name: String, _ value: String, domain: String = ".x.com", path: String = "/") -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [:]
        properties[.name] = name
        properties[.value] = value
        properties[.domain] = domain
        properties[.path] = path
        return HTTPCookie(properties: properties)!
    }

    func testHeaderIncludesSessionCookies() throws {
        let cookies = [cookie("auth_token", "secret"), cookie("ct0", "csrf-value")]
        let header = XTwitterCookiePolicy.header(cookies: cookies,
                                                for: URL(string: "https://x.com/i/api/graphql/1/UserMedia")!)
        XCTAssertNotNil(header)
        XCTAssertTrue(header!.contains("auth_token=secret"))
        XCTAssertTrue(header!.contains("ct0=csrf-value"))
        XCTAssertEqual(XTwitterCookiePolicy.csrfToken(cookies: cookies), "csrf-value")
    }

    func testExpiredCookieIsDropped() throws {
        var properties: [HTTPCookiePropertyKey: Any] = [:]
        properties[.name] = "auth_token"
        properties[.value] = "secret"
        properties[.domain] = ".x.com"
        properties[.path] = "/"
        properties[.expires] = Date().addingTimeInterval(-60)
        let expired = HTTPCookie(properties: properties)!
        XCTAssertNil(XTwitterCookiePolicy.header(cookies: [expired],
                                                 for: URL(string: "https://x.com/i/api/graphql/1/UserMedia")!))
    }

    func testForeignCookieNotForwarded() throws {
        let foreign = cookie("auth_token", "reddit-value", domain: ".reddit.com")
        XCTAssertNil(XTwitterCookiePolicy.header(cookies: [foreign],
                                                 for: URL(string: "https://x.com/i/api/graphql/1/UserMedia")!))
    }

    // MARK: - Résolution du compte

    func testParseUserID() throws {
        let json = """
        {"data":{"user":{"result":{"__typename":"User","legacy":{"id_str":"37258327594","screen_name":"nasa"}}}}}
        """
        XCTAssertEqual(try XTwitterMedia.parseUser(Data(json.utf8)), "37258327594")
    }

    /// Un compte absent ou protégé est signalé comme tel, pas comme un média
    /// absent : le message invite à vérifier le pseudo.
    func testParseUnknownAccountThrows() {
        let json = #"{"data":{"user":{"result":{"__typename":"UserUnavailable"}}}}"#
        XCTAssertThrowsError(try XTwitterMedia.parseUser(Data(json.utf8))) { error in
            guard case XTwitterError.unknownAccount = error else {
                return XCTFail("attendu unknownAccount, reçu \(error)")
            }
        }
    }

    // MARK: - Choix de la qualité

    /// Une image doit être demandée en `name=orig` : c'est l'original
    /// téléversé, pas une vignette.
    func testPhotoUsesOriginal() {
        let entry: [String: Any] = [
            "media_key": "3_1234567890123456789",
            "type": "photo",
            "url": "https://pbs.twimg.com/media/ABCdef.jpg",
            "original_width": 2048,
            "original_height": 1152
        ]
        let media = XTwitterMedia.bestVariant(entry)
        XCTAssertEqual(media?.kind, .image)
        XCTAssertEqual(media?.url.absoluteString, "https://pbs.twimg.com/media/ABCdef.jpg?name=orig")
        XCTAssertEqual(media?.width, 2048)
        XCTAssertEqual(media?.height, 1152)
        // `3_…` : l'identifiant nu, sans le préfixe de type.
        XCTAssertEqual(media?.id, "1234567890123456789")
    }

    /// Une vignette déjà présente dans l'URL est remplacée : demander
    /// `name=large` ne donnerait pas la meilleure qualité.
    func testPhotoReplacesExistingSize() {
        let entry: [String: Any] = [
            "id_str": "999",
            "type": "photo",
            "url": "https://pbs.twimg.com/media/ABCdef.jpg?format=jpg&name=large"
        ]
        let media = XTwitterMedia.bestVariant(entry)
        XCTAssertEqual(media?.url.absoluteString, "https://pbs.twimg.com/media/ABCdef.jpg?name=orig")
    }

    func testVideoPicksHighestBitrate() throws {
        let json = """
        {"media_key":"3_111","type":"video","original_width":1280,"original_height":720,
         "video_info":{"variants":[
           {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/x.m3u8"},
           {"content_type":"video/mp4","bitrate":256000,"url":"https://video.twimg.com/x-256.mp4"},
           {"content_type":"video/mp4","bitrate":2176000,"url":"https://video.twimg.com/x-2176.mp4"},
           {"content_type":"video/mp4","bitrate":832000,"url":"https://video.twimg.com/x-832.mp4"}]}}
        """
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let media = XTwitterMedia.bestVariant(entry)
        XCTAssertEqual(media?.kind, .video)
        XCTAssertEqual(media?.url.absoluteString, "https://video.twimg.com/x-2176.mp4")
        XCTAssertEqual(media?.bitrate, 2176000)
    }

    /// Un GIF animé X est un MP4 : l'extension doit suivre le conteneur réel.
    func testAnimatedGifIsMP4() throws {
        let json = """
        {"media_key":"3_222","type":"animated_gif","original_width":480,"original_height":270,
         "video_info":{"variants":[
           {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/g.m3u8"},
           {"content_type":"video/mp4","bitrate":632000,"url":"https://video.twimg.com/g-632.mp4"}]}}
        """
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let media = XTwitterMedia.bestVariant(entry)
        XCTAssertEqual(media?.kind, .gif)
        XCTAssertEqual(media?.kind.fileExtension, "mp4")
    }

    /// Un flux HLS seul n'est pas téléchargeable : le média est ignoré plutôt
    /// que présenté comme un échec de téléchargement.
    func testHLSONlyIsSkipped() throws {
        let json = """
        {"media_key":"3_333","type":"video",
         "video_info":{"variants":[{"content_type":"application/x-mpegURL","url":"https://video.twimg.com/only.m3u8"}]}}
        """
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(XTwitterMedia.bestVariant(entry))
    }

    /// Un compte étranger ne doit pas pouvoir faire télécharger son contenu.
    func testForeignHostRejected() throws {
        let json = """
        {"media_key":"3_444","type":"photo","url":"https://evil.example.com/a.jpg"}
        """
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(XTwitterMedia.bestVariant(entry))
    }

    // MARK: - Fil média

    func testParseMediaPage() throws {
        let json = """
        {"data":{"user":{"result":{"timeline_v2":{"timeline":{"instructions":[
          {"type":"TimelineAddEntries","entries":[
            {"entryId":"tweet-1","content":{"itemContent":{"tweet_results":{"result":{
              "rest_id":"100","legacy":{
                "id_str":"100","full_text":"Photo","created_at":"Wed Oct 10 20:19:24 +0000 2018",
                "extended_entities":{"media":[
                  {"media_key":"3_1","type":"photo","url":"https://pbs.twimg.com/media/AAA.jpg","original_width":1,"original_height":2}]}}}}}}},
            {"entryId":"tweet-2","content":{"itemContent":{"tweet_results":{"result":{
              "rest_id":"200","legacy":{
                "id_str":"200","full_text":"Video","created_at":"Thu Oct 11 20:19:24 +0000 2018",
                "extended_entities":{"media":[
                  {"media_key":"3_2","type":"video","video_info":{"variants":[
                    {"content_type":"video/mp4","bitrate":1000,"url":"https://video.twimg.com/v.mp4"}]}}]}}}}}}},
            {"entryId":"tweet-3","content":{"itemContent":{"tweet_results":{"result":{
              "rest_id":"300","legacy":{"id_str":"300","full_text":"Texte seul"}}}}}},
            {"entryId":"cursor-bottom-1","content":{"value":"CURSOR_NEXT"}}
          ]}]}}}}}}
        """
        let page = try XTwitterMedia.parseMediaPage(Data(json.utf8))
        // Le post texte seul est écarté ; le curseur est conservé.
        XCTAssertEqual(page.posts.count, 2)
        XCTAssertEqual(page.posts.map(\.id), ["100", "200"])
        XCTAssertEqual(page.posts[0].media.first?.kind, .image)
        XCTAssertEqual(page.posts[1].media.first?.kind, .video)
        XCTAssertEqual(page.nextCursor, "CURSOR_NEXT")
        let date = try XCTUnwrap(page.posts[0].publishedAt)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: date), 2018)
    }

    /// Deux médias dans un même post doivent rester deux médias distincts.
    func testMultipleMediaPerPost() throws {
        let json = """
        {"data":{"user":{"result":{"timeline_v2":{"timeline":{"instructions":[
          {"entries":[{"entryId":"tweet-1","content":{"itemContent":{"tweet_results":{"result":{
            "legacy":{"id_str":"100","full_text":"Album",
              "extended_entities":{"media":[
                {"media_key":"3_1","type":"photo","url":"https://pbs.twimg.com/media/A.jpg"},
                {"media_key":"3_2","type":"photo","url":"https://pbs.twimg.com/media/B.jpg"},
                {"media_key":"3_2","type":"photo","url":"https://pbs.twimg.com/media/B.jpg"}]}}}}}}}]}]}}}}}}
        """
        let page = try XTwitterMedia.parseMediaPage(Data(json.utf8))
        XCTAssertEqual(page.posts.count, 1)
        // Le doublon `3_2` est écarté.
        XCTAssertEqual(page.posts[0].media.count, 2)
    }

    /// Une réponse sans `instructions` signifie un `queryId` périmé : le dire
    /// explicitement vaut mieux que « aucun média ».
    func testMissingInstructionsThrows() {
        let json = #"{"errors":[{"message":"Could not find operation"}]}"#
        XCTAssertThrowsError(try XTwitterMedia.parseMediaPage(Data(json.utf8))) { error in
            guard case XTwitterError.invalidTimeline = error else {
                return XCTFail("attendu invalidTimeline, reçu \(error)")
            }
        }
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try XTwitterMedia.parseMediaPage(Data("pas du json".utf8)))
        XCTAssertThrowsError(try XTwitterMedia.parseUser(Data("[]".utf8)))
    }

    // MARK: - RatePolicy

    /// L'API et son CDN partagent une limite : changer de sous-domaine ne doit
    /// pas permettre de la contourner.
    func testRatePolicyGroupsXHosts() {
        XCTAssertEqual(RatePolicy.service(for: "x.com"), "X")
        XCTAssertEqual(RatePolicy.service(for: "api.x.com"), "X")
        XCTAssertEqual(RatePolicy.service(for: "pbs.twimg.com"), "X")
        XCTAssertEqual(RatePolicy.service(for: "video.twimg.com"), "X")
        XCTAssertEqual(RatePolicy.service(for: "twitter.com"), "X")
    }

    // MARK: - Clés de fichiers

    func testXMediaIDFromFileName() {
        XCTAssertEqual(FilenamePolicy.xMediaID(inFileName: "Photo - xm-1234567890123456789.jpg"),
                       "xm-1234567890123456789")
        XCTAssertEqual(FilenamePolicy.xMediaID(inFileName: "Clip 1 - xmv-987654321.mp4"),
                       "xmv-987654321")
        // Un nom sans clé n'appartient pas à cette source.
        XCTAssertNil(FilenamePolicy.xMediaID(inFileName: "image - 12345.jpg"))
        XCTAssertNil(FilenamePolicy.xMediaID(inFileName: "sans extension"))
        // Un post X sans texte ne laisse que la clé dans le nom : ce nom doit rester
        // relisible, sinon le média serait retéléchargé à chaque exécution.
        XCTAssertEqual(FilenamePolicy.xMediaID(inFileName: "xm-12345.jpg"), "xm-12345")
        XCTAssertEqual(FilenamePolicy.xMediaID(inFileName: "xmv-12345.mp4"), "xmv-12345")
        // Un suffixe de collision de nom n'est pas une clé : il ne doit pas
        // faire passer un doublon `-2` pour le média d'origine.
        XCTAssertNil(FilenamePolicy.xMediaID(inFileName: "Photo - xm-12345-2.jpg"))
        XCTAssertNil(FilenamePolicy.xMediaID(inFileName: "Clip - xmv-98765-3.mp4"))
        XCTAssertNil(FilenamePolicy.xMediaID(inFileName: "xm-12345-2.jpg"))
    }

    /// `xm-` ne doit pas être confondu avec `xmv-` : une vidéo ne peut pas être
    /// sautée parce que son nom ressemble à celui d'une image.
    func testXMediaIDDistinguishesVideoFromImage() {
        let video = try? XCTUnwrap(FilenamePolicy.xMediaID(inFileName: "V - xmv-111.mp4"))
        XCTAssertEqual(video, "xmv-111")
        let image = try? XCTUnwrap(FilenamePolicy.xMediaID(inFileName: "I - xm-111.jpg"))
        XCTAssertEqual(image, "xm-111")
    }
}

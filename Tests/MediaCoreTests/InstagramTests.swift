import XCTest
@testable import MediaCore

final class InstagramTests: XCTestCase {

    // MARK: - Pseudo

    func testUsernameValidation() throws {
        XCTAssertEqual(try InstagramAPI.username("nasa"), "nasa")
        XCTAssertEqual(try InstagramAPI.username(" ig/NASA "), "NASA")
        XCTAssertEqual(try InstagramAPI.username("@nasa"), "nasa")
        XCTAssertEqual(try InstagramAPI.username("instagram.com/nasa"), "nasa")
        XCTAssertEqual(try InstagramAPI.username("https://www.instagram.com/nasa/?hl=fr"), "nasa")
        XCTAssertNoThrow(try InstagramAPI.username("some.name_24"))
        XCTAssertThrowsError(try InstagramAPI.username(""))
        XCTAssertThrowsError(try InstagramAPI.username("nasa web"))
        // Un point final n'existe pas dans un pseudo Instagram.
        XCTAssertThrowsError(try InstagramAPI.username("nasa."))
        // Au-delà de 30 caractères, ce n'est plus un pseudo.
        XCTAssertThrowsError(try InstagramAPI.username(String(repeating: "a", count: 31)))
    }

    func testParseInstagramForms() throws {
        XCTAssertEqual(try FeedSource.parse("ig/nasa"), .instagramUser("nasa"))
        XCTAssertEqual(try FeedSource.parse("https://www.instagram.com/nasa/"), .instagramUser("nasa"))
        // `@` reste X : le préfixe `ig/` et une adresse instagram.com sont les
        // seules formes à déclencher Instagram.
        XCTAssertEqual(try FeedSource.parse("@nasa"), .twitterUser("nasa"))
        // Une publication isolée est refusée avec un message dédié, pas une
        // erreur de pseudo.
        XCTAssertThrowsError(try FeedSource.parse("https://www.instagram.com/p/Cabcdefg/")) { error in
            XCTAssertTrue(error is InstagramError)
        }
        XCTAssertThrowsError(try FeedSource.parse("https://www.instagram.com/reel/Cabcdefg/")) { error in
            XCTAssertTrue(error is InstagramError)
        }
        // `x/` reste X-Fetish, `tt/` reste TikTok.
        XCTAssertEqual(try FeedSource.parse("x/someone"), .xFetish(XFetishAlbums.Target(model: "someone", videos: [], albums: [])))
        XCTAssertEqual(try FeedSource.parse("tt/nasa"), .tiktokUser("nasa"))
    }

    func testInstagramMapping() {
        let source = FeedSource.instagramUser("nasa")
        XCTAssertEqual(source.id, "ig/nasa")
        XCTAssertEqual(source.folderName, "ig.nasa")
        XCTAssertEqual(source.displayName, "ig/nasa")
        XCTAssertEqual(source.feedURL(), InstagramAPI.profilePageURL(username: "nasa"))
        XCTAssertEqual(InstagramAPI.profilePageURL(username: "nasa").absoluteString, "https://www.instagram.com/nasa/")
    }

    /// `ig.nasa` ne doit jamais être confondu avec `tk.nasa` (TikTok),
    /// `tw.nasa` (X), `x.nasa` (X-Fetish) ni avec un profil Reddit nu.
    func testFolderNoCollision() {
        XCTAssertNotEqual(FeedSource.instagramUser("nasa").folderName,
                          FeedSource.tiktokUser("nasa").folderName)
        XCTAssertNotEqual(FeedSource.instagramUser("nasa").folderName,
                          FeedSource.twitterUser("nasa").folderName)
        XCTAssertNotEqual(FeedSource.instagramUser("nasa").folderName,
                          FeedSource.xFetish(XFetishAlbums.Target(model: "nasa", videos: [], albums: [])).folderName)
        XCTAssertNotEqual(FeedSource.instagramUser("nasa").folderName,
                          FeedSource.user("nasa").folderName)
    }

    func testKDriveFolderNameForInstagram() {
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("ig/nasa"), "Nasa - Instagram")
    }

    // MARK: - Jetons et corps de requête

    /// La page de profil livre les deux jetons exigés par `api/graphql`.
    func testTokensFromProfilePage() throws {
        let html = """
        <html><script>["LSD",[],{"token":"LsdToken123"}]</script>
        <script>["InstagramSecurityConfig",[],{"csrf_token":"Csrf456"}]</script></html>
        """
        let tokens = try XCTUnwrap(InstagramAPI.tokens(inHTML: Data(html.utf8)))
        XCTAssertEqual(tokens.lsd, "LsdToken123")
        XCTAssertEqual(tokens.csrf, "Csrf456")
        // Page réelle sans `csrf_token` : les jetons restent utilisables.
        let withoutCSRF = try XCTUnwrap(InstagramAPI.tokens(inHTML: Data(#"["LSD",[],{"token":"LsdToken123"}]"#.utf8)))
        XCTAssertEqual(withoutCSRF.lsd, "LsdToken123")
        XCTAssertEqual(withoutCSRF.csrf, "")
        // Page sans jeton (interface modifiée) : pas de faux jetons inventés.
        XCTAssertNil(InstagramAPI.tokens(inHTML: Data("<html></html>".utf8)))
    }

    func testPostsRequestBody() throws {
        let tokens = InstagramAPI.Tokens(lsd: "LsdToken123", csrf: "Csrf456")
        let body = InstagramAPI.postsRequestBody(tokens: tokens, username: "nasa", cursor: "CURSOR1")
        let form = String(decoding: body, as: UTF8.self)
        let fields = Dictionary(uniqueKeysWithValues: form.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), (String(parts[1]).removingPercentEncoding ?? ""))
        })
        XCTAssertEqual(fields["lsd"], "LsdToken123")
        XCTAssertEqual(fields["doc_id"], InstagramAPI.postsQueryID)
        XCTAssertEqual(fields["server_timestamps"], "true")
        let variables = try XCTUnwrap(fields["variables"])
        XCTAssertTrue(variables.contains("\"username\":\"nasa\""))
        XCTAssertTrue(variables.contains("\"after\":\"CURSOR1\""))
        XCTAssertTrue(variables.contains("\"first\":12"))
        XCTAssertTrue(variables.contains("__relay_internal__pv__PolarisSEOIsCrawlerrelayprovider"))
        // Première page : `after` est nul, pas une chaîne vide.
        let first = InstagramAPI.postsRequestBody(tokens: tokens, username: "nasa", cursor: nil)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("\"after\":null"))
    }

    /// Les en-têtes portent l'identifiant d'application et les jetons : sans
    /// eux, Instagram ne répond pas.
    func testGraphqlHeaders() {
        let tokens = InstagramAPI.Tokens(lsd: "LsdToken123", csrf: "Csrf456")
        let headers = InstagramAPI.graphqlHeaders(tokens: tokens, referer: InstagramAPI.profilePageURL(username: "nasa"))
        XCTAssertEqual(headers["X-IG-App-ID"], InstagramAPI.appID)
        XCTAssertEqual(headers["X-FB-LSD"], "LsdToken123")
        XCTAssertEqual(headers["X-CSRF-Token"], "Csrf456")
        XCTAssertEqual(headers["Cookie"], "csrftoken=Csrf456")
        XCTAssertEqual(headers["Referer"], "https://www.instagram.com/nasa/")
        XCTAssertEqual(headers["Sec-Fetch-Mode"], "cors")
        // Sans `csrf_token` dans la page, aucun en-tête de jeton vide n'est
        // envoyé : Instagram répond à la requête anonyme sans lui.
        let anonymous = InstagramAPI.graphqlHeaders(tokens: InstagramAPI.Tokens(lsd: "Lsd", csrf: ""),
                                                    referer: InstagramAPI.profilePageURL(username: "nasa"))
        XCTAssertNil(anonymous["X-CSRF-Token"])
        XCTAssertNil(anonymous["Cookie"])
        XCTAssertEqual(anonymous["X-FB-LSD"], "Lsd")
    }

    // MARK: - Clés de médias

    func testMediaKey() {
        XCTAssertEqual(InstagramWeb.mediaKey("2743123456789012345", video: false), "igm-2743123456789012345")
        XCTAssertEqual(InstagramWeb.mediaKey("2743123456789012345", video: true), "igv-2743123456789012345")
        // Un identifiant inattendu retombe sur une empreinte stable : jamais
        // le hachage Swift, aléatoire à chaque exécution.
        XCTAssertEqual(InstagramWeb.mediaKey("abc", video: false), InstagramWeb.mediaKey("abc", video: false))
        XCTAssertNotEqual(InstagramWeb.mediaKey("abc", video: false), InstagramWeb.mediaKey("abd", video: false))
        // Les chiffres isolés d'un identifiant sale ne deviennent pas une clé
        // ambiguë : l'identifiant entier est filtré.
        XCTAssertEqual(InstagramWeb.mediaKey("12x34", video: false), "igm-1234")
    }

    func testMediaIDInFileName() {
        XCTAssertEqual(FilenamePolicy.instagramMediaID(inFileName: "titre - igm-2743123456789012345.jpg"), "igm-2743123456789012345")
        XCTAssertEqual(FilenamePolicy.instagramMediaID(inFileName: "titre - igv-2743123456789012345.mp4"), "igv-2743123456789012345")
        XCTAssertEqual(FilenamePolicy.instagramMediaID(inFileName: "igm-2743123456789012345.jpg"), "igm-2743123456789012345")
        // Un suffixe de collision n'est pas une clé.
        XCTAssertNil(FilenamePolicy.instagramMediaID(inFileName: "titre - igm-2743123456789012345-2.jpg"))
        // Une clé TikTok ou X-Fetish n'est pas une clé Instagram.
        XCTAssertNil(FilenamePolicy.instagramMediaID(inFileName: "titre - tkm-7301234567890123456-1.jpg"))
        XCTAssertNil(FilenamePolicy.instagramMediaID(inFileName: "titre.txt"))
    }

    // MARK: - Analyse des réponses

    /// Réponse `api/graphql` du site : `edges[].node` et `page_info`.
    func testParseTimeline() throws {
        let json = """
        {"data":{"xdt_api__v1__feed__user_timeline_graphql_connection":{
            "edges":[
                {"cursor":"C1","node":{"pk":"2743000000000000001","code":"CaAAAAA","taken_at":1710000000,
                     "media_type":1,
                     "caption":{"text":"Une légende"},
                     "image_versions2":{"candidates":[{"url":"https://scontent.cdninstagram.com/img.jpg","width":1080,"height":1080}]}}},
                {"cursor":"C2","node":{"pk":"2743000000000000002","code":"CaBBBBB","taken_at":1710000100,
                     "media_type":2,
                     "caption":{"text":""},
                     "video_versions":[{"url":"https://scontent.cdninstagram.com/video.mp4"}],
                     "image_versions2":{"candidates":[{"url":"https://scontent.cdninstagram.com/thumb.jpg"}]}}}
            ],
            "page_info":{"end_cursor":"AQHCURSOR","has_next_page":true}}}}
        """
        let page = try InstagramWeb.parseTimeline(Data(json.utf8))
        XCTAssertEqual(page.posts.count, 2)
        XCTAssertEqual(page.nextCursor, "AQHCURSOR")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.posts[0].text, "Une légende")
        XCTAssertEqual(page.posts[0].code, "CaAAAAA")
        XCTAssertEqual(page.posts[0].media, [InstagramMedia(storageKey: "igm-2743000000000000001",
                                                             url: URL(string: "https://scontent.cdninstagram.com/img.jpg")!,
                                                             isVideo: false)])
        XCTAssertNotNil(page.posts[0].publishedAt)
        // Une vidéo garde son URL vidéo, jamais son affiche.
        XCTAssertEqual(page.posts[1].media, [InstagramMedia(storageKey: "igv-2743000000000000002",
                                                             url: URL(string: "https://scontent.cdninstagram.com/video.mp4")!,
                                                             isVideo: true)])
    }

    func testParseTimelineCarousel() throws {
        let json = """
        {"data":{"xdt_api__v1__feed__user_timeline_graphql_connection":{"edges":[
            {"node":{"pk":"2743000000000000003","code":"CaCCCCC","taken_at":1710000000,"media_type":8,
                     "caption":{"text":""},
                     "carousel_media":[
                        {"pk":"2743000000000000010","media_type":1,"image_versions2":{"candidates":[{"url":"https://cdn/a.jpg"}]}},
                        {"pk":"2743000000000000011","media_type":2,"video_versions":[{"url":"https://cdn/b.mp4"}]}
                     ]}}
        ],"page_info":{"end_cursor":null,"has_next_page":false}}}}
        """
        let page = try InstagramWeb.parseTimeline(Data(json.utf8))
        XCTAssertEqual(page.posts.count, 1)
        XCTAssertEqual(page.posts[0].media.map(\.storageKey),
                       ["igm-2743000000000000010", "igv-2743000000000000011"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    /// L'ancien format `api/v1` n'est plus servi : un corps message ne doit pas
    /// passer pour une fin de fil.
    func testParseTimelineRejectsLegacyFeedBody() {
        XCTAssertThrowsError(try InstagramWeb.parseTimeline(Data("{\"items\":[],\"more_available\":false}".utf8))) { error in
            XCTAssertEqual(error as? InstagramError, .invalidResponse)
        }
        XCTAssertThrowsError(try InstagramWeb.parseTimeline(Data("<html>login</html>".utf8))) { error in
            XCTAssertEqual(error as? InstagramError, .invalidResponse)
        }
    }

    /// Quota anonyme : Instagram répond 200 avec un message d'API.
    func testParseTimelineRateLimited() {
        let json = """
        {"errors":[{"message":"Rate limit exceeded","severity":"CRITICAL","code":1675004}],
         "extensions":{"is_final":true}}
        """
        XCTAssertThrowsError(try InstagramWeb.parseTimeline(Data(json.utf8))) { error in
            XCTAssertEqual(error as? InstagramError, .rateLimited)
        }
    }

    /// Repli SEO : la connexion est enfouie dans un script JSON de la page.
    /// Une vidéo n'y a pas d'URL vidéo : son affiche est prise comme image,
    /// jamais comme un faux fichier vidéo.
    func testParseCrawlerPage() throws {
        let payload = """
        {"require":[["RelayPrefetchedStreamCache","next",[],["adp_preloader",{"__bbox":{"result":{"data":{
            "xig_user_by_igid_v2":{"id":"1784140","polaris_timeline_connection":{
                "edges":[
                    {"node":{"__typename":"XIGPolarisVideoMedia","pk":"4031845282429052247","media_type":1,
                              "caption":{"text":"SEO"},
                              "image_versions2":{"candidates":[{"url":"https://cdn/seo.jpg"}]}}},
                    {"node":{"__typename":"XIGPolarisVideoMedia","pk":"4031845282429052248","media_type":2,
                              "caption":{"text":"Vidéo sans URL"},
                              "image_versions2":{"candidates":[{"url":"https://cdn/poster.jpg"}]}}}
                ],
                "page_info":{"end_cursor":"NEXT","has_next_page":true}}}
        }}}]]]}
        """
        let html = "<html><body><script type=\"application/json\" data-sjs>\(payload)</script></body></html>"
        let page = try InstagramWeb.parseCrawlerPage(Data(html.utf8))
        XCTAssertEqual(page.posts.count, 2)
        XCTAssertEqual(page.posts[0].id, "4031845282429052247")
        XCTAssertEqual(page.posts[0].text, "SEO")
        XCTAssertEqual(page.posts[0].media.map(\.storageKey), ["igm-4031845282429052247"])
        XCTAssertEqual(page.posts[1].media.map(\.storageKey), ["igm-4031845282429052248"])
        XCTAssertFalse(page.posts[1].media[0].isVideo)
        XCTAssertEqual(page.nextCursor, "NEXT")
    }

    func testParseCrawlerPageWithoutPayload() {
        XCTAssertThrowsError(try InstagramWeb.parseCrawlerPage(Data("<html></html>".utf8))) { error in
            XCTAssertEqual(error as? InstagramError, .invalidResponse)
        }
    }
}

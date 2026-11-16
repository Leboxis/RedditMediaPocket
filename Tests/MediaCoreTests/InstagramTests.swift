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
        XCTAssertEqual(source.feedURL(), InstagramAPI.profileInfoURL(username: "nasa"))
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

    func testParseProfile() throws {
        let json = """
        {"data":{"user":{"id":"1234567","edge_owner_to_timeline_media":{"edges":[
            {"node":{"id":"2743000000000000001","shortcode":"CaAAAAA","taken_at_timestamp":1710000000,
                     "is_video":false,
                     "display_url":"https://scontent.cdninstagram.com/img.jpg",
                     "edge_media_to_caption":{"edges":[{"node":{"text":"Une légende"}}]}}},
            {"node":{"id":"2743000000000000002","shortcode":"CaBBBBB","taken_at_timestamp":1710000100,
                     "is_video":true,
                     "video_url":"https://scontent.cdninstagram.com/video.mp4",
                     "edge_media_to_caption":{"edges":[]}}}
        ]}}}}
        """
        let profile = try InstagramWeb.parseProfile(Data(json.utf8))
        XCTAssertEqual(profile.userID, "1234567")
        XCTAssertEqual(profile.posts.count, 2)
        XCTAssertEqual(profile.posts[0].text, "Une légende")
        XCTAssertEqual(profile.posts[0].code, "CaAAAAA")
        XCTAssertEqual(profile.posts[0].media, [InstagramMedia(storageKey: "igm-2743000000000000001",
                                                               url: URL(string: "https://scontent.cdninstagram.com/img.jpg")!,
                                                               isVideo: false)])
        XCTAssertEqual(profile.posts[1].media, [InstagramMedia(storageKey: "igv-2743000000000000002",
                                                               url: URL(string: "https://scontent.cdninstagram.com/video.mp4")!,
                                                               isVideo: true)])
        XCTAssertNotNil(profile.posts[0].publishedAt)
    }

    func testParseProfileCarrousel() throws {
        let json = """
        {"data":{"user":{"id":"42","edge_owner_to_timeline_media":{"edges":[
            {"node":{"id":"2743000000000000003","shortcode":"CaCCCCC","taken_at_timestamp":1710000000,
                     "edge_sidecar_to_children":{"edges":[
                        {"node":{"id":"2743000000000000010","is_video":false,"display_url":"https://cdn/a.jpg"}},
                        {"node":{"id":"2743000000000000011","is_video":true,"video_url":"https://cdn/b.mp4"}}
                     ]},
                     "edge_media_to_caption":{"edges":[]}}}
        ]}}}}
        """
        let profile = try InstagramWeb.parseProfile(Data(json.utf8))
        XCTAssertEqual(profile.posts.count, 1)
        XCTAssertEqual(profile.posts[0].media.map(\.storageKey),
                       ["igm-2743000000000000010", "igv-2743000000000000011"])
    }

    func testParseProfileInvalid() {
        XCTAssertThrowsError(try InstagramWeb.parseProfile(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? InstagramError, .invalidResponse)
        }
        XCTAssertThrowsError(try InstagramWeb.parseProfile(Data("<html>login</html>".utf8)))
    }

    func testParseFeed() throws {
        let json = """
        {"items":[
            {"pk":"2743000000000000020","code":"CaDDDDD","taken_at":1710000000,
             "caption":{"text":"Texte du post"},
             "media_type":1,
             "image_versions2":{"candidates":[{"url":"https://cdn/x.jpg"}]}},
            {"pk":"2743000000000000021","code":"CaEEEEE","taken_at":1710000100,
             "media_type":2,
             "video_versions":[{"url":"https://cdn/y.mp4"}],
             "image_versions2":{"candidates":[{"url":"https://cdn/y.jpg"}]}},
            {"pk":"2743000000000000022","code":"CaFFFFF","taken_at":1710000200,
             "media_type":8,
             "carousel_media":[
                {"pk":"2743000000000000030","media_type":1,"image_versions2":{"candidates":[{"url":"https://cdn/z1.jpg"}]}},
                {"pk":"2743000000000000031","media_type":2,"video_versions":[{"url":"https://cdn/z2.mp4"}]}
             ]}
        ],"next_max_id":"2743000000000000022","more_available":true}
        """
        let page = try InstagramWeb.parseFeed(Data(json.utf8))
        XCTAssertEqual(page.posts.count, 3)
        XCTAssertEqual(page.nextCursor, "2743000000000000022")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.posts[0].text, "Texte du post")
        XCTAssertEqual(page.posts[0].media.map(\.storageKey), ["igm-2743000000000000020"])
        XCTAssertEqual(page.posts[1].media.map(\.storageKey), ["igv-2743000000000000021"])
        XCTAssertEqual(page.posts[2].media.map(\.storageKey),
                       ["igm-2743000000000000030", "igv-2743000000000000031"])
    }

    func testParseFeedLoginWall() {
        let json = """
        {"message":"login_required","error_type":"OAuthForbiddenException"}
        """
        XCTAssertThrowsError(try InstagramWeb.parseFeed(Data(json.utf8))) { error in
            XCTAssertEqual(error as? InstagramError, .loginRequired)
        }
    }

    func testParseFeedEnd() throws {
        let page = try InstagramWeb.parseFeed(Data("{\"items\":[],\"more_available\":false}".utf8))
        XCTAssertTrue(page.posts.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }
}

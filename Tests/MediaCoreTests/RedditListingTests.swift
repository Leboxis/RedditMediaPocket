import XCTest
@testable import MediaCore

/// Listing JSON `www.reddit.com/….json` : chemin retenu pour Reddit depuis la
/// coupure des flux `.rss` (13/11/2026). Les `Post` produits doivent être
/// identiques à ceux du parseur Atom : `t3_…`, lien absolu, HTML synthétique
/// exploitable par `MediaExtractor.extract` et `GalleryFeed.linkedID`.
final class RedditListingTests: XCTestCase {
    private let listing = """
    {
      "kind": "Listing",
      "data": {
        "after": "t3_zzz",
        "children": [
          {
            "kind": "t3",
            "data": {
              "id": "aaa111",
              "name": "t3_aaa111",
              "title": "Image post",
              "permalink": "/r/pics/comments/aaa111/image_post/",
              "url": "https://i.redd.it/aaa111.jpg",
              "created_utc": 1763600000.0,
              "is_video": false,
              "preview": { "images": [ { "source": { "url": "https://preview.redd.it/aaa111.jpg?width=640" } } ] }
            }
          },
          {
            "kind": "t3",
            "data": {
              "id": "bbb222",
              "name": "t3_bbb222",
              "title": "Video post",
              "permalink": "/r/pics/comments/bbb222/video_post/",
              "url": "https://v.redd.it/bbb222",
              "created_utc": 1763600100.0,
              "is_video": true,
              "media": { "reddit_video": { "fallback_url": "https://v.redd.it/bbb222/DASH_720.mp4?source=fallback" } }
            }
          },
          {
            "kind": "t3",
            "data": {
              "id": "ccc333",
              "name": "t3_ccc333",
              "title": "Gallery post",
              "permalink": "/r/pics/comments/ccc333/gallery_post/",
              "url": "https://www.reddit.com/gallery/ccc333",
              "created_utc": 1763600200.0,
              "is_video": false
            }
          },
          {
            "kind": "t1",
            "data": { "id": "comment", "body": "not a post" }
          }
        ]
      }
    }
    """

    func testParsesOnlyT3Children() throws {
        let posts = try RedditListing.parse(Data(listing.utf8))
        XCTAssertEqual(posts.map(\.id), ["t3_aaa111", "t3_bbb222", "t3_ccc333"])
    }

    func testPostFields() throws {
        let posts = try RedditListing.parse(Data(listing.utf8))
        let first = posts[0]
        XCTAssertEqual(first.title, "Image post")
        XCTAssertEqual(first.link, "https://www.reddit.com/r/pics/comments/aaa111/image_post/")
        XCTAssertEqual(first.publishedAt, Date(timeIntervalSince1970: 1763600000.0))
    }

    func testHtmlCarriesMediaForExtractor() throws {
        let posts = try RedditListing.parse(Data(listing.utf8))
        // Image : href i.redd.it + img d'aperçu.
        let image = MediaExtractor.extract(posts[0].html)
        XCTAssertEqual(image, [.direct(URL(string: "https://i.redd.it/aaa111.jpg")!])
        XCTAssertNotNil(MediaExtractor.previewImage(posts[0].html))
        // Vidéo : fallback v.redd.it prioritaire.
        let video = MediaExtractor.extract(posts[1].html)
        XCTAssertTrue(video.contains(.redditVideo(URL(string: "https://v.redd.it/bbb222")!)))
        // Galerie : lien /gallery/ détecté par GalleryFeed.linkedID.
        XCTAssertEqual(GalleryFeed.linkedID(posts[2].html), "ccc333")
        XCTAssertTrue(MediaExtractor.extract(posts[2].html).isEmpty)
    }

    func testCursorAfter() throws {
        XCTAssertEqual(RedditListing.after(Data(listing.utf8)), "t3_zzz")
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try RedditListing.parse(Data("<html><body>Blocked</body></html>".utf8)))
        XCTAssertThrowsError(try RedditListing.parse(Data("{}".utf8)))
    }

    func testEmptyListingIsValid() throws {
        let empty = #"{"kind":"Listing","data":{"after":null,"children":[]}}"#
        XCTAssertTrue(try RedditListing.parse(Data(empty.utf8)).isEmpty)
        XCTAssertNil(RedditListing.after(Data(empty.utf8)))
    }
}

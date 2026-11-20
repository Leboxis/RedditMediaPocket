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
        XCTAssertEqual(image, [.direct(URL(string: "https://i.redd.it/aaa111.jpg")!)])
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

    /// Le listing JSON porte gallery_data + media_metadata : la galerie doit
    /// être résolue directement (Post.galleryMedia), sans appel
    /// /comments/<id>.json, avec l'URL signée s.u exacte (vraie extension).
    func testGalleryResolvedInlineWithSignedURL() throws {
        let json = """
        {
          "kind": "Listing",
          "data": {
            "after": null,
            "children": [
              {
                "kind": "t3",
                "data": {
                  "id": "ddd444", "name": "t3_ddd444", "title": "Galerie",
                  "permalink": "/r/pics/comments/ddd444/galerie/",
                  "url": "https://www.reddit.com/gallery/ddd444",
                  "created_utc": 1763600300.0, "is_video": false,
                  "gallery_data": { "items": [ { "media_id": "m1" }, { "media_id": "m2" } ] },
                  "media_metadata": {
                    "m1": { "status": "valid", "m": "image/jpeg", "e": "Image",
                             "s": { "u": "https://preview.redd.it/aaa111.jpeg?width=2000&amp;auto=webp&amp;s=xyz" } },
                    "m2": { "status": "valid", "m": "image/jpg", "e": "Image",
                             "s": { "u": "https://preview.redd.it/bbb222.jpg?width=1000&amp;s=abc" } }
                  }
                }
              }
            ]
          }
        }
        """
        let posts = try RedditListing.parse(Data(json.utf8))
        XCTAssertEqual(posts.count, 1)
        let gallery = try XCTUnwrap(posts[0].galleryMedia)
        XCTAssertEqual(gallery.count, 2)
        // URL signée exacte, `&amp;` conservé dans le html/img mais décodé dans
        // les Media ; l'extension réelle (.jpeg) est préservée.
        guard case .direct(let first) = gallery[0] else { return XCTFail() }
        XCTAssertEqual(first.absoluteString,
                       "https://preview.redd.it/aaa111.jpeg?width=2000&auto=webp&s=xyz")
        // Le lien /gallery/ reste dans le html pour le repli réseau éventuel.
        XCTAssertNotNil(GalleryFeed.linkedID(posts[0].html))
    }
}

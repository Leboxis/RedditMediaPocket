import XCTest
@testable import MediaCore

final class GalleryFeedTests: XCTestCase {
    private let fixture = """
    [
      {
        "data": {
          "children": [
            {
              "data": {
                "id": "1wlhnh1",
                "is_gallery": true,
                "gallery_data": {
                  "items": [
                    { "id": 1, "media_id": "bbb222" },
                    { "id": 2, "media_id": "aaa111" },
                    { "id": 3, "media_id": "ccc333" },
                    { "id": 4, "media_id": "ddd444" },
                    { "id": 5, "media_id": "eee555" },
                    { "id": 6, "media_id": "fff666" }
                  ]
                },
                "media_metadata": {
                  "aaa111": {
                    "status": "valid", "e": "Image", "m": "image/png", "id": "aaa111",
                    "s": { "u": "https://preview.redd.it/aaa111.png?width=1080&format=png&auto=webp&s=aa", "x": 1080, "y": 1350 }
                  },
                  "bbb222": {
                    "status": "valid", "e": "Image", "m": "image/jpg", "id": "bbb222",
                    "s": { "u": "https://preview.redd.it/bbb222.jpg?width=3024&format=pjpg&auto=webp&s=bb", "x": 3024, "y": 4032 }
                  },
                  "ccc333": { "status": "failed", "e": "Image", "m": "image/jpg", "id": "ccc333", "s": { "u": "https://preview.redd.it/ccc333.jpg?width=640" } },
                  "ddd444": { "status": "valid", "e": "RedditVideo", "m": "video/mp4", "id": "ddd444", "s": { "dashUrl": "https://v.redd.it/ddd444/DASHPlaylist.mpd" } },
                  "eee555": { "status": "valid", "e": "AnimatedImage", "m": "image/gif", "id": "eee555", "s": { "gif": "https://i.redd.it/eee555.gif", "mp4": "https://preview.redd.it/eee555.mp4?s=ee", "x": 480, "y": 270 } },
                  "fff666": { "status": "valid", "e": "Image", "m": "image/jpeg", "id": "fff666", "s": { "u": "https://i.redd.it/fff666.jpg", "x": 800, "y": 600 } }
                }
              }
            }
          ]
        }
      }
    ]
    """

    func testParsesOrderedOriginals() throws {
        let media = try GalleryFeed.parse(Data(fixture.utf8))
        XCTAssertEqual(media, [
            .direct(URL(string: "https://i.redd.it/bbb222.jpg")!),
            .direct(URL(string: "https://i.redd.it/aaa111.png")!),
            .direct(URL(string: "https://i.redd.it/eee555.gif")!),
            .direct(URL(string: "https://i.redd.it/fff666.jpg")!)
        ])
    }

    func testParsesCrosspostedGalleryFromParent() throws {
        let json = """
        [
          {
            "data": {
              "children": [
                {
                  "data": {
                    "id": "1wlhnh1",
                    "crosspost_parent_list": [
                      {
                        "id": "1wlgxpz",
                        "gallery_data": { "items": [ { "media_id": "aaa111" } ] },
                        "media_metadata": { "aaa111": { "status": "valid", "e": "Image", "m": "image/jpg", "s": { "u": "https://preview.redd.it/aaa111.jpg?width=640" } } }
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
        """
        XCTAssertEqual(try GalleryFeed.parse(Data(json.utf8)),
                       [.direct(URL(string: "https://i.redd.it/aaa111.jpg")!)])
    }

    func testPostWithoutGalleryYieldsEmptyList() throws {
        let json = """
        [ { "data": { "children": [ { "data": { "id": "abc123", "title": "text" } } ] } } ]
        """
        XCTAssertEqual(try GalleryFeed.parse(Data(json.utf8)), [])
    }

    func testInvalidPayloadThrows() {
        XCTAssertThrowsError(try GalleryFeed.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try GalleryFeed.parse(Data(#"{"not":"a listing"}"#.utf8)))
    }

    func testRejectsUntrustedSources() throws {
        let json = """
        [
          {
            "data": {
              "children": [
                {
                  "data": {
                    "id": "abc123",
                    "gallery_data": { "items": [ { "media_id": "aaa111" }, { "media_id": "bbb222" } ] },
                    "media_metadata": {
                      "aaa111": { "status": "valid", "e": "Image", "m": "image/jpg", "s": { "u": "https://preview.redd.it.evil.example/aaa111.jpg" } },
                      "bbb222": { "status": "valid", "e": "Image", "m": "image/jpg", "s": { "u": "http://preview.redd.it/bbb222.jpg" } }
                    }
                  }
                }
              ]
            }
          }
        ]
        """
        XCTAssertEqual(try GalleryFeed.parse(Data(json.utf8)), [])
    }

    func testDetectsGalleryLink() {
        let gallery = #"<span><a href="https://www.reddit.com/gallery/1wlgxpz">[link]</a></span>"#
        XCTAssertTrue(GalleryFeed.linked(gallery))
        XCTAssertEqual(GalleryFeed.linkedID(gallery), "1wlgxpz")
        let image = #"<a href="https://i.redd.it/abc.jpg"><img src="https://preview.redd.it/abc.jpg"></a>"#
        XCTAssertFalse(GalleryFeed.linked(image))
        XCTAssertNil(GalleryFeed.linkedID(image))
    }

    func testCommentsJSONURLAcceptsFeedIDAndRejectsJunk() {
        XCTAssertEqual(GalleryFeed.commentsJSONURL(feedID: "t3_1wlhnh1")?.absoluteString,
                       "https://www.reddit.com/comments/1wlhnh1.json?raw_json=1&limit=1")
        XCTAssertNil(GalleryFeed.commentsJSONURL(feedID: "t3_"))
        XCTAssertNil(GalleryFeed.commentsJSONURL(feedID: "bad id/../.."))
    }
}

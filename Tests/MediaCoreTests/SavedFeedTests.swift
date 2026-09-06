import XCTest
@testable import MediaCore

final class SavedFeedTests: XCTestCase {
    func testAccountIdentityAndLoggedOutResponse() throws {
        XCTAssertEqual(try SavedPage.account(Data(#"{"kind":"t2","data":{"name":"Connected_User"}}"#.utf8)), "Connected_User")
        XCTAssertThrowsError(try SavedPage.account(Data(#"{"data":{}}"#.utf8)))
    }

    func testJSONURLAndCommentCursor() throws {
        let url = try SavedPage.url(username: "Connected_User", after: "t1_last")
        XCTAssertEqual(url.path, "/user/Connected_User/saved.json")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(URLQueryItem(name: "after", value: "t1_last")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "raw_json", value: "1")))
        XCTAssertThrowsError(try SavedPage.url(username: "../other"))
    }

    func testMixedListingUsesServerCursorAndOriginalMedia() throws {
        let data = Data(#"""
        {"kind":"Listing","data":{"after":"t1_last","children":[
          {"kind":"t3","data":{"name":"t3_image","url_overridden_by_dest":"https://i.redd.it/image.jpg","thumbnail":"https://i.redd.it/thumb.jpg"}},
          {"kind":"t3","data":{"name":"t3_gallery","gallery_data":{"items":[{"media_id":"b"},{"media_id":"a"}]},"media_metadata":{
            "a":{"status":"valid","s":{"u":"https://i.redd.it/a.png"}},
            "b":{"status":"valid","s":{"gif":"https://i.redd.it/b.gif"}}
          }}},
          {"kind":"t3","data":{"name":"t3_crosspost","crosspost_parent_list":[{"url":"https://v.redd.it/video","secure_media":{"reddit_video":{"fallback_url":"https://v.redd.it/video/DASH_1080.mp4"}}}]}},
          {"kind":"t1","data":{"name":"t1_last","body_html":"<a href=\"https://www.redgifs.com/watch/Example\">video</a>"}}
        ]}}
        """#.utf8)
        let page = try SavedPage.parse(data)
        XCTAssertEqual(page.after, "t1_last")
        XCTAssertEqual(page.entries.count, 4)
        XCTAssertEqual(page.entries[0].media, [.direct(URL(string: "https://i.redd.it/image.jpg")!)])
        XCTAssertEqual(page.entries[1].media, [.direct(URL(string: "https://i.redd.it/b.gif")!), .direct(URL(string: "https://i.redd.it/a.png")!)])
        XCTAssertEqual(page.entries[2].media, [.redditVideo(URL(string: "https://v.redd.it/video")!)])
        XCTAssertEqual(page.entries[3].media, [.redgifs("example")])
    }

    func testEmptyAndCommentOnlyPages() throws {
        let empty = try SavedPage.parse(Data(#"{"kind":"Listing","data":{"children":[],"after":null}}"#.utf8))
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertNil(empty.after)
        let comments = try SavedPage.parse(Data(#"{"kind":"Listing","data":{"children":[{"kind":"t1","data":{"name":"t1_comment","body_html":"no media"}}],"after":"t1_comment"}}"#.utf8))
        XCTAssertEqual(comments.after, "t1_comment")
        XCTAssertTrue(comments.entries[0].media.isEmpty)
    }

    func testRejectsErrorHTMLAndMalformedListing() {
        for text in ["<html>login</html>", #"{"error":403}"#, #"{"kind":"Listing","data":{"children":[{}]}}"#, #"{"kind":"Listing","data":{"children":[],"after":42}}"#] {
            XCTAssertThrowsError(try SavedPage.parse(Data(text.utf8)))
        }
    }
}

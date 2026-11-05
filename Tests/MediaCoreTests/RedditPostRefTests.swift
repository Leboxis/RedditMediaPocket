import XCTest
@testable import MediaCore

/// Posts Reddit isolés : analyse d'adresse, sélection et résolution du JSON.
final class RedditPostRefTests: XCTestCase {
    func testCanonicalPostURLIsRecognised() {
        let post = RedditPostRef.postID("https://www.reddit.com/r/pics/comments/1abc234/some_title/")
        XCTAssertEqual(post?.id, "t3_1abc234")
        XCTAssertEqual(post?.subreddit, "pics")
        XCTAssertEqual(post?.url.absoluteString, "https://www.reddit.com/r/pics/comments/1abc234/")
    }

    func testShortAndBareForms() {
        XCTAssertEqual(RedditPostRef.postID("https://redd.it/1abc234")?.id, "t3_1abc234")
        XCTAssertEqual(RedditPostRef.postID("redd.it/1abc234")?.id, "t3_1abc234")
        XCTAssertEqual(RedditPostRef.postID("https://www.reddit.com/comments/1abc234/")?.id, "t3_1abc234")
        XCTAssertNil(RedditPostRef.postID("https://www.reddit.com/comments/1abc234/")?.subreddit)
    }

    func testRejectsEverythingElse() {
        XCTAssertNil(RedditPostRef.postID("https://www.reddit.com/r/pics/"))
        XCTAssertNil(RedditPostRef.postID("https://www.reddit.com/r/pics/comments/"))
        XCTAssertNil(RedditPostRef.postID("https://evil.test/r/pics/comments/1abc234/"))
        XCTAssertNil(RedditPostRef.postID("https://www.reddit.com/r/pics/comments/ab/x/"))
        XCTAssertNil(RedditPostRef.postID(""))
        XCTAssertNil(RedditPostRef.postID("r/pics"))
    }

    func testSelectionDeduplicatesAndIgnoresNoise() throws {
        let target = try RedditPostRef.parseTarget("""
        https://www.reddit.com/r/pics/comments/aaaa11/x/
        https://redd.it/bbbb22
        https://www.reddit.com/r/pics/comments/aaaa11/x/
        """)
        XCTAssertEqual(target.posts.map(\.id), ["t3_aaaa11", "t3_bbbb22"])
        XCTAssertEqual(target.collectionName, "posts")
        XCTAssertThrowsError(try RedditPostRef.parseTarget("   "))
        XCTAssertThrowsError(try RedditPostRef.parseTarget("bonjour"))
    }

    func testFeedSourceAcceptsPostSelection() throws {
        let source = try FeedSource.parse("https://www.reddit.com/r/pics/comments/1abc234/some_title/")
        guard case .redditPosts(let target) = source else {
            return XCTFail("adresse de post lue comme \(source)")
        }
        XCTAssertEqual(target.posts.count, 1)
        XCTAssertEqual(source.id, "reddit/posts")
        XCTAssertEqual(source.folderName, "reddit.posts")
        // La collection est stable : deux sélections différentes la partagent.
        let other = try FeedSource.parse("https://redd.it/zzzz99")
        XCTAssertEqual(other.id, source.id)
        // Et elle ne peut pas entrer en collision avec un subreddit « posts ».
        XCTAssertEqual(try FeedSource.parse("r/posts").id, "r/posts")
        XCTAssertNotEqual(try FeedSource.parse("r/posts").folderName, source.folderName)
    }

    func testSubredditStillWinsWithoutPostAddress() throws {
        XCTAssertEqual(try FeedSource.parse("r/pics"), .subreddit("pics"))
        // Coller l'adresse du subreddit équivaut à saisir `r/pics`.
        XCTAssertEqual(try FeedSource.parse("https://www.reddit.com/r/pics/"), .subreddit("pics"))
        XCTAssertEqual(try FeedSource.parse("https://www.reddit.com/r/pics/new/"), .subreddit("pics"))
        XCTAssertEqual(FeedSource.subredditFromURL("https://old.reddit.com/r/EarthPorn/"), "EarthPorn")
        XCTAssertNil(FeedSource.subredditFromURL("https://www.reddit.com/user/x/"))
        XCTAssertNil(FeedSource.subredditFromURL("https://evil.test/r/pics/"))
    }

    // MARK: Résolution du JSON

    private func listing(_ post: [String: Any], comments: [[String: Any]] = []) throws -> Data {
        let root: [Any] = [
            ["kind": "Listing", "data": ["children": [["kind": "t3", "data": post]]]],
            ["kind": "Listing", "data": ["children": comments]]
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testSingleImagePostIsResolved() throws {
        let data = try listing([
            "id": "abc123",
            "title": "Un chat",
            "created_utc": 1_700_000_000,
            "permalink": "/r/pics/comments/abc123/un_chat/",
            "url_overridden_by_dest": "https://i.redd.it/xyz99.jpg"
        ])
        let fallback = RedditPostRef.Post(id: "t3_abc123", url: URL(string: "https://redd.it/abc123")!)
        let detail = try RedditPostRef.parsePost(data, fallback: fallback)
        XCTAssertEqual(detail.id, "t3_abc123")
        XCTAssertEqual(detail.title, "Un chat")
        XCTAssertEqual(detail.media, [.direct(URL(string: "https://i.redd.it/xyz99.jpg")!)])
        XCTAssertEqual(detail.publishedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(detail.url.absoluteString, "https://www.reddit.com/r/pics/comments/abc123/un_chat/")
    }

    func testVideoPostUsesDASHPipeline() throws {
        let data = try listing([
            "id": "vid123",
            "title": "Vidéo",
            "url_overridden_by_dest": "https://v.redd.it/abc999/xyz"
        ])
        let fallback = RedditPostRef.Post(id: "t3_vid123", url: URL(string: "https://redd.it/vid123")!)
        let detail = try RedditPostRef.parsePost(data, fallback: fallback)
        XCTAssertEqual(detail.media, [.redditVideo(URL(string: "https://v.redd.it/abc999")!)])
    }

    func testGalleryPostListsEveryImageInOrder() throws {
        let data = try listing([
            "id": "gal123",
            "title": "Galerie",
            "gallery_data": ["items": [["media_id": "a"], ["media_id": "b"]]],
            "media_metadata": [
                "a": ["status": "valid", "m": "image/jpg", "s": ["u": "https://preview.redd.it/a.jpg?width=1080"]],
                "b": ["status": "valid", "m": "image/png", "s": ["u": "https://preview.redd.it/b.png"]]
            ]
        ])
        let fallback = RedditPostRef.Post(id: "t3_gal123", url: URL(string: "https://redd.it/gal123")!)
        let detail = try RedditPostRef.parsePost(data, fallback: fallback)
        XCTAssertEqual(detail.media, [
            .direct(URL(string: "https://i.redd.it/a.jpg")!),
            .direct(URL(string: "https://i.redd.it/b.png")!)
        ])
    }

    func testPostWithoutMediaIsEmptyNotAnError() throws {
        let data = try listing([
            "id": "txt123",
            "title": "Texte seul",
            "url_overridden_by_dest": "https://example.test/article"
        ])
        let fallback = RedditPostRef.Post(id: "t3_txt123", url: URL(string: "https://redd.it/txt123")!)
        let detail = try RedditPostRef.parsePost(data, fallback: fallback)
        XCTAssertTrue(detail.media.isEmpty)
        XCTAssertEqual(detail.title, "Texte seul")
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try RedditPostRef.parsePost(
            Data("pas du json".utf8),
            fallback: RedditPostRef.Post(id: "t3_x", url: URL(string: "https://redd.it/x")!)))
    }
}

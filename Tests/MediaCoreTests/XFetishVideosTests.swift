import XCTest
@testable import MediaCore

final class XFetishVideosTests: XCTestCase {
    /// Real page shape captured from `itwasalwaysmysolesvip` on 2026-09-29.
    private static let playerPage = """
    <div class="player"><script type="text/javascript">
    var td41013a933 = {
    video_id: '708259',
    video_title: 'The softest soles',
    event_reporting2: 'https://x-fetish.tube/get_file/11/e91cbcd4820f4c76e77161a8f5cfe010/708000/708259/708259.mp4/?v-acctoken=report-secret',
    video_url: 'https://x-fetish.tube/get_file/11/e2c0bcfed5372d6819b0152ea213b10e/708000/708259/708259_single_hd_vertical.mp4/?v-acctoken=MjE5NXwxfDB8MTE0NDA5MzkyZjA5OWEzYTI4YmNiMzVmYmIzNjA2MmYb1f67b1f3d4c83b7',
    video_url_fhd: '1',
    postfix: '_single_hd_vertical.mp4',
    preview_url: 'https://x-fetish.tube/contents/videos_screenshots/708000/708259/preview.jpg',
    };
    </script></div>
    """

    private func video(_ id: String = "708259") -> XFetishVideos.Video {
        XFetishVideos.Video(id: id, title: "The softest soles",
                            url: URL(string: "https://x-fetish.tube/video/\(id)/slug/")!)
    }

    func testListingKeepsOnlyVideosAndAdvancesToNextPage() throws {
        let html = """
        <div id="list_videos_common_videos_list">
          <div class="thumbs__list cfx">
            <div class="item thumb thumb--videos" data-hover="true">
              <a href="https://x-fetish.tube/video/708259/itwasalwaysmysolesvip-the-softest-soles/" title="Itwasalwaysmysolesvip - 09-17-2026 OnlyFans Video - The softest soles">
                <img class="lazyload" data-src="https://x-fetish.tube/contents/videos_screenshots/708000/708259/576x460/3.jpg" data-preview="https://x-fetish.tube/get_file/11/059705ff9e46771b0a4ee1d90aee007c/708000/708259/708259_preview_vertical.mp4/">
              </a>
            </div>
            <div class="item thumb thumb--videos"><a title="Second" href="/video/708257/second-slug/">Two</a></div>
            <div class="item thumb thumb--videos"><a href="/video/708257/second-slug/">Duplicate</a></div>
            <div class="item thumb thumb--videos"><a href="https://other.example/video/999/a/">Off site</a></div>
            <div class="item thumb thumb--albums"><a href="/albums/3948/older/">Album</a></div>
          </div>
          <div class="pagination"><a href="/models/example/videos/2/">2</a>
            <a href="/models/other/videos/3/">3</a></div>
        </div>
        """
        let page = try XFetishVideos.parseListing(Data(html.utf8), model: "example", page: 1)
        XCTAssertEqual(page.videos.map(\.id), ["708259", "708257"])
        XCTAssertEqual(page.videos[0].title, "Itwasalwaysmysolesvip - 09-17-2026 OnlyFans Video - The softest soles")
        XCTAssertEqual(page.videos[1].url.absoluteString, "https://x-fetish.tube/video/708257/second-slug/")
        XCTAssertEqual(page.nextPage, 2)
    }

    func testListingURLsMirrorTheAlbumPagination() {
        XCTAssertEqual(XFetishVideos.listingURL(model: "example", page: 1).absoluteString,
                       "https://x-fetish.tube/models/example/videos/")
        XCTAssertEqual(XFetishVideos.listingURL(model: "example", page: 3).absoluteString,
                       "https://x-fetish.tube/models/example/videos/3/")
    }

    /// Video slugs are the media title, so they exceed the 80-character model
    /// slug bound. A real 89-character slug must still be kept.
    func testLongTitleSlugsAreKept() throws {
        let slug = "itwasalwaysmysolesvip-aka-itwasalwaysmysolesvip-09-17-2026-onlyfans-video-the-softest-soles"
        XCTAssertGreaterThan(slug.count, 80)
        XCTAssertFalse(XFetishHTML.slug(slug))
        XCTAssertTrue(XFetishHTML.pathComponent(slug))
        let html = """
        <div id="list_videos_common_videos_list">
          <a href="/video/708259/\(slug)/" title="The softest soles">One</a>
        </div>
        """
        let page = try XFetishVideos.parseListing(Data(html.utf8), model: "example", page: 1)
        XCTAssertEqual(page.videos.map(\.id), ["708259"])
    }

    func testPathComponentRejectsSeparatorsAndEscapes() {
        XCTAssertFalse(XFetishHTML.pathComponent("has spaces"))
        XCTAssertFalse(XFetishHTML.pathComponent("dot.slug"))
        XCTAssertFalse(XFetishHTML.pathComponent("percent%2Fescape"))
        XCTAssertFalse(XFetishHTML.pathComponent("slash/es"))
        XCTAssertFalse(XFetishHTML.pathComponent(String(repeating: "a", count: 301)))
    }

    func testMalformedListingIsNotTreatedAsNoVideos() {
        XCTAssertThrowsError(try XFetishVideos.parseListing(Data("<html>blocked</html>".utf8), model: "example", page: 1))
    }

    func testPlayerPageYieldsTheSignedRouteAndKeepsTheToken() throws {
        let url = try XFetishVideos.parseFileURL(Data(Self.playerPage.utf8), video: video())
        XCTAssertEqual(url.absoluteString,
                       "https://x-fetish.tube/get_file/11/e2c0bcfed5372d6819b0152ea213b10e/708000/708259/708259_single_hd_vertical.mp4/?v-acctoken=MjE5NXwxfDB8MTE0NDA5MzkyZjA5OWEzYTI4YmNiMzVmYmIzNjA2MmYb1f67b1f3d4c83b7")
        // The reporting route is never mistaken for the media file.
        XCTAssertFalse(url.absoluteString.contains("report-secret"))
        XCTAssertTrue(XFetishIPv4.isSignedMediaRoute(url))
    }

    func testPlayerPageAcceptsAPlainFileName() throws {
        let html = "<script>video_url: 'https://x-fetish.tube/get_file/11/abcdef0123456789/708000/708259/708259.mp4/?v-acctoken=x'</script>"
        let url = try XFetishVideos.parseFileURL(Data(html.utf8), video: video())
        XCTAssertEqual(url.lastPathComponent, "708259.mp4")
    }

    func testPlayerPageRejectsForeignAndNonMediaRoutes() {
        let anotherVideo = "video_url: 'https://x-fetish.tube/get_file/11/abcdef0123456789/708000/708259/708257.mp4/'"
        let offSite = "video_url: 'https://storage4.x-fetish.tube/contents/videos/708259.mp4'"
        let imageRoute = "video_url: 'https://x-fetish.tube/get_image/10/abc/sources/3000/3948/2652884.jpg/'"
        let nonVideo = "video_url: 'https://x-fetish.tube/get_file/11/abcdef0123456789/708000/708259/708259.mkv/'"
        let elsewhere = "video_url: 'https://x-fetish.tube/contents/videos_screenshots/708000/708259/708259.mp4'"
        for script in [anotherVideo, offSite, imageRoute, nonVideo, elsewhere, "<html>blocked</html>", "video_url: ''"] {
            XCTAssertThrowsError(try XFetishVideos.parseFileURL(Data(script.utf8), video: video())) { error in
                guard case XFetishVideoError.invalidPlayer = error else {
                    return XCTFail("Expected invalidPlayer, got \(error)")
                }
            }
        }
    }

    func testPlayerPageAcceptsARelativeRouteOnTheSameSite() throws {
        let script = "video_url: '/get_file/11/abcdef0123456789/708000/708259/708259.mp4/?v-acctoken=x'"
        let url = try XFetishVideos.parseFileURL(Data(script.utf8), video: video())
        XCTAssertEqual(url.absoluteString,
                       "https://x-fetish.tube/get_file/11/abcdef0123456789/708000/708259/708259.mp4/?v-acctoken=x")
    }

    func testOnlyVideoRoutesAreForcedOverIPv4() {
        XCTAssertFalse(XFetishIPv4.isSignedMediaRoute(URL(string: "https://x-fetish.tube/video/708259/slug/")!))
        XCTAssertFalse(XFetishIPv4.isSignedMediaRoute(URL(string: "https://x-fetish.tube/models/example/videos/")!))
        XCTAssertFalse(XFetishIPv4.isSignedMediaRoute(
            URL(string: "https://evil.example/get_file/11/abcdef0123456789/708000/708259/708259.mp4/")!))
    }

    func testMediaKindCoversEveryCombination() {
        XCTAssertEqual(XFetishMediaKind.allCases, [.images, .videos, .both])
        XCTAssertTrue(XFetishMediaKind.images.includesImages)
        XCTAssertFalse(XFetishMediaKind.images.includesVideos)
        XCTAssertFalse(XFetishMediaKind.videos.includesImages)
        XCTAssertTrue(XFetishMediaKind.videos.includesVideos)
        XCTAssertTrue(XFetishMediaKind.both.includesImages)
        XCTAssertTrue(XFetishMediaKind.both.includesVideos)
        XCTAssertEqual(XFetishMediaKind.defaultsKey, "xFetishMediaKind")
    }

    func testVideoTokenIsMaskedInDiagnostics() {
        let url = URL(string: "https://x-fetish.tube/get_file/11/abcdef0123456789/708000/708259/708259.mp4/?v-acctoken=secret-value")!
        let summary = LogDiagnostics.requestSummary(url)
        XCTAssertTrue(summary.contains("v-acctoken=oui"))
        XCTAssertFalse(summary.contains("secret-value"))
        XCTAssertFalse(LogDiagnostics.sanitize("GET /get_file/11/x/708259.mp4/?v-acctoken=secret-value")
            .contains("secret-value"))
    }
}

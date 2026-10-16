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

    func testPlayerAttachesAdjacentTokenWithoutReplacingExistingToken() throws {
        let route = "https://x-fetish.tube/get_file/11/abcdef0123456789/708000/708259/708259.mp4/"
        let separate = "video_url: '\(route)', 'v-acctoken': 'fresh-token'"
        let url = try XFetishVideos.parseFileURL(Data(separate.utf8), video: video())
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "fresh-token")
        let existing = "video_url: '\(route)?v-acctoken=original', 'v-acctoken': 'other'"
        let kept = try XFetishVideos.parseFileURL(Data(existing.utf8), video: video())
        XCTAssertEqual(URLComponents(url: kept, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "original")
    }

    func testAdjacentTokenEscapesPlusAndPreservesExistingQueryBytes() throws {
        let route = "https://x-fetish.tube/get_file/11/abcdef0123456789/708000/708259/708259.mp4/"
        let existing = "other=a%2Bb%252Fc+space&flag"
        for token in ["abc+def/ghi==&%", "literal%2B+token"] {
            let script = "video_url: '\(route)?\(existing)', 'v-acctoken': '\(token)'"
            let url = try XFetishVideos.parseFileURL(Data(script.utf8), video: video())
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = try XCTUnwrap(components.percentEncodedQuery)
            XCTAssertTrue(query.hasPrefix(existing + "&v-acctoken="))
            XCTAssertTrue(query.contains("%2B"))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "v-acctoken" })?.value, token)
            XCTAssertFalse(query.components(separatedBy: "v-acctoken=").last!.contains("+"))
        }
    }

    @MainActor func testPageBudgetResumesAt101ThenRestartsAtHead() async throws {
        var resume: Int?
        var requested: [Int] = []
        var processed: [Int] = []
        let fetch: (Int) async throws -> XFetishVideos.ListingPage = { page in
            requested.append(page)
            return .init(videos: [self.video("\(page)")], nextPage: page < 101 ? page + 1 : nil)
        }
        let first = try await XFetishVideos.run(page: resume ?? 1, fetch: fetch, process: { videos in
            XCTAssertEqual(requested.count, 100, "Collect listings before resolving any signed files")
            XCTAssertNil(resume, "Do not advance the checkpoint before downloads finish")
            processed.append(videos.count)
        }, persist: { resume = $0 })
        XCTAssertFalse(first)
        XCTAssertEqual(resume, 101)
        let second = try await XFetishVideos.run(page: resume ?? 1, fetch: fetch,
            process: { processed.append($0.count) }, persist: { resume = $0 })
        XCTAssertTrue(second)
        XCTAssertNil(resume)
        _ = try await XFetishVideos.run(page: resume ?? 1, maximumPages: 1, fetch: fetch,
            process: { processed.append($0.count) }, persist: { resume = $0 })
        XCTAssertEqual(Array(requested.suffix(2)), [101, 1])
        XCTAssertEqual(processed, [100, 1, 1])
    }

    @MainActor func testFailedOrCancelledBatchKeepsItsStartingPage() async throws {
        let errors: [Error] = [NetworkError.refused(503), CancellationError()]
        for error in errors {
            var resume: Int? = 101
            do {
                _ = try await XFetishVideos.run(page: resume!, maximumPages: 1,
                    fetch: { _ in .init(videos: [self.video()], nextPage: 102) },
                    process: { _ in throw error }, persist: { resume = $0 })
                XCTFail("Expected the batch to fail")
            } catch { XCTAssertEqual(resume, 101) }
        }
    }

    @MainActor func testRepeatedVideosAreCollectedOnceAndBadPaginationNeverCommits() async throws {
        var received: [String] = []
        _ = try await XFetishVideos.run(maximumPages: 2,
            fetch: { page in .init(videos: [self.video()], nextPage: page + 1) },
            process: { received = $0.map(\.id) }, persist: { XCTAssertEqual($0, 3) })
        XCTAssertEqual(received, ["708259"])
        do {
            _ = try await XFetishVideos.run(page: 101,
                fetch: { _ in .init(videos: [], nextPage: 101) },
                process: { _ in XCTFail("Do not process a pagination cycle") },
                persist: { _ in XCTFail("Do not commit a pagination cycle") })
            XCTFail("Expected invalid listing")
        } catch XFetishVideoError.invalidListing { }
    }

    @MainActor func testInvalidPageOrBudgetDoesNotFetchOrCommit() async throws {
        for (page, budget) in [(0, 100), (-1, 100), (1, 0), (1, -1)] {
            do {
                _ = try await XFetishVideos.run(page: page, maximumPages: budget,
                    fetch: { _ in XCTFail("Do not fetch invalid pagination"); return .init(videos: [], nextPage: nil) },
                    process: { _ in XCTFail("Do not process invalid pagination") },
                    persist: { _ in XCTFail("Do not commit invalid pagination") })
                XCTFail("Expected invalid listing")
            } catch XFetishVideoError.invalidListing { }
        }
    }

    func testForbiddenTransferResolvesAFreshURLExactlyOnce() async throws {
        var pageReads = 0
        var tokens: [String] = []
        var attempts: [Int] = []
        let output = URL(fileURLWithPath: "/temporary/video.mp4")
        let result = try await XFetishVideos.download(video(), page: { _ in
            pageReads += 1
            return Data("video_url: '/get_file/11/abcdef0123456789/708000/708259/708259.mp4/?v-acctoken=token\(pageReads)'".utf8)
        }, transfer: { url, attempt in
            attempts.append(attempt)
            tokens.append(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)
            if tokens.count == 1 { throw NetworkError.refused(403) }
            return output
        })
        XCTAssertEqual(result, output)
        XCTAssertEqual(pageReads, 2)
        XCTAssertEqual(tokens, ["token1", "token2"])
        XCTAssertEqual(attempts, [0, 1])
    }

    func testSecondForbiddenAndRateLimitNeverRefreshAgain() async throws {
        for status in [403, 429] {
            var pageReads = 0
            do {
                _ = try await XFetishVideos.download(video(), page: { _ in
                    pageReads += 1
                    return Data(Self.playerPage.utf8)
                }, transfer: { _, _ in
                    if status == 429 { throw NetworkError.limited(service: "X-Fetish", until: nil) }
                    throw NetworkError.refused(403)
                })
                XCTFail("Expected refusal")
            } catch NetworkError.refused(let code) { XCTAssertEqual(code, 403) }
              catch NetworkError.limited { XCTAssertEqual(status, 429) }
            XCTAssertEqual(pageReads, status == 403 ? 2 : 1)
        }
    }

    func testCancelledVideoDoesNotResolveOrRefresh() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await XFetishVideos.download(self.video(), page: { _ in
                XCTFail("Cancelled work must not resolve a signed URL")
                return Data()
            }, transfer: { _, _ in
                XCTFail("Cancelled work must not download")
                return URL(fileURLWithPath: "/unused")
            })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
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

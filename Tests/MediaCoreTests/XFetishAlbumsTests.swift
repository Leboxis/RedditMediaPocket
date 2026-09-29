import XCTest
@testable import MediaCore

final class XFetishAlbumsTests: XCTestCase {
    func testIPv4ImageTargetPreservesTrailingSlashAndSignedQuery() throws {
        let url = try XCTUnwrap(URL(string: "https://x-fetish.tube/get_image/12/abc/sources/6000/6264/3454270.jpg/?i-acctoken=a%2Bb%2Fz&v=1"))
        XCTAssertEqual(try XFetishIPv4.requestTarget(for: url),
                       "/get_image/12/abc/sources/6000/6264/3454270.jpg/?i-acctoken=a%2Bb%2Fz&v=1")
    }

    func testIPv4ImageTargetPreservesEncodedPath() throws {
        let url = try XCTUnwrap(URL(string: "https://x-fetish.tube/get_image/a%2Fb/image.jpg/?token=x%26y"))
        XCTAssertEqual(try XFetishIPv4.requestTarget(for: url), "/get_image/a%2Fb/image.jpg/?token=x%26y")
    }

    func testSourceButtonCyclesThroughAllFourKinds() {
        XCTAssertEqual(SourceKind.user.next, .subreddit)
        XCTAssertEqual(SourceKind.subreddit.next, .saved)
        XCTAssertEqual(SourceKind.saved.next, .xFetish)
        XCTAssertEqual(SourceKind.xFetish.next, .user)
    }

    func testExistingImageIDSurvivesAlbumRename() {
        let oldName = "Original title - xf-3948-2652884.jpg"
        let newName = "Renamed album - xf-3948-2652884.jpg"
        XCTAssertEqual(FilenamePolicy.xFetishMediaID(inFileName: oldName), "xf-3948-2652884")
        XCTAssertEqual(FilenamePolicy.xFetishMediaID(inFileName: newName),
                       FilenamePolicy.xFetishMediaID(inFileName: oldName))
        XCTAssertEqual(FilenamePolicy.xFetishMediaID(inFileName: "Title - xfv-708259.mp4"), "xfv-708259")
        XCTAssertEqual(FilenamePolicy.xFetishMediaID(inFileName: "Title - xf-3948-2652884.webp"), "xf-3948-2652884")
        XCTAssertNil(FilenamePolicy.xFetishMediaID(inFileName: "Other - xf-3948-abc.jpg"))
        XCTAssertNil(FilenamePolicy.xFetishMediaID(inFileName: "title without a key.jpg"))
        XCTAssertNil(FilenamePolicy.xFetishMediaID(inFileName: "Some post - xf-3948-2652884.txt"))
    }

    func testProfileSourceUsesDistinctCollectionAndListing() throws {
        let source = try FeedSource.parse(" X/ItWasAlwaysMySolesVIP ")
        XCTAssertEqual(source, .xFetish("itwasalwaysmysolesvip"))
        XCTAssertEqual(source.id, "x/itwasalwaysmysolesvip")
        XCTAssertEqual(source.folderName, "x.itwasalwaysmysolesvip")
        XCTAssertEqual(source.feedURL().absoluteString,
                       "https://x-fetish.tube/models/itwasalwaysmysolesvip/albums/")
        XCTAssertThrowsError(try FeedSource.parse("x/../other"))
        XCTAssertThrowsError(try FeedSource.parse("x/not a slug"))
    }

    func testListingKeepsOnlyAlbumsAndAdvancesToNextPage() throws {
        let html = """
        <div id="list_albums_common_albums_list">
          <a href="https://x-fetish.tube/albums/6264/example-pictures-2/" title="Example &amp; Friends">Album</a>
          <a title="Older album" href="/albums/3948/older-pictures/">Album</a>
          <a href="/albums/3948/older-pictures/">Duplicate</a>
          <a href="https://other.example/albums/999/unrelated/">Unrelated</a>
          <div class="pagination"><a href="/models/example/albums/2/">2</a>
            <a href="/models/another/albums/3/">3</a></div>
        </div>
        <div id="list_albums_related_albums"><a href="/albums/7777/unrelated/" title="Related">Related</a></div>
        """
        let page = try XFetishAlbums.parseListing(Data(html.utf8), model: "example", page: 1)
        XCTAssertEqual(page.albums.map(\.id), ["6264", "3948"])
        XCTAssertEqual(page.albums.map(\.title), ["Example & Friends", "Older album"])
        XCTAssertEqual(page.nextPage, 2)
        XCTAssertEqual(page.albums[1].url.absoluteString, "https://x-fetish.tube/albums/3948/older-pictures/")
    }

    func testGalleryExtractsOriginalLinksAndExtraPageCount() throws {
        let album = XFetishAlbums.Album(id: "3948", title: "Example", url: URL(string: "https://x-fetish.tube/albums/3948/example/")!)
        let html = """
        <div id="albumGallery">
          <a rel="screenshots" href="https://x-fetish.tube/get_image/10/abc/sources/3000/3948/2652884.jpg/?i-acctoken=abc&amp;v=1"><img src="https://storage4.x-fetish.tube/contents/albums/main/200x150/3000/3948/2652884.jpg"></a>
          <a href="https://x-fetish.tube/get_image/10/def/sources/3000/3948/2652885.png/" rel="screenshots">Two</a>
          <a rel="screenshots" href="https://evil.example/get_image/10/abc/sources/3000/3948/3.jpg/">Unrelated</a>
          <a rel="screenshots" href="https://x-fetish.tube/get_image/10/abc/sources/3000/9999/4.jpg/">Other album</a>
          <a href="https://x-fetish.tube/video/1/a/">Video</a>
        </div>
        <a rel="screenshots" href="/get_image/10/other/sources/3000/3948/2652999.jpg/">Advertisement</a>
        <a class="js-ajax-images2" data-from="1" data-total="2" href="">Show More</a>
        """
        let gallery = try XFetishAlbums.parseGallery(Data(html.utf8), album: album)
        XCTAssertEqual(gallery.images.map(\.id), ["2652884", "2652885"])
        XCTAssertEqual(gallery.extraPages, 2)
        XCTAssertEqual(gallery.images[0].url.query, "i-acctoken=abc&v=1")
        XCTAssertEqual(XFetishAlbums.extraImagesURL(album: album, page: 1).absoluteString,
                       "https://x-fetish.tube/albums/3948/example/?mode=async&function=get_block&block_id=album_view_album_view&load=more&from=1")
    }

    func testImageFragmentDeduplicatesIDsAndRejectsUnrelatedLinks() throws {
        let html = """
        <div class="item"><a href="/get_image/10/abc/sources/3000/3948/2652884.jpg/" rel="screenshots">One</a></div>
        <div class="item"><a rel="screenshots" href="/get_image/10/changed/sources/3000/3948/2652884.jpg/">Duplicate</a></div>
        <div class="item"><a rel="screenshots" href="/get_image/10/def/sources/3000/3948/2652885.webp/">Two</a></div>
        <div class="item"><a rel="screenshots" href="/contents/albums/main/200x150/3000/3948/2652886.jpg">Thumbnail</a></div>
        """
        XCTAssertEqual(XFetishAlbums.parseImages(Data(html.utf8), albumID: "3948").map(\.id),
                       ["2652884", "2652885"])
    }

    func testEmptyAdditionalPageEndsGalleryAfterInitialImages() throws {
        // The public album 6264 advertises one extra page after showing all 9
        // photos; that request returns HTTP 200 with a zero-byte body.
        XCTAssertNil(try XFetishAlbums.parseExtraImages(Data(), albumID: "6264", hasEarlierImages: true))
    }

    func testEmptyAdditionalPageCannotHideAnEmptyGallery() {
        XCTAssertThrowsError(try XFetishAlbums.parseExtraImages(Data(), albumID: "6264", hasEarlierImages: false))
        XCTAssertThrowsError(try XFetishAlbums.parseExtraImages(Data("<html>blocked</html>".utf8),
                                                              albumID: "6264", hasEarlierImages: true))
    }

    func testAdditionalPageKeepsOriginalImageLinks() throws {
        let fragment = Data("<a rel=\"screenshots\" href=\"/get_image/10/abc/sources/3000/3948/2652885.jpg/\">Two</a>".utf8)
        XCTAssertEqual(try XFetishAlbums.parseExtraImages(fragment, albumID: "3948", hasEarlierImages: true)?.map(\.id),
                       ["2652885"])
    }

    func testMalformedPagesAreNotTreatedAsEmptyAlbums() {
        let album = XFetishAlbums.Album(id: "3948", title: "Example", url: URL(string: "https://x-fetish.tube/albums/3948/example/")!)
        XCTAssertThrowsError(try XFetishAlbums.parseListing(Data("<html>blocked</html>".utf8), model: "example", page: 1))
        XCTAssertThrowsError(try XFetishAlbums.parseGallery(Data("<html>blocked</html>".utf8), album: album))
    }

    func testAPIHeadersUseAlbumRefererAndBrowserAccept() {
        let album = URL(string: "https://x-fetish.tube/albums/3948/example/")!
        let headers = XFetishAPI.headers(referer: album)
        XCTAssertEqual(headers["Referer"], album.absoluteString)
        XCTAssertEqual(headers["Origin"], "https://x-fetish.tube")
        XCTAssertTrue(headers["Accept"]?.contains("image/") == true)
        let videoHeaders = XFetishAPI.headers(referer: album, accept: XFetishAPI.videoAccept)
        XCTAssertEqual(videoHeaders["Accept"], XFetishAPI.videoAccept)
        XCTAssertTrue(XFetishAPI.videoAccept.hasPrefix("video/"))
        XCTAssertEqual(videoHeaders["Referer"], album.absoluteString)
        XCTAssertTrue(XFetishAPI.userAgent.contains("Safari"))
        XCTAssertTrue(XFetishAPI.isXFetish(album))
        XCTAssertTrue(XFetishAPI.isXFetish(URL(string: "https://storage4.x-fetish.tube/remote_control.php?file=a.jpg&acctoken=b")!))
        XCTAssertFalse(XFetishAPI.isXFetish(URL(string: "https://www.reddit.com/")!))
        let defaults = XFetishAPI.headers()
        XCTAssertEqual(defaults["Referer"], "https://x-fetish.tube/")
    }

    func testStorageRedirectKeepsQueryForNonCredentialHosts() {
        let source = URL(string: "https://x-fetish.tube/get_image/10/abc/sources/3000/3948/2652884.jpg/?i-acctoken=tok123")!
        let destination = URL(string: "https://storage4.x-fetish.tube/remote_control.php?file=abc.jpg&acctoken=tok456")!
        let followed = SavedFeed.redirectURL(from: source, to: destination)
        XCTAssertEqual(followed?.absoluteString, destination.absoluteString)
        XCTAssertTrue(followed?.query?.contains("acctoken=tok456") == true)
    }

    func testIPv4StorageRejectsNonSignedRoute() async {
        let url = URL(string: "https://x-fetish.tube/albums/1/a/")!
        XCTAssertFalse(XFetishIPv4.isSignedMediaRoute(url))
        do {
            _ = try await XFetishIPv4.storageURL(for: url, userAgent: "t", referer: "r")
            XCTFail("should reject non-signed route")
        } catch {
            XCTAssertTrue(error is XFetishIPv4Error)
        }
    }

    func testIPv4StorageAcceptsImageAndVideoSignedRoutes() {
        XCTAssertTrue(XFetishIPv4.isSignedMediaRoute(
            URL(string: "https://x-fetish.tube/get_image/10/abc/sources/3000/3948/2652884.jpg/?i-acctoken=t")!))
        XCTAssertTrue(XFetishIPv4.isSignedMediaRoute(
            URL(string: "https://x-fetish.tube/get_file/11/abcdef01/708000/708259/708259_single_hd_vertical.mp4/?v-acctoken=t")!))
        XCTAssertFalse(XFetishIPv4.isSignedMediaRoute(
            URL(string: "https://x-fetish.tube/contents/videos_screenshots/708000/708259/preview.jpg")!))
        XCTAssertFalse(XFetishIPv4.isSignedMediaRoute(
            URL(string: "https://storage4.x-fetish.tube/remote_control.php?file=a.mp4&acctoken=b")!))
    }

    func testIPv4RedirectPreservesSignedLocation() throws {
        let source = URL(string: "https://x-fetish.tube/get_image/10/example/")!
        let destination = "https://storage4.x-fetish.tube/remote_control.php?file=a%2Fb.jpg&acctoken=test%2Btoken"
        let headers = Data("HTTP/1.1 302 Found\r\nlOcAtIoN: \(destination)\r\nContent-Length: 0".utf8)
        XCTAssertEqual(try XFetishIPv4.redirectURL(headerData: headers, from: source).absoluteString, destination)
        let relative = Data("HTTP/1.0 307 Temporary Redirect\r\nLocation: /next?acctoken=test".utf8)
        XCTAssertEqual(try XFetishIPv4.redirectURL(headerData: relative, from: source).absoluteString,
                       "https://x-fetish.tube/next?acctoken=test")
    }

    func testIPv4UnexpectedStatusIsReportedWithoutServerSecrets() {
        let source = URL(string: "https://x-fetish.tube/get_image/10/example/?token=source-secret")!
        for code in [103, 200, 403, 429, 503] {
            let headers = Data("HTTP/1.1 \(code) reason-secret\r\nLocation: https://storage4.x-fetish.tube/?acctoken=location-secret".utf8)
            XCTAssertThrowsError(try XFetishIPv4.redirectURL(headerData: headers, from: source)) { error in
                guard case XFetishIPv4Error.unexpectedStatus(let received) = error else {
                    return XCTFail("Expected an explicit HTTP status, got \(type(of: error))")
                }
                XCTAssertEqual(received, code)
                XCTAssertTrue(error.localizedDescription.contains("\(code)"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testIPv4MissingLocationIsDistinctFromMalformedResponse() {
        let source = URL(string: "https://x-fetish.tube/get_image/10/example/")!
        for headers in ["HTTP/1.1 302 Found", "HTTP/1.1 302 Found\r\nLocation: "] {
            XCTAssertThrowsError(try XFetishIPv4.redirectURL(headerData: Data(headers.utf8), from: source)) { error in
                guard case XFetishIPv4Error.missingLocation(302) = error else {
                    return XCTFail("Expected missing Location")
                }
            }
        }
        for headers in ["", "not-http 302 Found\r\nLocation: /next", "HTTP/1.1 invalid"] {
            XCTAssertThrowsError(try XFetishIPv4.redirectURL(headerData: Data(headers.utf8), from: source)) { error in
                guard case XFetishIPv4Error.invalidResponse = error else {
                    return XCTFail("Expected malformed response")
                }
            }
        }
    }

    func testIPv4NonHTTPSLocationIsRejectedWithoutTokenDisclosure() {
        let source = URL(string: "https://x-fetish.tube/get_image/10/example/")!
        let headers = Data("HTTP/1.1 302 Found\r\nLocation: http://storage4.x-fetish.tube/?acctoken=private-token".utf8)
        XCTAssertThrowsError(try XFetishIPv4.redirectURL(headerData: headers, from: source)) { error in
            guard case XFetishIPv4Error.invalidLocation = error else {
                return XCTFail("Expected invalid Location")
            }
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }
}

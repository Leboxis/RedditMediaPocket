import XCTest
@testable import MediaCore

final class XFetishAlbumsTests: XCTestCase {
    func testSourceButtonCyclesThroughAllFourKinds() {
        XCTAssertEqual(SourceKind.user.next, .subreddit)
        XCTAssertEqual(SourceKind.subreddit.next, .saved)
        XCTAssertEqual(SourceKind.saved.next, .xFetish)
        XCTAssertEqual(SourceKind.xFetish.next, .user)
    }

    func testExistingImageIDSurvivesAlbumRename() {
        let oldName = "Original title - xf-3948-2652884.jpg"
        let newName = "Renamed album - xf-3948-2652884.jpg"
        XCTAssertEqual(FilenamePolicy.xFetishImageID(inFileName: oldName), "xf-3948-2652884")
        XCTAssertEqual(FilenamePolicy.xFetishImageID(inFileName: newName),
                       FilenamePolicy.xFetishImageID(inFileName: oldName))
        XCTAssertNil(FilenamePolicy.xFetishImageID(inFileName: "Other - xf-3948-2652884.mp4"))
        XCTAssertNil(FilenamePolicy.xFetishImageID(inFileName: "Other - xf-3948-abc.jpg"))
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
}

import XCTest
@testable import MediaCore

final class RedgifsUserTests: XCTestCase {
    func testRedgifsUsernameValidation() throws {
        XCTAssertEqual(try RedgifsAPI.username("upset_trash_3094"), "upset_trash_3094")
        XCTAssertEqual(try RedgifsAPI.username(" RG/Upset_Trash-3094 "), "Upset_Trash-3094")
        XCTAssertThrowsError(try RedgifsAPI.username("ab"))
        XCTAssertThrowsError(try RedgifsAPI.username("a/b"))
        XCTAssertThrowsError(try RedgifsAPI.username(""))
    }

    func testUserSearchURL() throws {
        let url = RedgifsAPI.userSearchURL(username: "Upset_Trash_3094", page: 1, count: 80)
        XCTAssertEqual(
            url.absoluteString,
            "https://api.redgifs.com/v2/users/upset_trash_3094/search?order=new&page=1&count=80"
        )
        let page2 = RedgifsAPI.userSearchURL(username: "upset_trash_3094", page: 2, count: 80)
        XCTAssertTrue(page2.absoluteString.contains("page=2"))
    }

    func testUserSearchResponseParsing() throws {
        let json = """
        {"gifs":[{"id":"DelectableIncompleteShorebird","userName":"upset_trash_3094","urls":{"hd":"https://media.redgifs.com/DelectableIncompleteShorebird.mp4","sd":"https://media.redgifs.com/DelectableIncompleteShorebird-mobile.mp4"}}],"page":1,"pages":2,"total":158}
        """
        let response = try JSONDecoder().decode(RedgifsUserSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.page, 1)
        XCTAssertEqual(response.pages, 2)
        XCTAssertEqual(response.total, 158)
        XCTAssertEqual(response.gifs.count, 1)
        XCTAssertEqual(response.gifs[0].id, "DelectableIncompleteShorebird")
        XCTAssertEqual(response.gifs[0].urls.hd?.absoluteString, "https://media.redgifs.com/DelectableIncompleteShorebird.mp4")
        XCTAssertEqual(response.gifs[0].urls.sd?.absoluteString, "https://media.redgifs.com/DelectableIncompleteShorebird-mobile.mp4")
    }

    func testParseRedgifsForms() throws {
        XCTAssertEqual(try FeedSource.parse("rg/upset_trash_3094"), .redgifsUser("upset_trash_3094"))
        XCTAssertEqual(try FeedSource.parse(" RG/Upset_Trash-3094 "), .redgifsUser("Upset_Trash-3094"))
        XCTAssertEqual(try FeedSource.parse("g/upset_trash_3094"), .redgifsUser("upset_trash_3094"))
        XCTAssertEqual(
            try FeedSource.parse("https://www.redgifs.com/users/upset_trash_3094"),
            .redgifsUser("upset_trash_3094")
        )
    }

    func testRedgifsMapping() {
        XCTAssertEqual(FeedSource.redgifsUser("upset_trash_3094").id, "rg/upset_trash_3094")
        XCTAssertEqual(FeedSource.redgifsUser("upset_trash_3094").folderName, "redgifs.upset_trash_3094")
        XCTAssertEqual(FeedSource.redgifsUser("upset_trash_3094").displayName, "rg/upset_trash_3094")
    }

    func testKDriveFolderNameForRedgifs() {
        XCTAssertEqual(FilenamePolicy.kDriveFolderName("rg/upset_trash_3094"), "Rgupset_trash_3094")
    }
}

import XCTest
@testable import RedditMediaPocket

final class FollowingSortTests: XCTestCase {
    func testDefaultOrderIsKDriveFirst() {
        XCTAssertEqual(FollowingSortOrder.defaultOrder, .kDriveFirst)
    }

    func testKDriveFirstPlacesPresentAccountsBeforeOthersAlphabetically() {
        let accounts = ["zara", "Alpha", "charlie", "beta", "delta"]
        let onKDrive: Set<String> = ["zara", "charlie"]

        let result = FollowingSortOrder.kDriveFirst.sorted(accounts) { onKDrive.contains($0) }

        XCTAssertEqual(result, ["charlie", "zara", "Alpha", "beta", "delta"])
    }

    func testAlphabeticalIgnoresKDrivePresenceAndIsCaseInsensitive() {
        let accounts = ["zara", "Alpha", "charlie", "beta"]
        let onKDrive: Set<String> = ["zara"]

        let result = FollowingSortOrder.alphabetical.sorted(accounts) { onKDrive.contains($0) }

        XCTAssertEqual(result, ["Alpha", "beta", "charlie", "zara"])
    }

    func testKDriveFirstWithNoMatchesFallsBackToAlphabetical() {
        let accounts = ["charlie", "alpha", "beta"]

        let result = FollowingSortOrder.kDriveFirst.sorted(accounts) { _ in false }

        XCTAssertEqual(result, ["alpha", "beta", "charlie"])
    }

    func testKDriveFirstWithAllMatchesSortsAlphabetically() {
        let accounts = ["charlie", "alpha", "beta"]

        let result = FollowingSortOrder.kDriveFirst.sorted(accounts) { _ in true }

        XCTAssertEqual(result, ["alpha", "beta", "charlie"])
    }
}

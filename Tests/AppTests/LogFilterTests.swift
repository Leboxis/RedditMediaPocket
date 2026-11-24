import XCTest
@testable import RedditMediaPocket

final class LogFilterTests: XCTestCase {
    private let sampleEntries: [LogEntry] = [
        LogEntry(date: Date(timeIntervalSince1970: 1_000), level: .info, message: "Journal démarré."),
        LogEntry(date: Date(timeIntervalSince1970: 2_000), level: .reseau, message: "Requête Reddit u/alice"),
        LogEntry(date: Date(timeIntervalSince1970: 3_000), level: .kdrive, message: "Upload terminé pour alice"),
        LogEntry(date: Date(timeIntervalSince1970: 4_000), level: .erreur, message: "kDrive : erreur HTTP 429")
    ]

    func testFilterEntriesChronologicalAndNewestFirst() {
        let asc = LogCenter.filterEntries(sampleEntries, level: nil, search: "", newestFirst: false)
        XCTAssertEqual(asc.map(\.level), [.info, .reseau, .kdrive, .erreur])

        let desc = LogCenter.filterEntries(sampleEntries, level: nil, search: "", newestFirst: true)
        XCTAssertEqual(desc.map(\.level), [.erreur, .kdrive, .reseau, .info])
    }

    func testFilterEntriesByLevelAndCaseInsensitiveSearch() {
        let alice = LogCenter.filterEntries(sampleEntries, level: nil, search: "ALICE", newestFirst: true)
        XCTAssertEqual(alice.map(\.level), [.kdrive, .reseau])

        let kdriveOnly = LogCenter.filterEntries(sampleEntries, level: .kdrive, search: "alice", newestFirst: false)
        XCTAssertEqual(kdriveOnly.count, 1)
        XCTAssertEqual(kdriveOnly.first?.message, "Upload terminé pour alice")
    }

    func testCountEntriesTracksPerLevelTotalsAndRespectsSearch() {
        let allCounts = LogCenter.countEntries(sampleEntries, search: "")
        XCTAssertEqual(allCounts.total, 4)
        XCTAssertEqual(allCounts.count(for: .info), 1)
        XCTAssertEqual(allCounts.count(for: .reseau), 1)
        XCTAssertEqual(allCounts.count(for: .kdrive), 1)
        XCTAssertEqual(allCounts.count(for: .erreur), 1)

        let searchCounts = LogCenter.countEntries(sampleEntries, search: "kdrive")
        XCTAssertEqual(searchCounts.total, 1)
        XCTAssertEqual(searchCounts.count(for: .erreur), 1)
        XCTAssertEqual(searchCounts.count(for: .kdrive), 0)
    }
}

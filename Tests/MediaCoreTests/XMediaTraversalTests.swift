import XCTest
@testable import MediaCore

final class XMediaTraversalTests: XCTestCase {
    /// `process` renvoie `true` quand la page a apporté du nouveau. Les tests
    /// qui portent sur le budget de pages le déclarent toujours vrai : ils
    /// vérifient le curseur, pas la détection de nouveauté.
    private func alwaysNew(_ page: XMediaPage) -> (String?) -> XMediaPage { { _ in page } }

    @MainActor func testCappedScanContinuesPastBudgetAndThenRestartsAtHead() async throws {
        var cursor: String?
        var requests: [String?] = []
        let fetch: (String?) async throws -> XMediaPage = { after in
            requests.append(after)
            return XMediaPage(posts: [], nextCursor: after == nil ? "older" : nil)
        }
        let capped = try await XMediaTraversal.run(cursor: cursor, maximumPages: 1,
            fetch: fetch, process: { _ in true }, persist: { cursor = $0 })
        XCTAssertFalse(capped)
        XCTAssertEqual(cursor, "older")
        let completed = try await XMediaTraversal.run(cursor: cursor,
            fetch: fetch, process: { _ in true }, persist: { cursor = $0 })
        XCTAssertTrue(completed)
        XCTAssertNil(cursor)
        _ = try await XMediaTraversal.run(cursor: cursor, maximumPages: 1,
            fetch: fetch, process: { _ in true }, persist: { cursor = $0 })
        XCTAssertEqual(requests, [nil, "older", nil])
    }

    @MainActor func testFailedPageDoesNotAdvanceCursor() async throws {
        var cursor: String? = "pending"
        do {
            _ = try await XMediaTraversal.run(cursor: cursor,
                fetch: { _ in XMediaPage(posts: [], nextCursor: "next") },
                process: { _ in throw NetworkError.refused(503) }, persist: { cursor = $0 })
            XCTFail("Expected failure")
        } catch NetworkError.refused { }
        XCTAssertEqual(cursor, "pending")
    }

    @MainActor func testCancelledPageDoesNotAdvanceCursor() async throws {
        var cursor: String? = "pending"
        do {
            _ = try await XMediaTraversal.run(cursor: cursor,
                fetch: { _ in XMediaPage(posts: [], nextCursor: "next") },
                process: { _ in throw CancellationError() }, persist: { cursor = $0 })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(cursor, "pending")
    }

    @MainActor func testCursorCycleIsRejected() async throws {
        do {
            _ = try await XMediaTraversal.run(cursor: "loop",
                fetch: { _ in XMediaPage(posts: [], nextCursor: "loop") },
                process: { _ in true }, persist: { _ in XCTFail("Do not commit a cycle") })
            XCTFail("Expected invalid timeline")
        } catch XTwitterError.invalidTimeline { }
    }

    /// Previously `precondition`: it killed the process, release builds
    /// included, instead of throwing an error the caller can handle.
    @MainActor func testNonPositivePageLimitThrowsInsteadOfTrapping() async {
        for limit in [0, -1] {
            do {
                _ = try await XMediaTraversal.run(cursor: nil, maximumPages: limit,
                    fetch: { _ in XMediaPage(posts: [], nextCursor: nil) },
                    process: { _ in XCTFail("Do not fetch with an invalid limit"); return true },
                    persist: { _ in })
                XCTFail("Expected invalid page limit")
            } catch XTwitterError.invalidPageLimit {
                XCTAssertFalse(limit > 0)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Caught-up detection

    /// Un compte déjà archivé ne doit pas être relu page par page : deux pages
    /// consécutives sans aucun média nouveau signifient qu'on a rattrapé
    /// l'historique. Le parcours est alors complet et le curseur effacé.
    @MainActor func testStopsAfterTwoConsecutiveIdlePages() async throws {
        var fetched = 0
        var cursor: String? = "head"
        let completed = try await XMediaTraversal.run(cursor: cursor, fetch: { _ in
            fetched += 1
            return XMediaPage(posts: [], nextCursor: "p\(fetched)")
        }, process: { _ in
            // Seules les deux premières pages apportent du nouveau.
            fetched <= 2
        }, persist: { cursor = $0 })

        XCTAssertTrue(completed)
        XCTAssertEqual(fetched, 4, "Doit s'arrêter après 2 pages vides, pas relire tout le fil")
        XCTAssertNil(cursor, "Un parcours rattrapé n'a pas de curseur à conserver")
    }

    /// Une page isolée sans nouveau média ne suffit pas : X répète parfois un
    /// post d'une page à l'autre, et s'arrêter là ferait manquer la suite.
    @MainActor func testSingleIdlePageDoesNotStopTheScan() async throws {
        var fetched = 0
        let completed = try await XMediaTraversal.run(cursor: "head", fetch: { _ in
            fetched += 1
            return XMediaPage(posts: [], nextCursor: fetched < 5 ? "p\(fetched)" : nil)
        }, process: { _ in
            // La page 2 est vide, la page 3 apporte du nouveau : le compteur
            // doit se réarmer et le parcours doit continuer jusqu'à la fin.
            fetched != 2
        }, persist: { _ in })

        XCTAssertTrue(completed)
        XCTAssertEqual(fetched, 5, "Doit atteindre la fin réelle du fil")
    }

    /// Un média en échec reste « nouveau » tant qu'il n'est pas sur le disque :
    /// sa page relance donc le compteur, ce qui évite de l'abandonner.
    @MainActor func testPageWithPendingMediaKeepsTheScanAlive() async throws {
        var fetched = 0
        var attempts = 0
        let completed = try await XMediaTraversal.run(cursor: "head", fetch: { _ in
            fetched += 1
            return XMediaPage(posts: [], nextCursor: fetched < 6 ? "p\(fetched)" : nil)
        }, process: { _ in
            // Les pages 2 et 4 gardent un média en attente : rien après elles ne
            // doit être considéré comme du contenu nouveau.
            if fetched == 2 || fetched == 4 {
                attempts += 1
                return true
            }
            return false
        }, persist: { _ in })

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(completed)
        XCTAssertEqual(fetched, 6, "p3 et p5 vides ne suffisent pas : le compteur repart à chaque pending")
    }

    /// Le budget de pages reste prioritaire sur la détection de nouveauté : un
    /// fil jamais rattrapé doit continuer à s'arrêter à 100 pages et à conserver
    /// son curseur, pour reprendre au bon endroit au lancement suivant.
    @MainActor func testPageBudgetStillWinsOnANeverEndingFeed() async throws {
        var fetched = 0
        var cursor: String?
        let completed = try await XMediaTraversal.run(cursor: nil, maximumPages: 3,
            fetch: { _ in fetched += 1; return XMediaPage(posts: [], nextCursor: "p\(fetched)") },
            process: { _ in true }, persist: { cursor = $0 })

        XCTAssertFalse(completed, "Un fil jamais rattrapé doit rester incomplet")
        XCTAssertEqual(fetched, 3)
        XCTAssertEqual(cursor, "p3", "Le curseur doit être conservé pour reprendre")
    }
}
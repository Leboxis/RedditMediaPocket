import XCTest
@testable import RedditMediaPocket

final class PocketSnapshotTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PocketSnapshotTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testCaptureEtRestaurationDesSuivisEtStatuts() throws {
        let telechargement = Date(timeIntervalSince1970: 1_760_000_000)
        let upload = Date(timeIntervalSince1970: 1_760_003_600)

        SuiviStore.enregistrerListe(["Alice", "Bob", "alice", "  ", "Charlie"], defaults: defaults, notifier: false)
        SuiviStore.enregistrer(
            ["alice": CompteSuiviEtat(marque: false, dernierTelechargement: telechargement, dernierUpload: upload)],
            defaults: defaults,
            notifier: false
        )
        let marquesData = try JSONEncoder().encode(["alice", "bob"])
        defaults.set(marquesData, forKey: SuiviStore.cleMarques)

        let capture = PocketSnapshot.capturer(defaults: defaults)
        XCTAssertEqual(capture.suivis, ["Alice", "Bob", "Charlie"])
        XCTAssertEqual(capture.comptes["alice"]?.marque, true)
        XCTAssertEqual(capture.comptes["alice"]?.dernierTelechargement, telechargement)
        XCTAssertEqual(capture.comptes["alice"]?.dernierUpload, upload)
        XCTAssertEqual(capture.comptes["bob"]?.marque, true)
        XCTAssertNil(capture.comptes["charlie"])

        // Restauration dans un stockage vierge (simulation après réinstallation sans session Reddit).
        let cibleSuite = "PocketSnapshotTests.cible.\(UUID().uuidString)"
        let cible = UserDefaults(suiteName: cibleSuite)!
        defer { cible.removePersistentDomain(forName: cibleSuite) }

        let octets = try XCTUnwrap(capture.jsonValue?.donneesJSON())
        let restaure = try JSONDecoder().decode(PocketSnapshot.self, from: octets)
        restaure.appliquer(defaults: cible)

        XCTAssertEqual(SuiviStore.pseudosConnus(defaults: cible), ["Alice", "Bob", "Charlie"])
        let etatsRestaures = SuiviStore.charger(defaults: cible)
        XCTAssertEqual(etatsRestaures["alice"]?.marque, true)
        XCTAssertEqual(etatsRestaures["alice"]?.dernierTelechargement, telechargement)
        XCTAssertEqual(etatsRestaures["alice"]?.dernierUpload, upload)
        let marquesRestaurees = try JSONDecoder().decode(
            [String].self,
            from: XCTUnwrap(cible.data(forKey: SuiviStore.cleMarques))
        )
        XCTAssertEqual(marquesRestaurees, ["alice", "bob"])
    }

    @MainActor
    func testCompatibiliteAncienneSauvegardeSansListeSuivis() throws {
        let ancienJSON = #"{"comptes":{"alice":{"marque":true},"zoe":{"marque":false}}}"#.data(using: .utf8)!
        let copie = try JSONDecoder().decode(PocketSnapshot.self, from: ancienJSON)

        XCTAssertTrue(copie.suivis.isEmpty)
        copie.appliquer(defaults: defaults)

        // Sans liste explicite, on retrouve quand même les comptes présents dans les statuts.
        XCTAssertEqual(SuiviStore.pseudosConnus(defaults: defaults), ["alice", "zoe"])
    }
}

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
        XCTAssertTrue(copie.suivisX.isEmpty)
        XCTAssertTrue(copie.comptesX.isEmpty)
        copie.appliquer(defaults: defaults)

        // Sans liste explicite, on retrouve quand même les comptes présents dans les statuts.
        XCTAssertEqual(SuiviStore.pseudosConnus(defaults: defaults), ["alice", "zoe"])
    }

    @MainActor
    func testSuivisXManuelsStatutsEtSynchronisation() throws {
        let telechargement = Date(timeIntervalSince1970: 1_760_010_000)
        let upload = Date(timeIntervalSince1970: 1_760_013_600)

        let ajoute1 = try SuiviStore.ajouterSuiviX("@Alice_X", defaults: defaults, notifier: false)
        let ajoute2 = try SuiviStore.ajouterSuiviX("https://x.com/BobX/media", defaults: defaults, notifier: false)
        // Doublon insensible à la casse ignoré.
        _ = try SuiviStore.ajouterSuiviX("alice_x", defaults: defaults, notifier: false)
        XCTAssertEqual(ajoute1, "Alice_X")
        XCTAssertEqual(ajoute2, "BobX")
        XCTAssertEqual(SuiviStore.chargerListe(plateforme: .x, defaults: defaults), ["Alice_X", "BobX"])

        XCTAssertThrowsError(try SuiviStore.ajouterSuiviX("pseudo invalide !", defaults: defaults, notifier: false))

        SuiviStore.enregistrer(
            ["alice_x": CompteSuiviEtat(marque: false, dernierTelechargement: telechargement, dernierUpload: upload)],
            plateforme: .x,
            defaults: defaults,
            notifier: false
        )
        SuiviStore.enregistrerMarques(["alice_x"], plateforme: .x, defaults: defaults, notifier: false)

        // Vérifie la reconnaissance des collections Reddit et X pour les uploads kDrive.
        let idReddit = SuiviStore.identifiantCollection("u/Alice")
        XCTAssertEqual(idReddit?.plateforme, .reddit)
        XCTAssertEqual(idReddit?.pseudo, "alice")
        let idX = SuiviStore.identifiantCollection("tw/Alice_X")
        XCTAssertEqual(idX?.plateforme, .x)
        XCTAssertEqual(idX?.pseudo, "alice_x")
        XCTAssertNil(SuiviStore.identifiantCollection("r/swift"))

        // Round-trip complet vers un stockage vierge.
        let capture = PocketSnapshot.capturer(defaults: defaults)
        XCTAssertEqual(capture.suivisX, ["Alice_X", "BobX"])
        XCTAssertEqual(capture.comptesX["alice_x"]?.marque, true)
        XCTAssertEqual(capture.comptesX["alice_x"]?.dernierTelechargement, telechargement)
        XCTAssertEqual(capture.comptesX["alice_x"]?.dernierUpload, upload)

        let cibleSuite = "PocketSnapshotTests.x.\(UUID().uuidString)"
        let cible = UserDefaults(suiteName: cibleSuite)!
        defer { cible.removePersistentDomain(forName: cibleSuite) }

        let octets = try XCTUnwrap(capture.jsonValue?.donneesJSON())
        let restaure = try JSONDecoder().decode(PocketSnapshot.self, from: octets)
        restaure.appliquer(defaults: cible)

        XCTAssertEqual(SuiviStore.pseudosConnus(plateforme: .x, defaults: cible), ["Alice_X", "BobX"])
        let etatsX = SuiviStore.charger(plateforme: .x, defaults: cible)
        XCTAssertEqual(etatsX["alice_x"]?.marque, true)
        XCTAssertEqual(etatsX["alice_x"]?.dernierTelechargement, telechargement)
        XCTAssertEqual(etatsX["alice_x"]?.dernierUpload, upload)
        XCTAssertEqual(SuiviStore.chargerMarques(plateforme: .x, defaults: cible), ["alice_x"])

        SuiviStore.supprimerSuiviX("bobx", defaults: cible, notifier: false)
        XCTAssertEqual(SuiviStore.chargerListe(plateforme: .x, defaults: cible), ["Alice_X"])
    }

    @MainActor
    func testSuivisTikTokManuelsStatutsEtSynchronisation() throws {
        let telechargement = Date(timeIntervalSince1970: 1_760_020_000)
        let upload = Date(timeIntervalSince1970: 1_760_023_600)

        let ajoute1 = try SuiviStore.ajouterSuiviTikTok("@Alice.TT", defaults: defaults, notifier: false)
        let ajoute2 = try SuiviStore.ajouterSuiviTikTok("https://www.tiktok.com/@Bob_TT?lang=fr", defaults: defaults, notifier: false)
        // Doublon insensible à la casse ignoré.
        _ = try SuiviStore.ajouterSuiviTikTok("alice.tt", defaults: defaults, notifier: false)
        XCTAssertEqual(ajoute1, "Alice.TT")
        XCTAssertEqual(ajoute2, "Bob_TT")
        XCTAssertEqual(SuiviStore.chargerListe(plateforme: .tiktok, defaults: defaults), ["Alice.TT", "Bob_TT"])

        XCTAssertThrowsError(try SuiviStore.ajouterSuiviTikTok("pseudo invalide !", defaults: defaults, notifier: false))

        SuiviStore.enregistrer(
            ["alice.tt": CompteSuiviEtat(marque: false, dernierTelechargement: telechargement, dernierUpload: upload)],
            plateforme: .tiktok,
            defaults: defaults,
            notifier: false
        )
        SuiviStore.enregistrerMarques(["alice.tt"], plateforme: .tiktok, defaults: defaults, notifier: false)

        let idTikTok = SuiviStore.identifiantCollection("tt/Alice.TT")
        XCTAssertEqual(idTikTok?.plateforme, .tiktok)
        XCTAssertEqual(idTikTok?.pseudo, "alice.tt")

        let capture = PocketSnapshot.capturer(defaults: defaults)
        XCTAssertEqual(capture.suivisTikTok, ["Alice.TT", "Bob_TT"])
        XCTAssertEqual(capture.comptesTikTok["alice.tt"]?.marque, true)
        XCTAssertEqual(capture.comptesTikTok["alice.tt"]?.dernierTelechargement, telechargement)
        XCTAssertEqual(capture.comptesTikTok["alice.tt"]?.dernierUpload, upload)

        let cibleSuite = "PocketSnapshotTests.tiktok.\(UUID().uuidString)"
        let cible = UserDefaults(suiteName: cibleSuite)!
        defer { cible.removePersistentDomain(forName: cibleSuite) }

        let octets = try XCTUnwrap(capture.jsonValue?.donneesJSON())
        let restaure = try JSONDecoder().decode(PocketSnapshot.self, from: octets)
        restaure.appliquer(defaults: cible)

        XCTAssertEqual(SuiviStore.pseudosConnus(plateforme: .tiktok, defaults: cible), ["Alice.TT", "Bob_TT"])
        let etatsTT = SuiviStore.charger(plateforme: .tiktok, defaults: cible)
        XCTAssertEqual(etatsTT["alice.tt"]?.marque, true)
        XCTAssertEqual(etatsTT["alice.tt"]?.dernierTelechargement, telechargement)
        XCTAssertEqual(etatsTT["alice.tt"]?.dernierUpload, upload)
        XCTAssertEqual(SuiviStore.chargerMarques(plateforme: .tiktok, defaults: cible), ["alice.tt"])

        SuiviStore.supprimerSuiviTikTok("bob_tt", defaults: cible, notifier: false)
        XCTAssertEqual(SuiviStore.chargerListe(plateforme: .tiktok, defaults: cible), ["Alice.TT"])
    }
}

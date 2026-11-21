import Foundation
import MediaCore

/// Notification envoyée quand un journal change, pour déclencher la synchronisation.
extension Notification.Name {
    static let pocketDonneesDidChange = Notification.Name("pocketDonneesDidChange")
}

/// Une ligne du journal de bord telle qu'elle est envoyée au serveur.
struct LigneJournal: Codable, Sendable {
    var date: String
    var niveau: String
    var message: String
}

/// Copie de toutes les données non secrètes de l'app, envoyée et restaurée en un seul élément.
struct PocketSnapshot: Codable {
    var collections: [UserCollection]
    /// Clés de réglages autorisées : aucun token, cookie ou mot de passe n'est inclus.
    var reglages: [String: JSONValue]
    var comptesSuivis: [String]
    var logs: [LigneJournal]
    var echecs: [FailureEntry]

    /// Clés UserDefaults synchronisées (liste fermée, volontairement exhaustive mais sûre).
    private static let clesReglages = [
        "appLanguage", "concurrentLimit", "xFetishDownloadSegments", "sourceKind",
        "subSort", "xFetishMediaKind", "storageQuotaBytes", "gallerySort", "lastUsername",
    ]

    /// Construit la copie à partir de l'état local.
    @MainActor static func capturer() -> PocketSnapshot {
        let defauts = UserDefaults.standard

        var reglages: [String: JSONValue] = [:]
        for cle in clesReglages {
            guard let objet = defauts.object(forKey: cle),
                  let valeur = JSONValue.depuis(objet) else { continue }
            reglages[cle] = valeur
        }

        let donneesCollections = defauts.data(forKey: "collections") ?? Data()
        let collections = (try? JSONDecoder().decode([UserCollection].self, from: donneesCollections)) ?? []

        let donneesComptes = defauts.data(forKey: "following.downloadedUsernames") ?? Data()
        let comptes = (try? JSONDecoder().decode([String].self, from: donneesComptes)) ?? []

        let formateur = ISO8601DateFormatter()
        let logs = LogCenter.shared.entries.suffix(500).map { entree in
            LigneJournal(
                date: formateur.string(from: entree.date),
                niveau: entree.level.rawValue,
                message: entree.message
            )
        }

        // Les en-têtes peuvent contenir des données d'authentification : on ne les synchronise pas.
        let echecs = FailureJournal.shared.entries.suffix(500).map { entree -> FailureEntry in
            var copie = entree
            copie.headers = nil
            return copie
        }

        return PocketSnapshot(
            collections: collections,
            reglages: reglages,
            comptesSuivis: comptes,
            logs: Array(logs),
            echecs: Array(echecs)
        )
    }

    /// Applique la copie distante à l'app (appelée après une réinstallation).
    @MainActor func appliquer() {
        let defauts = UserDefaults.standard

        if let donnees = try? JSONEncoder().encode(collections) {
            defauts.set(donnees, forKey: "collections")
        }
        for (cle, valeur) in reglages {
            guard let fondamentale = valeur.valeurFondamentale else { continue }
            if fondamentale is NSNull { defauts.removeObject(forKey: cle) }
            else { defauts.set(fondamentale, forKey: cle) }
        }
        if let donnees = try? JSONEncoder().encode(comptesSuivis.sorted()) {
            defauts.set(donnees, forKey: "following.downloadedUsernames")
        }

        LogCenter.shared.restaurer(lignes: logs)
        FailureJournal.shared.clear()
        for entree in echecs { FailureJournal.shared.record(entree) }
    }

    /// Représentation JSON pour le champ `data` de l'élément envoyé au serveur.
    var jsonValue: JSONValue? {
        guard let donnees = try? JSONEncoder().encode(self),
              let objet = try? JSONSerialization.jsonObject(with: donnees) else { return nil }
        return JSONValue.depuis(objet)
    }
}

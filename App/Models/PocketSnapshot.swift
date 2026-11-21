import Foundation
import MediaCore

extension Notification.Name {
    static let pocketDonneesDidChange = Notification.Name("pocketDonneesDidChange")
    /// Envoyée quand une copie distante vient d'être appliquée, pour recharger l'interface.
    static let pocketDonneesRestaurees = Notification.Name("pocketDonneesRestaurees")
}

/// État d'un compte Reddit suivi, tel qu'il est gardé sur le serveur.
struct CompteSuiviEtat: Codable, Sendable, Equatable {
    /// Vrai quand l'utilisateur a validé la petite coche « déjà téléchargé ».
    var marque: Bool = false
    /// Fin du dernier parcours « Tout télécharger » réussi.
    var dernierTelechargement: Date?
    /// Fin du dernier envoi kDrive réussi.
    var dernierUpload: Date?
}

/// Stockage local des états de suivi, séparé de la liste des pseudos marqués.
enum SuiviStore {
    static let cle = "following.etats"

    static func charger() -> [String: CompteSuiviEtat] {
        guard let donnees = UserDefaults.standard.data(forKey: cle),
              let etats = try? JSONDecoder().decode([String: CompteSuiviEtat].self, from: donnees) else {
            return [:]
        }
        return etats
    }

    static func enregistrer(_ etats: [String: CompteSuiviEtat]) {
        guard let donnees = try? JSONEncoder().encode(etats) else { return }
        UserDefaults.standard.set(donnees, forKey: cle)
        NotificationCenter.default.post(name: .pocketDonneesDidChange, object: nil)
    }

    /// N'accepte que les collections d'utilisateur Reddit (`u/pseudo`).
    static func pseudoReddit(_ libelle: String) -> String? {
        guard libelle.hasPrefix("u/") else { return nil }
        let pseudo = String(libelle.dropFirst(2)).lowercased()
        return pseudo.isEmpty ? nil : pseudo
    }

    static func noterTelechargement(pseudo: String) {
        var etats = charger()
        var etat = etats[pseudo] ?? CompteSuiviEtat()
        etat.dernierTelechargement = Date()
        etats[pseudo] = etat
        enregistrer(etats)
    }

    static func noterUpload(pseudo: String) {
        var etats = charger()
        var etat = etats[pseudo] ?? CompteSuiviEtat()
        etat.dernierUpload = Date()
        etats[pseudo] = etat
        enregistrer(etats)
    }
}

/// La seule copie envoyée au serveur : les comptes suivis Reddit et leurs dates.
struct PocketSnapshot: Codable {
    var comptes: [String: CompteSuiviEtat]

    private enum CodingKeys: String, CodingKey { case comptes }

    init(comptes: [String: CompteSuiviEtat] = [:]) {
        self.comptes = comptes
    }

    /// Tolère une ancienne copie qui ne contenait pas ce champ.
    init(from decoder: Decoder) throws {
        let conteneur = try decoder.container(keyedBy: CodingKeys.self)
        comptes = try conteneur.decodeIfPresent([String: CompteSuiviEtat].self, forKey: .comptes) ?? [:]
    }

    @MainActor
    static func capturer() -> PocketSnapshot {
        var etats = SuiviStore.charger()

        // La coche vit encore dans la clé historique `following.downloadedUsernames`.
        let donneesMarques = UserDefaults.standard.data(forKey: "following.downloadedUsernames") ?? Data()
        let marques = Set((try? JSONDecoder().decode([String].self, from: donneesMarques)) ?? [])

        for (pseudo, etat) in etats {
            var copie = etat
            copie.marque = marques.contains(pseudo)
            etats[pseudo] = copie
        }
        for pseudo in marques where etats[pseudo] == nil {
            etats[pseudo] = CompteSuiviEtat(marque: true)
        }
        return PocketSnapshot(comptes: etats)
    }

    @MainActor
    func appliquer() {
        SuiviStore.enregistrer(comptes)
        let marques = comptes.filter { $0.value.marque }.keys.sorted()
        if let donnees = try? JSONEncoder().encode(marques) {
            UserDefaults.standard.set(donnees, forKey: "following.downloadedUsernames")
        }
    }

    /// Représentation JSON pour le champ `data` de l'élément envoyé au serveur.
    var jsonValue: JSONValue? {
        guard let donnees = try? JSONEncoder().encode(self),
              let objet = try? JSONSerialization.jsonObject(with: donnees) else { return nil }
        return JSONValue.depuis(objet)
    }
}

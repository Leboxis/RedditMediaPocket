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

/// Stockage local des suivis Reddit et de leurs états, séparé des coches historiques.
enum SuiviStore {
    static let cle = "following.etats"
    static let cleListe = "following.liste"
    static let cleMarques = "following.downloadedUsernames"

    static func charger(defaults: UserDefaults = .standard) -> [String: CompteSuiviEtat] {
        guard let donnees = defaults.data(forKey: cle),
              let etats = try? JSONDecoder().decode([String: CompteSuiviEtat].self, from: donnees) else {
            return [:]
        }
        return etats
    }

    static func enregistrer(_ etats: [String: CompteSuiviEtat], defaults: UserDefaults = .standard, notifier: Bool = true) {
        guard let donnees = try? JSONEncoder().encode(etats) else { return }
        defaults.set(donnees, forKey: cle)
        if notifier {
            NotificationCenter.default.post(name: .pocketDonneesDidChange, object: nil)
        }
    }

    /// Nettoie et dédoublonne les pseudos sans casser leur casse d'origine ni leur ordre.
    static func normaliserListe(_ pseudos: [String]) -> [String] {
        var vus = Set<String>()
        var resultat: [String] = []
        for brut in pseudos {
            let propre = brut.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !propre.isEmpty else { continue }
            guard vus.insert(propre.lowercased()).inserted else { continue }
            resultat.append(propre)
        }
        return resultat
    }

    /// Liste synchronisée des comptes Reddit suivis (casse d'origine conservée).
    static func chargerListe(defaults: UserDefaults = .standard) -> [String] {
        guard let donnees = defaults.data(forKey: cleListe),
              let pseudos = try? JSONDecoder().decode([String].self, from: donnees) else {
            return []
        }
        return normaliserListe(pseudos)
    }

    /// Enregistre la liste complète des comptes suivis et déclenche la synchro si elle change.
    static func enregistrerListe(_ pseudos: [String], defaults: UserDefaults = .standard, notifier: Bool = true) {
        let propre = normaliserListe(pseudos)
        guard propre != chargerListe(defaults: defaults) else { return }
        guard let donnees = try? JSONEncoder().encode(propre) else { return }
        defaults.set(donnees, forKey: cleListe)
        if notifier {
            NotificationCenter.default.post(name: .pocketDonneesDidChange, object: nil)
        }
    }

    /// Retourne les suivis connus hors connexion Reddit : la liste synchronisée si présente,
    /// sinon un repli sur les comptes ayant déjà un statut ou une coche (anciennes sauvegardes).
    static func pseudosConnus(defaults: UserDefaults = .standard) -> [String] {
        let liste = chargerListe(defaults: defaults)
        if !liste.isEmpty { return liste }
        let etats = charger(defaults: defaults)
        let donneesMarques = defaults.data(forKey: cleMarques) ?? Data()
        let marques = (try? JSONDecoder().decode([String].self, from: donneesMarques)) ?? []
        return Set(etats.keys).union(marques).sorted()
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

/// La seule copie envoyée au serveur : tous les comptes suivis Reddit et leurs statuts.
struct PocketSnapshot: Codable {
    /// Liste complète des comptes Reddit suivis (casse d'origine conservée).
    var suivis: [String]
    /// Statut (coche, dernier téléchargement, dernier upload) indexé par pseudo en minuscules.
    var comptes: [String: CompteSuiviEtat]

    private enum CodingKeys: String, CodingKey { case suivis, comptes }

    init(suivis: [String] = [], comptes: [String: CompteSuiviEtat] = [:]) {
        self.suivis = SuiviStore.normaliserListe(suivis)
        self.comptes = comptes
    }

    /// Tolère une ancienne copie qui ne contenait pas l'un de ces champs.
    init(from decoder: Decoder) throws {
        let conteneur = try decoder.container(keyedBy: CodingKeys.self)
        let bruts = try conteneur.decodeIfPresent([String].self, forKey: .suivis) ?? []
        suivis = SuiviStore.normaliserListe(bruts)
        comptes = try conteneur.decodeIfPresent([String: CompteSuiviEtat].self, forKey: .comptes) ?? [:]
    }

    @MainActor
    static func capturer(defaults: UserDefaults = .standard) -> PocketSnapshot {
        let suivis = SuiviStore.chargerListe(defaults: defaults)
        var etats = SuiviStore.charger(defaults: defaults)

        // La coche vit encore dans la clé historique `following.downloadedUsernames`.
        let donneesMarques = defaults.data(forKey: SuiviStore.cleMarques) ?? Data()
        let marques = Set((try? JSONDecoder().decode([String].self, from: donneesMarques)) ?? [])

        for (pseudo, etat) in etats {
            var copie = etat
            copie.marque = marques.contains(pseudo)
            etats[pseudo] = copie
        }
        for pseudo in marques where etats[pseudo] == nil {
            etats[pseudo] = CompteSuiviEtat(marque: true)
        }
        return PocketSnapshot(suivis: suivis, comptes: etats)
    }

    @MainActor
    func appliquer(defaults: UserDefaults = .standard) {
        SuiviStore.enregistrerListe(suivis, defaults: defaults, notifier: false)
        SuiviStore.enregistrer(comptes, defaults: defaults, notifier: false)
        let marques = comptes.filter { $0.value.marque }.keys.sorted()
        if let donnees = try? JSONEncoder().encode(marques) {
            defaults.set(donnees, forKey: SuiviStore.cleMarques)
        }
    }

    /// Représentation JSON pour le champ `data` de l'élément envoyé au serveur.
    var jsonValue: JSONValue? {
        guard let donnees = try? JSONEncoder().encode(self),
              let objet = try? JSONSerialization.jsonObject(with: donnees) else { return nil }
        return JSONValue.depuis(objet)
    }
}

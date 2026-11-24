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

/// Plateforme d'un compte suivi dans l'écran Suivis et la synchro Cloudflare.
enum PlateformeSuivi: String, CaseIterable, Identifiable, Sendable {
    case reddit
    case x
    case tiktok

    var id: String { rawValue }
}

/// Stockage local des suivis (Reddit, X et TikTok) et de leurs états, séparé des coches historiques.
enum SuiviStore {
    static let cle = "following.etats"
    static let cleListe = "following.liste"
    static let cleMarques = "following.downloadedUsernames"

    static let cleEtatsX = "following.x.etats"
    static let cleListeX = "following.x.liste"
    static let cleMarquesX = "following.x.downloadedUsernames"

    static let cleEtatsTikTok = "following.tiktok.etats"
    static let cleListeTikTok = "following.tiktok.liste"
    static let cleMarquesTikTok = "following.tiktok.downloadedUsernames"

    private static func cleEtats(pour plateforme: PlateformeSuivi) -> String {
        switch plateforme {
        case .reddit: return cle
        case .x: return cleEtatsX
        case .tiktok: return cleEtatsTikTok
        }
    }

    private static func cleListe(pour plateforme: PlateformeSuivi) -> String {
        switch plateforme {
        case .reddit: return cleListe
        case .x: return cleListeX
        case .tiktok: return cleListeTikTok
        }
    }

    private static func cleMarques(pour plateforme: PlateformeSuivi) -> String {
        switch plateforme {
        case .reddit: return cleMarques
        case .x: return cleMarquesX
        case .tiktok: return cleMarquesTikTok
        }
    }

    /// Cache mémoire des lectures UserDefaults : la feuille « État kDrive »
    /// relit ces valeurs plusieurs fois par image (compteurs, filtres, lignes),
    /// et un re-décodage JSON par appel provoquait des saccades au défilement.
    /// Invalide à chaque écriture pour ne jamais servir de donnée périmée.
    private static var cacheLock = NSLock()
    private static var listeCache: [ObjectIdentifier: [PlateformeSuivi: [String]]] = [:]
    private static var etatsCache: [ObjectIdentifier: [PlateformeSuivi: [String: CompteSuiviEtat]]] = [:]
    private static var marquesCache: [ObjectIdentifier: [PlateformeSuivi: Set<String>]] = [:]

    private static func viderCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        listeCache.removeAll()
        etatsCache.removeAll()
        marquesCache.removeAll()
    }

    static func charger(plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard) -> [String: CompteSuiviEtat] {
        let identite = ObjectIdentifier(defaults)
        cacheLock.lock()
        if let misEnCache = etatsCache[identite]?[plateforme] {
            cacheLock.unlock()
            return misEnCache
        }
        cacheLock.unlock()
        guard let donnees = defaults.data(forKey: cleEtats(pour: plateforme)),
              let etats = try? JSONDecoder().decode([String: CompteSuiviEtat].self, from: donnees) else {
            return [:]
        }
        cacheLock.lock()
        etatsCache[identite, default: [:]][plateforme] = etats
        cacheLock.unlock()
        return etats
    }

    static func enregistrer(_ etats: [String: CompteSuiviEtat], plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard, notifier: Bool = true) {
        guard let donnees = try? JSONEncoder().encode(etats) else { return }
        defaults.set(donnees, forKey: cleEtats(pour: plateforme))
        viderCache()
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

    /// Liste synchronisée des comptes suivis (casse d'origine conservée).
    static func chargerListe(plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard) -> [String] {
        let identite = ObjectIdentifier(defaults)
        cacheLock.lock()
        if let misEnCache = listeCache[identite]?[plateforme] {
            cacheLock.unlock()
            return misEnCache
        }
        cacheLock.unlock()
        guard let donnees = defaults.data(forKey: cleListe(pour: plateforme)),
              let pseudos = try? JSONDecoder().decode([String].self, from: donnees) else {
            return []
        }
        let resultat = normaliserListe(pseudos)
        cacheLock.lock()
        listeCache[identite, default: [:]][plateforme] = resultat
        cacheLock.unlock()
        return resultat
    }

    /// Enregistre la liste complète des comptes suivis et déclenche la synchro si elle change.
    static func enregistrerListe(_ pseudos: [String], plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard, notifier: Bool = true) {
        let propre = normaliserListe(pseudos)
        guard propre != chargerListe(plateforme: plateforme, defaults: defaults) else { return }
        guard let donnees = try? JSONEncoder().encode(propre) else { return }
        defaults.set(donnees, forKey: cleListe(pour: plateforme))
        viderCache()
        if notifier {
            NotificationCenter.default.post(name: .pocketDonneesDidChange, object: nil)
        }
    }

    /// Ajoute manuellement un pseudo X (accepte `@pseudo`, `pseudo`, `tw/pseudo` ou une URL x.com).
    @discardableResult
    static func ajouterSuiviX(_ saisie: String, defaults: UserDefaults = .standard, notifier: Bool = true) throws -> String {
        try ajouterSuiviManuel(saisie, plateforme: .x, defaults: defaults, notifier: notifier)
    }

    /// Ajoute manuellement un pseudo TikTok (accepte `@pseudo`, `pseudo`, `tt/pseudo` ou une URL tiktok.com/@pseudo).
    @discardableResult
    static func ajouterSuiviTikTok(_ saisie: String, defaults: UserDefaults = .standard, notifier: Bool = true) throws -> String {
        try ajouterSuiviManuel(saisie, plateforme: .tiktok, defaults: defaults, notifier: notifier)
    }

    /// Ajoute manuellement un pseudo X ou TikTok en validant son format.
    @discardableResult
    static func ajouterSuiviManuel(_ saisie: String, plateforme: PlateformeSuivi, defaults: UserDefaults = .standard, notifier: Bool = true) throws -> String {
        let pseudo: String
        switch plateforme {
        case .x:
            pseudo = try XTwitterAPI.username(saisie)
        case .tiktok:
            pseudo = try TikTokAPI.username(saisie)
        case .reddit:
            pseudo = try MediaExtractor.username(saisie)
        }
        var liste = chargerListe(plateforme: plateforme, defaults: defaults)
        if !liste.contains(where: { $0.caseInsensitiveCompare(pseudo) == .orderedSame }) {
            liste.append(pseudo)
            enregistrerListe(liste, plateforme: plateforme, defaults: defaults, notifier: notifier)
        }
        return pseudo
    }

    /// Retire un pseudo de la liste manuelle X (sans effacer son historique si jamais il est réajouté).
    static func supprimerSuiviX(_ pseudo: String, defaults: UserDefaults = .standard, notifier: Bool = true) {
        supprimerSuiviManuel(pseudo, plateforme: .x, defaults: defaults, notifier: notifier)
    }

    /// Retire un pseudo de la liste manuelle TikTok.
    static func supprimerSuiviTikTok(_ pseudo: String, defaults: UserDefaults = .standard, notifier: Bool = true) {
        supprimerSuiviManuel(pseudo, plateforme: .tiktok, defaults: defaults, notifier: notifier)
    }

    /// Retire un pseudo d'une liste manuelle (X ou TikTok).
    static func supprimerSuiviManuel(_ pseudo: String, plateforme: PlateformeSuivi, defaults: UserDefaults = .standard, notifier: Bool = true) {
        let liste = chargerListe(plateforme: plateforme, defaults: defaults)
            .filter { $0.caseInsensitiveCompare(pseudo) != .orderedSame }
        enregistrerListe(liste, plateforme: plateforme, defaults: defaults, notifier: notifier)
    }

    /// Renomme un suivi manuel (X ou TikTok) en gardant sa place dans la liste et
    /// en transférant son historique (statut et coche) sur le nouveau pseudo.
    @discardableResult
    static func renommerSuiviManuel(
        _ pseudoActuel: String,
        saisie: String,
        plateforme: PlateformeSuivi,
        defaults: UserDefaults = .standard,
        notifier: Bool = true
    ) throws -> String {
        let nouveauPseudo: String
        switch plateforme {
        case .x: nouveauPseudo = try XTwitterAPI.username(saisie)
        case .tiktok: nouveauPseudo = try TikTokAPI.username(saisie)
        case .reddit: nouveauPseudo = try MediaExtractor.username(saisie)
        }

        var liste = chargerListe(plateforme: plateforme, defaults: defaults)
        guard let index = liste.firstIndex(where: { $0.caseInsensitiveCompare(pseudoActuel) == .orderedSame }) else {
            throw NetworkError.invalid(L("Ce suivi n'existe plus.", "This follow no longer exists."))
        }
        if let doublon = liste.firstIndex(where: { $0.caseInsensitiveCompare(nouveauPseudo) == .orderedSame }),
           doublon != index {
            throw NetworkError.invalid(L("Ce compte est déjà suivi.", "This account is already followed."))
        }

        let ancienneCle = pseudoActuel.lowercased()
        let nouvelleCle = nouveauPseudo.lowercased()
        if ancienneCle != nouvelleCle {
            var etats = charger(plateforme: plateforme, defaults: defaults)
            if let etat = etats.removeValue(forKey: ancienneCle) {
                var fusion = etat
                // Un pseudo déjà supprimé peut encore avoir un historique : on le garde.
                if let existant = etats[nouvelleCle] {
                    fusion.marque = fusion.marque || existant.marque
                    fusion.dernierTelechargement = [fusion.dernierTelechargement, existant.dernierTelechargement]
                        .compactMap { $0 }.max()
                    fusion.dernierUpload = [fusion.dernierUpload, existant.dernierUpload]
                        .compactMap { $0 }.max()
                }
                etats[nouvelleCle] = fusion
                enregistrer(etats, plateforme: plateforme, defaults: defaults, notifier: notifier)
            }
            var marques = chargerMarques(plateforme: plateforme, defaults: defaults)
            if marques.remove(ancienneCle) != nil {
                marques.insert(nouvelleCle)
                enregistrerMarques(marques, plateforme: plateforme, defaults: defaults, notifier: notifier)
            }
        }
        if liste[index] != nouveauPseudo {
            liste[index] = nouveauPseudo
            enregistrerListe(liste, plateforme: plateforme, defaults: defaults, notifier: notifier)
        }
        return nouveauPseudo
    }

    /// Retourne les suivis connus hors connexion : la liste synchronisée si présente,
    /// sinon un repli sur les comptes ayant déjà un statut ou une coche (anciennes sauvegardes).
    static func pseudosConnus(plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard) -> [String] {
        let liste = chargerListe(plateforme: plateforme, defaults: defaults)
        if !liste.isEmpty { return liste }
        let etats = charger(plateforme: plateforme, defaults: defaults)
        let marques = chargerMarques(plateforme: plateforme, defaults: defaults)
        return Set(etats.keys).union(marques).sorted()
    }

    static func chargerMarques(plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard) -> Set<String> {
        let identite = ObjectIdentifier(defaults)
        cacheLock.lock()
        if let misEnCache = marquesCache[identite]?[plateforme] {
            cacheLock.unlock()
            return misEnCache
        }
        cacheLock.unlock()
        let donnees = defaults.data(forKey: cleMarques(pour: plateforme)) ?? Data()
        let marques = Set((try? JSONDecoder().decode([String].self, from: donnees)) ?? [])
        cacheLock.lock()
        marquesCache[identite, default: [:]][plateforme] = marques
        cacheLock.unlock()
        return marques
    }

    static func enregistrerMarques(_ marques: Set<String>, plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard, notifier: Bool = true) {
        guard let donnees = try? JSONEncoder().encode(marques.sorted()) else { return }
        defaults.set(donnees, forKey: cleMarques(pour: plateforme))
        viderCache()
        if notifier {
            NotificationCenter.default.post(name: .pocketDonneesDidChange, object: nil)
        }
    }

    /// Reconnaît les collections d'utilisateur Reddit (`u/pseudo`), X (`tw/pseudo`) et TikTok (`tt/pseudo`).
    static func identifiantCollection(_ libelle: String) -> (plateforme: PlateformeSuivi, pseudo: String)? {
        if libelle.hasPrefix("u/") {
            let pseudo = String(libelle.dropFirst(2)).lowercased()
            return pseudo.isEmpty ? nil : (.reddit, pseudo)
        }
        if libelle.hasPrefix("tw/") {
            let pseudo = String(libelle.dropFirst(3)).lowercased()
            return pseudo.isEmpty ? nil : (.x, pseudo)
        }
        if libelle.hasPrefix("tt/") {
            let pseudo = String(libelle.dropFirst(3)).lowercased()
            return pseudo.isEmpty ? nil : (.tiktok, pseudo)
        }
        return nil
    }

    /// N'accepte que les collections d'utilisateur Reddit (`u/pseudo`).
    static func pseudoReddit(_ libelle: String) -> String? {
        guard let id = identifiantCollection(libelle), id.plateforme == .reddit else { return nil }
        return id.pseudo
    }

    static func noterTelechargement(pseudo: String, plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard) {
        let clePseudo = pseudo.lowercased()
        guard !clePseudo.isEmpty else { return }
        var etats = charger(plateforme: plateforme, defaults: defaults)
        var etat = etats[clePseudo] ?? CompteSuiviEtat()
        etat.dernierTelechargement = Date()
        etats[clePseudo] = etat
        enregistrer(etats, plateforme: plateforme, defaults: defaults)
    }

    static func noterUpload(pseudo: String, plateforme: PlateformeSuivi = .reddit, defaults: UserDefaults = .standard) {
        let clePseudo = pseudo.lowercased()
        guard !clePseudo.isEmpty else { return }
        var etats = charger(plateforme: plateforme, defaults: defaults)
        var etat = etats[clePseudo] ?? CompteSuiviEtat()
        etat.dernierUpload = Date()
        etats[clePseudo] = etat
        enregistrer(etats, plateforme: plateforme, defaults: defaults)
    }
}

/// La seule copie envoyée au serveur : tous les comptes suivis (Reddit, X et TikTok) et leurs statuts.
struct PocketSnapshot: Codable {
    /// Liste complète des comptes Reddit suivis (casse d'origine conservée).
    var suivis: [String]
    /// Statut Reddit (coche, dernier téléchargement, dernier upload) indexé par pseudo en minuscules.
    var comptes: [String: CompteSuiviEtat]
    /// Liste manuelle des comptes X suivis (casse d'origine conservée).
    var suivisX: [String]
    /// Statut X (coche, dernier téléchargement, dernier upload) indexé par pseudo en minuscules.
    var comptesX: [String: CompteSuiviEtat]
    /// Liste manuelle des comptes TikTok suivis (casse d'origine conservée).
    var suivisTikTok: [String]
    /// Statut TikTok (coche, dernier téléchargement, dernier upload) indexé par pseudo en minuscules.
    var comptesTikTok: [String: CompteSuiviEtat]

    private enum CodingKeys: String, CodingKey {
        case suivis, comptes, suivisX, comptesX, suivisTikTok, comptesTikTok
    }

    init(
        suivis: [String] = [],
        comptes: [String: CompteSuiviEtat] = [:],
        suivisX: [String] = [],
        comptesX: [String: CompteSuiviEtat] = [:],
        suivisTikTok: [String] = [],
        comptesTikTok: [String: CompteSuiviEtat] = [:]
    ) {
        self.suivis = SuiviStore.normaliserListe(suivis)
        self.comptes = comptes
        self.suivisX = SuiviStore.normaliserListe(suivisX)
        self.comptesX = comptesX
        self.suivisTikTok = SuiviStore.normaliserListe(suivisTikTok)
        self.comptesTikTok = comptesTikTok
    }

    /// Tolère une ancienne copie qui ne contenait pas certains champs.
    init(from decoder: Decoder) throws {
        let conteneur = try decoder.container(keyedBy: CodingKeys.self)
        let bruts = try conteneur.decodeIfPresent([String].self, forKey: .suivis) ?? []
        suivis = SuiviStore.normaliserListe(bruts)
        comptes = try conteneur.decodeIfPresent([String: CompteSuiviEtat].self, forKey: .comptes) ?? [:]
        let brutsX = try conteneur.decodeIfPresent([String].self, forKey: .suivisX) ?? []
        suivisX = SuiviStore.normaliserListe(brutsX)
        comptesX = try conteneur.decodeIfPresent([String: CompteSuiviEtat].self, forKey: .comptesX) ?? [:]
        let brutsTikTok = try conteneur.decodeIfPresent([String].self, forKey: .suivisTikTok) ?? []
        suivisTikTok = SuiviStore.normaliserListe(brutsTikTok)
        comptesTikTok = try conteneur.decodeIfPresent([String: CompteSuiviEtat].self, forKey: .comptesTikTok) ?? [:]
    }

    private static func fusionnerEtats(plateforme: PlateformeSuivi, defaults: UserDefaults) -> [String: CompteSuiviEtat] {
        var etats = SuiviStore.charger(plateforme: plateforme, defaults: defaults)
        let marques = SuiviStore.chargerMarques(plateforme: plateforme, defaults: defaults)
        for (pseudo, etat) in etats {
            var copie = etat
            copie.marque = marques.contains(pseudo)
            etats[pseudo] = copie
        }
        for pseudo in marques where etats[pseudo] == nil {
            etats[pseudo] = CompteSuiviEtat(marque: true)
        }
        return etats
    }

    @MainActor
    static func capturer(defaults: UserDefaults = .standard) -> PocketSnapshot {
        PocketSnapshot(
            suivis: SuiviStore.chargerListe(plateforme: .reddit, defaults: defaults),
            comptes: fusionnerEtats(plateforme: .reddit, defaults: defaults),
            suivisX: SuiviStore.chargerListe(plateforme: .x, defaults: defaults),
            comptesX: fusionnerEtats(plateforme: .x, defaults: defaults),
            suivisTikTok: SuiviStore.chargerListe(plateforme: .tiktok, defaults: defaults),
            comptesTikTok: fusionnerEtats(plateforme: .tiktok, defaults: defaults)
        )
    }

    @MainActor
    func appliquer(defaults: UserDefaults = .standard) {
        SuiviStore.enregistrerListe(suivis, plateforme: .reddit, defaults: defaults, notifier: false)
        SuiviStore.enregistrer(comptes, plateforme: .reddit, defaults: defaults, notifier: false)
        SuiviStore.enregistrerMarques(
            Set(comptes.filter { $0.value.marque }.keys),
            plateforme: .reddit,
            defaults: defaults,
            notifier: false
        )

        SuiviStore.enregistrerListe(suivisX, plateforme: .x, defaults: defaults, notifier: false)
        SuiviStore.enregistrer(comptesX, plateforme: .x, defaults: defaults, notifier: false)
        SuiviStore.enregistrerMarques(
            Set(comptesX.filter { $0.value.marque }.keys),
            plateforme: .x,
            defaults: defaults,
            notifier: false
        )

        SuiviStore.enregistrerListe(suivisTikTok, plateforme: .tiktok, defaults: defaults, notifier: false)
        SuiviStore.enregistrer(comptesTikTok, plateforme: .tiktok, defaults: defaults, notifier: false)
        SuiviStore.enregistrerMarques(
            Set(comptesTikTok.filter { $0.value.marque }.keys),
            plateforme: .tiktok,
            defaults: defaults,
            notifier: false
        )
    }

    /// Représentation JSON pour le champ `data` de l'élément envoyé au serveur.
    var jsonValue: JSONValue? {
        guard let donnees = try? JSONEncoder().encode(self),
              let objet = try? JSONSerialization.jsonObject(with: donnees) else { return nil }
        return JSONValue.depuis(objet)
    }
}

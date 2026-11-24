import Foundation
import WebKit
import MediaCore
import Observation

extension Notification.Name {
    /// Envoyée quand une session locale change (connexion ou déconnexion).
    static let pocketSessionsDidChange = Notification.Name("pocketSessionsDidChange")
    /// Envoyée quand des sessions distantes viennent d'être réinjectées.
    static let pocketSessionsRestaurees = Notification.Name("pocketSessionsRestaurees")
}

/// Les sites dont les cookies de session sont sauvegardés sur le serveur.
/// Le filtre de domaine garantit qu'aucun cookie de CDN ou d'un autre site
/// n'est archivé, même si le magasin WebKit en contient.
public enum SiteSession: String, CaseIterable, Sendable {
    case reddit
    case x
    case tiktok
    case instagram

    public func accepte(domain: String) -> Bool {
        let brut = domain.lowercased()
        let base = brut.hasPrefix(".") ? String(brut.dropFirst()) : brut
        switch self {
        case .reddit:
            return base == "reddit.com" || base.hasSuffix(".reddit.com")
        case .x:
            return base == "x.com" || base.hasSuffix(".x.com")
                || base == "twitter.com" || base.hasSuffix(".twitter.com")
        case .tiktok:
            return base == "tiktok.com" || base.hasSuffix(".tiktok.com")
        case .instagram:
            return base == "instagram.com" || base.hasSuffix(".instagram.com")
        }
    }
}

/// Sauvegarde et restauration des sessions WebKit via le Worker Cloudflare.
///
/// - Au lancement (et dès que la clé API est enregistrée), les cookies distants
///   sont réinjectés dans le magasin WebKit de chaque site : sur une installation
///   neuve, une seule saisie de la clé suffit à retrouver toutes les connexions.
/// - Toute modification locale des cookies déclenche une sauvegarde groupée.
/// - Les changements survenus pendant une restauration sont ignorés pour ne pas
///   écraser la copie distante avec un magasin encore vide.
@MainActor
@Observable
final class SessionCookieSyncService: NSObject, WKHTTPCookieStoreObserver {
    static let shared = SessionCookieSyncService()

    private(set) var etat = L("Clé API requise", "API key required")
    private(set) var derniereSynchronisation: Date?
    private(set) var sitesSauvegardes: [String] = []

    private let client: CookiesAPIClientProtocol
    private var observateursInstallees = false
    private var notificationObserver: NSObjectProtocol?
    private var restaurationRecente = false
    private var tacheAntiRebond: Task<Void, Never>?
    /// Empreinte canonique de la dernière copie envoyée, pour éviter les allers-retours inutiles.
    private var derniereEmpreinte: String?

    init(client: CookiesAPIClientProtocol = CookiesAPIClient()) {
        self.client = client
        super.init()
    }

    /// À appeler au lancement et juste après l'enregistrement de la clé API.
    func demarrer() async {
        guard KeychainStore.get() != nil else {
            etat = L("Clé API requise", "API key required")
            return
        }
        restaurationRecente = true
        installerObservateursSiBesoin()
        await restaurer()
    }

    private func installerObservateursSiBesoin() {
        guard !observateursInstallees else { return }
        for site in SiteSession.allCases {
            store(pour: site).httpCookieStore.add(self)
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .pocketSessionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.planifierSynchronisation() }
        }
        observateursInstallees = true
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.planifierSynchronisation() }
    }

    private func store(pour site: SiteSession) -> WKWebsiteDataStore {
        switch site {
        case .reddit: return RedditSession.shared.store
        case .x: return XSession.shared.store
        case .tiktok: return TikTokSession.shared.store
        case .instagram: return InstagramSession.shared.store
        }
    }

    private func actualiserSessions() async {
        await RedditSession.shared.refresh()
        await XSession.shared.refresh()
        await TikTokSession.shared.refresh()
        await InstagramSession.shared.refresh()
    }

    private func cookies(pour site: SiteSession) async -> [CookieRecord] {
        let tous = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            store(pour: site).httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return tous.compactMap { cookie in
            guard site.accepte(domain: cookie.domain) else { return nil }
            return CookieRecord(cookie: cookie)
        }
    }

    /// Empreinte déterministe : l'ordre du dictionnaire ou des cookies ne doit pas
    /// faire croire à une modification.
    private func empreinte(_ sites: [String: [CookieRecord]]) -> String {
        var lignes: [String] = []
        for site in sites.keys.sorted() {
            let cookies = (sites[site] ?? []).sorted {
                if $0.domain != $1.domain { return $0.domain < $1.domain }
                if $0.path != $1.path { return $0.path < $1.path }
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.value < $1.value
            }
            for cookie in cookies {
                let expiration = cookie.expires?.timeIntervalSinceReferenceDate.description ?? "-"
                lignes.append("\(site)|\(cookie.domain)|\(cookie.path)|\(cookie.name)|\(cookie.value)|\(expiration)|\(cookie.secure)|\(cookie.httpOnly)")
            }
        }
        return lignes.joined(separator: "\n")
    }

    /// Programme un envoi groupé après une courte attente.
    func planifierSynchronisation() {
        guard !restaurationRecente else { return }
        tacheAntiRebond?.cancel()
        tacheAntiRebond = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await synchroniser()
        }
    }

    /// Envoie les cookies locaux des quatre sites au serveur.
    func synchroniser() async {
        guard KeychainStore.get() != nil else {
            etat = L("Clé API requise", "API key required")
            return
        }
        var sites: [String: [CookieRecord]] = [:]
        for site in SiteSession.allCases {
            sites[site.rawValue] = await cookies(pour: site)
        }
        let actuelle = empreinte(sites)
        guard actuelle != derniereEmpreinte else {
            etat = L("Sessions à jour", "Sessions up to date")
            return
        }
        do {
            try await client.ecrire(sites: sites)
            derniereEmpreinte = actuelle
            sitesSauvegardes = SiteSession.allCases
                .filter { !(sites[$0.rawValue] ?? []).isEmpty }
                .map(\.rawValue)
            etat = L("Sessions synchronisées", "Sessions synced")
            derniereSynchronisation = Date()
        } catch {
            etat = L("Erreur : \(error.localizedDescription)", "Error: \(error.localizedDescription)")
        }
    }

    /// Réinjecte les cookies distants dans chaque magasin WebKit, puis rafraîchit
    /// les indicateurs de session pour que l'interface affiche immédiatement
    /// les connexions retrouvées.
    func restaurer() async {
        guard KeychainStore.get() != nil else {
            etat = L("Clé API requise", "API key required")
            return
        }
        restaurationRecente = true
        defer {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.restaurationRecente = false
            }
        }
        do {
            let sauvegarde = try await client.lire()
            var restaures: [String] = []
            for site in SiteSession.allCases {
                guard let enregistrements = sauvegarde.sites[site.rawValue],
                      !enregistrements.isEmpty else { continue }
                let cookies = enregistrements.compactMap { $0.makeCookie() }
                guard !cookies.isEmpty else { continue }
                let magasin = store(pour: site)
                for cookie in cookies {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        magasin.httpCookieStore.setCookie(cookie) { continuation.resume() }
                    }
                }
                restaures.append(site.rawValue)
            }
            await actualiserSessions()
            sitesSauvegardes = restaures
            derniereEmpreinte = empreinte(sauvegarde.sites)
            derniereSynchronisation = Date()
            NotificationCenter.default.post(name: .pocketSessionsRestaurees, object: nil)
            if restaures.isEmpty {
                // Aucune copie distante : on prend celle déjà présente sur l'appareil.
                etat = L("Aucune session distante", "No remote session")
                await synchroniser()
            } else {
                etat = L("Sessions restaurées", "Sessions restored")
            }
        } catch {
            etat = L("Restauration impossible : \(error.localizedDescription)",
                     "Restore failed: \(error.localizedDescription)")
        }
    }

    /// Efface les sessions côté serveur sans toucher aux sessions locales.
    func supprimerSauvegarde() async {
        guard KeychainStore.get() != nil else { return }
        do {
            try await client.supprimer()
            derniereEmpreinte = nil
            sitesSauvegardes = []
            etat = L("Sessions distantes effacées", "Remote sessions cleared")
            derniereSynchronisation = Date()
        } catch {
            etat = L("Erreur : \(error.localizedDescription)", "Error: \(error.localizedDescription)")
        }
    }
}

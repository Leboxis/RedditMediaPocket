import Foundation

public enum TikTokError: LocalizedError {
    case invalidUsername, loginRequired, unknownAccount, deniedAccess, invalidTimeline, tooManyPages, invalidPageLimit, postUnsupported, verificationRequired

    public var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return L("Pseudo TikTok invalide (1 à 24 lettres, chiffres, points ou underscores, ex. tt/pseudo).", "Invalid TikTok username (1 to 24 letters, digits, dots or underscores, e.g. tt/username).")
        case .loginRequired:
            return L("Connecte-toi à TikTok dans les Réglages : les médias d'un profil exigent une session.", "Sign in to TikTok in Settings: a profile's media requires a session.")
        case .unknownAccount:
            return L("Compte TikTok introuvable ou privé : les médias publics de ce profil sont inaccessibles.", "TikTok account not found or private: this profile's public media is inaccessible.")
        case .deniedAccess:
            return L("TikTok refuse l'accès aux médias (HTTP 403 ou 401). Reconnecte-toi dans les Réglages, l'interface de TikTok a peut-être changé.", "TikTok denied media access (HTTP 403 or 401). Sign in again in Settings; TikTok's interface may have changed.")
        case .invalidTimeline:
            return L("Fil des médias TikTok illisible ou tronqué. TikTok demande parfois une vérification : reconnecte-toi dans les Réglages puis relance.", "TikTok media timeline is unreadable or truncated. TikTok sometimes asks for verification: sign in again in Settings, then relaunch.")
        case .tooManyPages:
            return L("Trop de pages de médias TikTok à parcourir.", "Too many TikTok media pages to scan.")
        case .invalidPageLimit:
            return L("Limite de pages invalide.", "Invalid page limit.")
        case .postUnsupported:
            return L("Les vidéos TikTok isolées ne sont pas prises en charge. Colle l'adresse du compte : les médias de ses publications seront parcourus.", "Single TikTok videos are not supported. Paste the account address instead: the media of its posts will be scanned.")
        case .verificationRequired:
            return L("TikTok exige une vérification avant de servir ce profil : ouvre la session TikTok dans les Réglages, visite tiktok.com dans la fenêtre affichée, complète la vérification (captcha) si elle apparaît, puis relance le parcours.", "TikTok requires a verification before serving this profile: open the TikTok session in Settings, browse tiktok.com in the shown window, complete the captcha if one appears, then run again.")
        }
    }
}

/// Surface publique de tiktok.com utilisée par la source `tt/`. Comme x.com,
/// TikTok ne sert les médias d'un profil qu'à un navigateur : les pages et
/// l'API interne exigent les cookies posés par WebKit (`sessionid` pour la
/// session, `ttwid` pour l'appareil, `msToken` pour les appels paginés), voir
/// `TikTokSession`. Les `queryId` de X n'ont pas d'équivalent stable ici :
/// la route `api/post/item_list` exige la signature `X-Bogus`/`X-Gnarly` que
/// seul le JavaScript de TikTok produit, donc la pagination passe par la
/// WebView cachée de `TikTokWebPaginator` plutôt que par URLSession.
public enum TikTokAPI {
    /// Profil WebKit et page web attendent un navigateur : TikTok refuse l'UA
    /// applicatif comme le stockage X-Fetish refuse le sien.
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// UA desktop (Chrome Windows) pour la tentative URLSession de la route
    /// paginée : TikTok sert parfois `item_list` sans signature à un client
    /// desktop cohérent, alors que le contexte mobile web exige `X-Bogus`.
    public static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// Un pseudo TikTok fait 1 à 24 caractères : lettres, chiffres, points ou
    /// underscores, et ne finit pas par un point. Les noms d'affichage
    /// (espaces, accents) sont refusés, ils ne sont pas utilisables dans une
    /// adresse de profil.
    public static func username(_ text: String) throws -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("tt/") { name = String(name.dropFirst(3)) }
        else if name.hasPrefix("@") { name = String(name.dropFirst()) }
        // Accepte une adresse de profil collée depuis un partage :
        // `tiktok.com/@pseudo`, `https://www.tiktok.com/@pseudo?lang=fr`.
        if let range = name.range(of: "(?:^|//)(?:www\\.)?tiktok\\.com/", options: .regularExpression) {
            name = String(name[range.upperBound...])
            name = String(name.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name = String(name.dropFirst()) }
        guard name.range(of: "^[A-Za-z0-9._]{1,24}$", options: .regularExpression) != nil,
              !name.hasSuffix(".") else {
            throw TikTokError.invalidUsername
        }
        return name
    }

    /// Adresse d'une vidéo isolée (`tiktok.com/@pseudo/video/<id>` ou
    /// `vm.tiktok.com`). Détectée seulement pour refuser la saisie avec un
    /// message utile : ce cas n'est pas pris en charge, et le dire vaut mieux
    /// qu'une erreur de pseudo (« video » n'est pas un compte).
    public static func isVideoURL(_ text: String) -> Bool {
        text.range(of: "(?:^|//)(?:www\\.)?tiktok\\.com/@[A-Za-z0-9._]+/video/",
                   options: .regularExpression) != nil
    }

    /// Page publique du profil : sert à résoudre le `secUid` du compte, la clé
    /// que l'API paginée exige. Les cookies de session ne sont pas nécessaires
    /// pour un profil public, mais TikTok exige le navigateur (UA, cookies
    /// `ttwid` posés par WebKit).
    public static func profileURL(username: String) -> URL {
        URL(string: "https://www.tiktok.com/@\(username)")!
    }

    /// Page des sauvegardés du compte connecté : dossiers de favoris
    /// (`/api/user/collection_list`) puis publications enregistrées
    /// (`/api/user/collect/item_list`), tous deux servisés signés par le
    /// JavaScript de la page — mêmes contraintes que `item_list`.
    public static func savedURL() -> URL {
        URL(string: "https://www.tiktok.com/saved")!
    }

    /// Route paginée « desktop » de la liste des publications : contexte
    /// Chrome Windows minimal, sans `msToken` en paramètre (les scrapeurs
    /// actifs s'en passent, et un msToken périmé est une cause plausible du
    /// 400 initial). Tentée avant la WebView ; au premier refus, la pagination
    /// bascule vers `TikTokWebPaginator` qui laisse TikTok signer lui-même.
    public static func desktopItemListURL(secUid: String, cursor: Int) -> URL {
        var components = URLComponents(string: "https://www.tiktok.com/api/post/item_list/")!
        components.queryItems = [
            URLQueryItem(name: "device_id", value: webDeviceID),
            URLQueryItem(name: "aid", value: "1988"),
            URLQueryItem(name: "count", value: "35"),
            URLQueryItem(name: "secUid", value: secUid),
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "device_platform", value: "web_pc"),
            URLQueryItem(name: "channel", value: "tiktok_web"),
            URLQueryItem(name: "os", value: "windows"),
            URLQueryItem(name: "browser_platform", value: "Win32"),
            URLQueryItem(name: "from_page", value: "user"),
            URLQueryItem(name: "sourceType", value: "8"),
            URLQueryItem(name: "app_language", value: "fr-FR"),
            URLQueryItem(name: "browser_language", value: "fr-FR"),
            URLQueryItem(name: "browser_name", value: "Chrome"),
            URLQueryItem(name: "browser_version", value: "126.0.0.0"),
            URLQueryItem(name: "region", value: "FR"),
            URLQueryItem(name: "priority_region", value: ""),
            URLQueryItem(name: "verifyFp", value: ""),
            URLQueryItem(name: "validFlag", value: "1")
        ]
        return components.url!
    }

    /// Identifiant d'appareil web, à la forme attendue (19 chiffres, généré
    /// par session). TikTok ne le vérifie pas : un nombre aléatoire bien
    /// formé vaut celui qu'il aurait émis. Son absence, si, se voit — c'est
    /// la seule différence entre une réponse complète et un 200 à corps vide
    /// sur les routes paginées (`tt_orcas_res: 1`, aucun message d'erreur) :
    /// chaque appel ci-dessous le porte pour cette raison.
    public static let webDeviceID: String = {
        var generator = SystemRandomNumberGenerator()
        var digits = String(Int.random(in: 1...9, using: &generator))
        for _ in 1..<19 { digits += String(Int.random(in: 0...9, using: &generator)) }
        return digits
    }()

    /// Paramètres communs aux appels « sauvegardés » du site web, relevés
    /// sur les requêtes que le client web desktop envoie lui-même :
    /// `browser_name`/`browser_version` portent les chaînes navigator
    /// (Mozilla / appVersion tronquée), pas le nom marketing. Le profil est
    /// francophone pour coller à la session de l'app.

    /// En-têtes des requêtes TikTok (page profil et API). Le Referer de la
    /// page profil est exigé par l'API web, et l'UA navigateur par les deux.
    /// `browserAgent` remplace l'UA iPhone par l'UA desktop pour la tentative
    /// URLSession paginée : les URL de médias servies à un client desktop
    /// n'acceptent que l'UA qui les a obtenues.
    public static func headers(referer: URL, browserAgent: String? = nil) -> [String: String] {
        [
            "User-Agent": browserAgent ?? userAgent,
            "Referer": referer.absoluteString,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    /// En-têtes des transferts de médias. Les URL vidéo exigent le Referer de
    /// tiktok.com (anti-hotlink) et l'UA navigateur lié aux cookies.
    public static func mediaHeaders(browserAgent: String? = nil) -> [String: String] {
        [
            "User-Agent": browserAgent ?? userAgent,
            "Referer": "https://www.tiktok.com/"
        ]
    }

    /// Pseudo d'un compte à partir d'un chemin de page `/@pseudo` (mensonge
    /// exclu : un chemin, pas une URL complète). `nil` hors profil.
    public static func usernameFromProfilePath(_ path: String) -> String? {
        guard let range = path.range(of: "^/@([A-Za-z0-9._]{1,24})", options: .regularExpression) else { return nil }
        let name = path[path.index(path.startIndex, offsetBy: 2)..<range.upperBound]
        guard !name.hasSuffix(".") else { return nil }
        return String(name)
    }

    private static func savedBaseQuery() -> [URLQueryItem] {
        // `region` dérive de la session ; la page utilisateur sert le compte
        // de la même région que l'appelant, une valeur vide reste acceptée.
        // `msToken` n'est pas construit ici : la page le replace seule.
        [
            URLQueryItem(name: "aid", value: "1988"),
            URLQueryItem(name: "app_language", value: "fr-FR"),
            URLQueryItem(name: "app_name", value: "tiktok_web"),
            URLQueryItem(name: "browser_language", value: "fr-FR"),
            URLQueryItem(name: "browser_name", value: "Mozilla"),
            URLQueryItem(name: "browser_online", value: "true"),
            URLQueryItem(name: "browser_platform", value: "Win32"),
            URLQueryItem(name: "browser_version", value: "5.0 (Windows)"),
            URLQueryItem(name: "channel", value: "tiktok_web"),
            URLQueryItem(name: "cookie_enabled", value: "true"),
            URLQueryItem(name: "device_id", value: webDeviceID),
            URLQueryItem(name: "device_platform", value: "web_pc"),
            URLQueryItem(name: "focus_state", value: "true"),
            URLQueryItem(name: "from_page", value: "user"),
            URLQueryItem(name: "history_len", value: "4"),
            URLQueryItem(name: "is_fullscreen", value: "false"),
            URLQueryItem(name: "is_page_visible", value: "true"),
            URLQueryItem(name: "language", value: "fr-FR"),
            URLQueryItem(name: "os", value: "windows"),
            URLQueryItem(name: "priority_region", value: ""),
            URLQueryItem(name: "referer", value: ""),
            URLQueryItem(name: "region", value: "FR"),
            URLQueryItem(name: "root_referer", value: "https://www.tiktok.com/"),
            URLQueryItem(name: "screen_height", value: "1080"),
            URLQueryItem(name: "screen_width", value: "1920"),
            URLQueryItem(name: "tz_name", value: "Europe/Paris"),
            URLQueryItem(name: "webcast_language", value: "fr-FR")
        ]
    }

    private static func savedURL(_ path: String, extra: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://www.tiktok.com" + path)!
        components.queryItems = savedBaseQuery() + extra
        return components.url!
    }

    /// Liste des dossiers de favoris du compte (`secUid`) : `publicOnly`
    /// demande aussi les dossiers privés, servis au compte propriétaire seul —
    /// c'est bien le but, la session est la sienne.
    public static func collectionListURL(secUid: String, cursor: String, count: Int = savedPageSize) -> URL {
        savedURL("/api/user/collection_list/", extra: [
            URLQueryItem(name: "secUid", value: secUid),
            URLQueryItem(name: "cursor", value: cursor.isEmpty ? "0" : cursor),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "coverFormat", value: "2"),
            URLQueryItem(name: "needPinnedItemIds", value: "true"),
            URLQueryItem(name: "publicOnly", value: "false")
        ])
    }

    /// Toutes les publications enregistrées du compte, dossiers compris :
    /// demi « enregistrés » de l'onglet Favoris, réservée au propriétaire.
    public static func collectItemListURL(secUid: String, cursor: String, count: Int = savedPageSize) -> URL {
        savedURL("/api/user/collect/item_list/", extra: [
            URLQueryItem(name: "secUid", value: secUid),
            URLQueryItem(name: "cursor", value: cursor.isEmpty ? "0" : cursor),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "coverFormat", value: "2"),
            URLQueryItem(name: "needPinnedItemIds", value: "true"),
            URLQueryItem(name: "post_item_list_request_type", value: "0")
        ])
    }

    /// Publications d'un seul dossier de favoris, nommé par `collectionId`
    /// (`sourceType` 113 = dossier d'enregistrés) : la requête nomme le
    /// dossier, pas une personne.
    public static func collectionItemListURL(collectionId: String, cursor: String, count: Int = savedPageSize) -> URL {
        savedURL("/api/collection/item_list/", extra: [
            URLQueryItem(name: "collectionId", value: collectionId),
            URLQueryItem(name: "cursor", value: cursor.isEmpty ? "0" : cursor),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "sourceType", value: "113")
        ])
    }

    /// Taille de page des routes sauvegardés : TikTok plafonne la liste des
    /// publications à 35.
    public static let savedPageSize = 35
}

/// Quels hôtes reçoivent les cookies de session TikTok. Les CDN de médias
/// (`tiktokcdn.com`, `tiktokv.com`, …) en sont volontairement exclus : leurs
/// URL d'images sont publiques et signées, et les identifiants de session ne
/// doivent jamais quitter `tiktok.com`. Modèle calqué sur `XTwitterCookiePolicy`.
public enum TikTokCookiePolicy {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    /// Session WebKit détectée dès qu'un `sessionid` TikTok non expiré existe.
    /// `ttwid` reste obligatoire pour les appels API paginés.
    public static func hasLoginCookie(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        matchingCookies(cookies, for: TikTokAPI.profileURL(username: "tiktok"), now: now)
            .contains { $0.name == "sessionid" && !$0.value.isEmpty }
    }

    public static func hasCredentials(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        let matching = matchingCookies(cookies, for: TikTokAPI.profileURL(username: "tiktok"), now: now)
        return ["sessionid", "ttwid"].allSatisfy { name in
            matching.contains { $0.name == name && !$0.value.isEmpty }
        }
    }

    /// Jeton `msToken` exigé en paramètre des appels `item_list`. Il peut
    /// apparaître après la session : son absence ne prouve pas une déconnexion.
    public static func msToken(cookies: [HTTPCookie], now: Date = Date()) -> String? {
        matchingCookies(cookies, for: TikTokAPI.profileURL(username: "tiktok"), now: now)
            .first { $0.name == "msToken" && !$0.value.isEmpty }?.value
    }

    public static func header(cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> String? {
        let matching = matchingCookies(cookies, for: url, now: now)
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    private static func matchingCookies(_ cookies: [HTTPCookie], for url: URL, now: Date) -> [HTTPCookie] {
        guard allows(url), let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard bare == "tiktok.com" || bare.hasSuffix(".tiktok.com") else { return false }
            let hostMatches = host == bare || host.hasSuffix("." + bare)
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return hostMatches && pathMatches && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        }
    }
}

/// Connexion WebKit directe à TikTok, sans accueil ni fil web intégré.
public enum TikTokWebNavigation {
    /// TikTok ouvre sa connexion dans une fenêtre dédiée ; la page d'accueil
    /// suffit : le bouton « Se connecter » y est toujours présent, et les
    /// cookies de session sont posés quel que soit le chemin suivi.
    public static let loginURL = URL(string: "https://www.tiktok.com/")!

    /// Hôtes des fournisseurs de connexion sociale de TikTok : Google,
    /// Facebook et Apple. La fenêtre de connexion quitte tiktok.com quand un
    /// bouton « Continuer avec… » est suivi. Ces hôtes ne reçoivent jamais les
    /// cookies de session : `TikTokCookiePolicy` reste limitée à tiktok.com.
    static let oauthHosts: Set<String> = [
        "accounts.google.com", "accounts.youtube.com",
        "facebook.com", "www.facebook.com", "m.facebook.com", "web.facebook.com",
        "appleid.apple.com", "appleid.cdn-apple.com"
    ]

    /// Navigation principale de la fenêtre de connexion : tiktok.com et les
    /// fournisseurs de connexion sociale. Une adresse hostile
    /// (`tiktok.com.attacker.example`) reste refusée.
    public static func allowsLogin(_ url: URL) -> Bool {
        TikTokCookiePolicy.allows(url) || isOAuthHost(url)
    }

    /// Les fenêtres contextuelles TikTok suivent les mêmes règles : un
    /// fournisseur peut ouvrir son formulaire dans une popup.
    public static func allowsPopup(_ url: URL) -> Bool {
        allowsLogin(url)
    }

    static func isOAuthHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return oauthHosts.contains(host)
    }
}

/// Un média publié par un compte TikTok, avec l'URL déjà choisie dans la
/// meilleure qualité que TikTok publie pour ce média.
///
/// Diaporamas : chaque image de `imagePost.images`, dans l'ordre publié.
/// Vidéos : `playAddr` est la version servie au lecteur web sans filigrane ;
/// `downloadAddr` la repli signée mais filigranée.
public struct TikTokMedia: Hashable, Sendable {
    /// Nature du média, pour l'extension et la dédouplication.
    public enum Kind: String, Sendable {
        case image, video

        public var fileExtension: String {
            switch self {
            case .image: return "jpg"
            case .video: return "mp4"
            }
        }
    }

    /// Identifiant du média, immuable, servant de clé de dédoublonnage.
    public let id: String
    public let kind: Kind
    public let url: URL
    /// Variante d'encodage choisie (`GearName` + débit), pour le diagnostic.
    /// `nil` pour les images ; une vidéo sans variante annoncée est étiquetée
    /// du champ de repli utilisé.
    public let quality: String?

    public init(id: String, kind: Kind, url: URL, quality: String? = nil) {
        self.id = id; self.kind = kind; self.url = url; self.quality = quality
    }
}

public extension TikTokMedia {
    /// Clé de dédoublonnage et de nom de fichier : `tkm-<post>-<position>`
    /// pour une image de diaporama, `tkv-<post>` pour une vidéo.
    ///
    /// `FilenamePolicy.tikTokMediaID` relit exactement cette forme depuis le
    /// nom présent sur disque pour ne pas retélécharger le média. Les deux
    /// vivent dans `MediaCore` et doivent évoluer ensemble : produire la clé
    /// ailleurs ferait retomber silencieusement le fichier en « nouveau » à
    /// chaque lancement.
    var storageKey: String {
        switch kind {
        case .image: return "tkm-\(id)"
        case .video: return "tkv-\(id)"
        }
    }
}

/// Une publication du compte, avec tous ses médias.
public struct TikTokPost: Sendable {
    public let id: String
    public let text: String
    public let publishedAt: Date?
    public let media: [TikTokMedia]

    public init(id: String, text: String, publishedAt: Date?, media: [TikTokMedia]) {
        self.id = id; self.text = text; self.publishedAt = publishedAt; self.media = media
    }
}

/// Une page du fil des publications, avec le curseur de la page suivante.
public struct TikTokMediaPage: Sendable {
    public let posts: [TikTokPost]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(posts: [TikTokPost], nextCursor: String?, hasMore: Bool) {
        self.posts = posts; self.nextCursor = nextCursor; self.hasMore = hasMore
    }
}

/// Dossier de favoris TikTok (« collection ») du compte connecté : un nom
/// et son identifiant stable servi par `/api/user/collection_list`.
public struct TikTokSavedCollection: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let itemCount: Int

    public init(id: String, name: String, itemCount: Int) {
        self.id = id; self.name = name; self.itemCount = itemCount
    }
}

/// Lecteur des pages TikTok : HTML du profil (données `__UNIVERSAL_DATA_
/// FOR_REHYDRATION__`) et réponses `api/…/item_list`.
///
/// Le format est un graphe profondément imbriqué dont les niveaux changent
/// quand TikTok ajuste son front. Le parcours est volontairement tolérant : un
/// nœud absent est ignoré, et seule l'absence de *toute* structure exploitable
/// est signalée comme `invalidTimeline`, ce qui couvre une route périmée ou
/// une page de vérification sans la confondre avec un compte sans média.
public enum TikTokWeb {
    /// Profil public : `secUid` du compte, et les publications embarquées dans
    /// la page quand TikTok les fournit (première page gratuite).
    public struct Profile: Sendable {
        public let secUid: String
        public let posts: [TikTokPost]

        public init(secUid: String, posts: [TikTokPost]) {
            self.secUid = secUid; self.posts = posts
        }
    }

    /// Résout `@pseudo` en `secUid` depuis le HTML du profil.
    public static func parseProfile(_ data: Data) throws -> Profile {
        let html = String(decoding: data, as: UTF8.self)
        guard let start = html.range(of:#"id="__UNIVERSAL_DATA_FOR_REHYDRATION__""#),
              let open = html[start.upperBound...].range(of: ">"),
              let close = html[open.upperBound...].range(of: "</script>") else {
            throw TikTokError.invalidTimeline
        }
        return try parseProfileData(String(html[open.upperBound..<close.lowerBound]))
    }

    /// Résout `@pseudo` en `secUid` depuis le JSON du script d'hydratation
    /// d'une page profil, tel que la page en cours le porte — sert à lire le
    /// compte connecté dans la WebView sans télécharger le HTML deux fois.
    public static func parseProfileData(_ json: String) throws -> Profile {
        guard let payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let scope = dictionary(payload, "__DEFAULT_SCOPE__"),
              let detail = dictionary(scope, "webapp.user-detail") else {
            throw TikTokError.invalidTimeline
        }
        guard let user = dictionary(dictionary(detail, "userInfo"), "user"),
              let secUid = text(user, "secUid"), !secUid.isEmpty else {
            // Un compte inexistant ou privé arrive ici : TikTok renvoie une
            // page sans `userInfo`, ou avec un code d'erreur.
            throw TikTokError.unknownAccount
        }
        let posts = posts(from: objects(detail, "itemList") ?? [])
        return Profile(secUid: secUid, posts: posts)
    }

    /// Une page de la liste des dossiers de favoris du compte connecté
    /// (`/api/user/collection_list`). Les nœuds bruts portent `collectionId`,
    /// `name` et `total` (chaîne ou nombre selon le front) ; l'enveloppe
    /// pagine comme `item_list` (`hasMore`, `cursor`), avec la liste sous
    /// `collectionList`.
    public static func parseCollectionList(_ data: Data) throws -> [TikTokSavedCollection] {
        try parseCollectionListPage(data).folders
    }

    /// La même page, avec son curseur de suite et sa fin annoncée : la liste
    /// des dossiers peut dépasser une page.
    public static func parseCollectionListPage(_ data: Data) throws -> (folders: [TikTokSavedCollection], nextCursor: String?, hasMore: Bool) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TikTokError.invalidTimeline
        }
        let raw = objects(root, "collectionList") ?? objects(root, "collections") ?? []
        var out: [TikTokSavedCollection] = []
        var seen = Set<String>()
        for node in raw {
            let id = text(node, "collectionId")
                ?? text(node, "collection_id")
                ?? ((node["collectionId"] as? NSNumber)?.stringValue)
            guard let id, !id.isEmpty, seen.insert(id).inserted else { continue }
            let name = text(node, "name") ?? id
            let count = (text(node, "total")).flatMap { Int($0) } ?? number(node, "total")
            out.append(TikTokSavedCollection(id: id, name: name, itemCount: count))
        }
        let cursor: String?
        if let value = root["cursor"] as? String { cursor = value.isEmpty ? nil : value }
        else if let value = root["cursor"] as? NSNumber { cursor = value.stringValue }
        else { cursor = nil }
        return (out, raw.isEmpty ? nil : cursor, number(root, "hasMore") != 0)
    }

    /// Une page de la liste des publications. Les entrées sans média
    /// exploitable sont ignorées.
    public static func parseItemList(_ data: Data) throws -> TikTokMediaPage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TikTokError.invalidTimeline
        }
        let rawItems = objects(root, "itemList") ?? []
        let posts = posts(from: rawItems)
        let hasMore = number(root, "hasMore") != 0
        // `cursor` arrive en chaîne ou en nombre selon la version du front.
        let cursor: String?
        if let value = root["cursor"] as? String { cursor = value.isEmpty ? nil : value }
        else if let value = root["cursor"] as? NSNumber { cursor = value.stringValue }
        else { cursor = nil }
        return TikTokMediaPage(posts: posts, nextCursor: rawItems.isEmpty ? nil : cursor, hasMore: hasMore)
    }

    /// Publications lisibles d'une liste brute : identifiant, texte, date et
    /// médias, sans doublon d'identifiant. Les entrées sans média exploitable
    /// (texte seul, épingle sans média) sont ignorées.
    private static func posts(from rawItems: [[String: Any]]) -> [TikTokPost] {
        var posts: [TikTokPost] = []
        var seenPosts = Set<String>()
        for item in rawItems {
            guard let id = text(item, "id") ?? text(item, "aweme_id"),
                  !id.isEmpty, seenPosts.insert(id).inserted else { continue }
            let media = mediaList(item)
            guard !media.isEmpty else { continue }
            posts.append(TikTokPost(id: id, text: text(item, "desc") ?? "",
                                    publishedAt: parseDate(text(item, "createTime")), media: media))
        }
        return posts
    }

    /// Médias d'une publication, dans l'ordre publié, sans doublon
    /// d'identifiant. Un diaporama et une vidéo s'excluent : TikTok ne publie
    /// jamais les deux sur la même entrée, l'image prime si les deux existent.
    static func mediaList(_ item: [String: Any]) -> [TikTokMedia] {
        var seen = Set<String>()
        var out: [TikTokMedia] = []
        for (index, image) in (objects(dictionary(item, "imagePost"), "images") ?? []).enumerated() {
            guard let url = firstURL(dictionary(image, "imageURL"), "urlList"),
                  isMediaHost(url), seen.insert("i\(index)-\(url.absoluteString)").inserted else { continue }
            out.append(TikTokMedia(id: "\(itemID(item))-\(index + 1)", kind: .image, url: url))
        }
        guard out.isEmpty else { return out }
        let video = dictionary(item, "video")
        // Qualité maximale : TikTok encode chaque vidéo en plusieurs variantes
        // listées dans `bitrateInfo` (540p, 720p, 1080p…), et `playAddr` seul
        // ne sert que la variante standard. La variante au débit le plus
        // élevé est la meilleure définition disponible. La casse des clés
        // varie selon la version du front : toutes les graphies sont essayées.
        var bestURL: URL?
        var bestLabel: String?
        var bestBitrate = 0
        var bestHeight = 0
        let variants = objects(video, "bitrateInfo") ?? objects(video, "BitrateInfo")
            ?? objects(video, "bitrate_info") ?? []
        for variant in variants {
            let bitrate = max(number(variant, "Bitrate"), number(variant, "bitrate"))
            let playNode = dictionary(variant, "PlayAddr") ?? dictionary(variant, "playAddr")
            let url = firstURL(playNode, "urlList") ?? firstURL(playNode, "UrlList")
                ?? text(variant, "PlayAddr").flatMap(URL.init(string:))
                ?? text(variant, "playAddr").flatMap(URL.init(string:))
            guard let url, isMediaHost(url) else { continue }
            let gear = text(variant, "GearName") ?? text(variant, "gearName") ?? ""
            // Le nom de variante porte la définition (`adapt_lowest_1080_1`,
            // `adapt_lower_720_1`…) : la définition prime sur le débit — un
            // 1080p à débit plus bas reste plus fin qu'un 720p — et le débit
            // tranche à définition égale. (3 à 4 chiffres : les fps à 2
            // chiffres et l'index final à 1 ne polluent pas la lecture.)
            let height = gear.range(of: "\\d{3,4}", options: .regularExpression)
                .flatMap { Int(gear[$0]) } ?? 0
            guard height > bestHeight || (height == bestHeight && bitrate > bestBitrate) else { continue }
            bestHeight = height
            bestBitrate = bitrate
            bestURL = url
            bestLabel = "\(gear) (\(bitrate / 1000) kbps)"
        }
        if let url = bestURL, seen.insert(url.absoluteString).inserted {
            out.append(TikTokMedia(id: itemID(item), kind: .video, url: url, quality: bestLabel))
            return out
        }
        for key in ["playAddr", "downloadAddr"] {
            guard let raw = text(video, key), let url = URL(string: raw),
                  isMediaHost(url), seen.insert(url.absoluteString).inserted else { continue }
            out.append(TikTokMedia(id: itemID(item), kind: .video, url: url, quality: "\(key) (standard)"))
            break
        }
        return out
    }

    private static func itemID(_ item: [String: Any]) -> String {
        text(item, "id") ?? text(item, "aweme_id") ?? ""
    }

    /// Première URL https d'une liste `urlList`, déséchappée au besoin : le
    /// JSON de TikTok sérialise parfois `/` en `\u002F`, que `URL(string:)`
    /// refuse tel quel.
    static func firstURL(_ node: [String: Any]?, _ key: String) -> URL? {
        guard let list = node?[key] as? [Any] else { return nil }
        for entry in list {
            guard let raw = entry as? String, !raw.isEmpty else { continue }
            let unescaped = raw
                .replacingOccurrences(of: "\\u002F", with: "/")
                .replacingOccurrences(of: "\\u0026", with: "&")
            if let url = URL(string: unescaped), url.scheme?.lowercased() == "https" { return url }
            if let url = URL(string: unescaped.replacingOccurrences(of: "http://", with: "https://")) { return url }
        }
        return nil
    }

    /// Seuls les hôtes de publication de TikTok sont acceptés : une URL
    /// d'hôte tiers dans la réponse ne doit pas être téléchargée.
    static func isMediaHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
            || host.hasSuffix(".tiktokcdn.com") || host.hasSuffix(".tiktokcdn-us.com")
            || host.hasSuffix(".tiktokv.com") || host.hasSuffix(".byteoversea.com")
    }

    private static func dictionary(_ node: Any?, _ key: String) -> [String: Any]? {
        guard let container = node as? [String: Any] else { return nil }
        return container[key] as? [String: Any]
    }

    private static func objects(_ node: [String: Any]?, _ key: String) -> [[String: Any]]? {
        guard let node else { return nil }
        return node[key] as? [[String: Any]]
    }

    private static func text(_ node: [String: Any]?, _ key: String) -> String? {
        guard let node else { return nil }
        return node[key] as? String
    }

    private static func number(_ node: [String: Any]?, _ key: String) -> Int {
        guard let node else { return 0 }
        return (node[key] as? NSNumber)?.intValue ?? 0
    }

    /// `createTime` de TikTok est un secondaire Unix, en chaîne ou en nombre.
    static func parseDate(_ text: String?) -> Date? {
        guard let text, let seconds = Double(text), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

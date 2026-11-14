import Foundation

public enum TikTokError: LocalizedError {
    case invalidUsername, loginRequired, unknownAccount, deniedAccess, invalidTimeline, tooManyPages, invalidPageLimit, postUnsupported

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
        }
    }
}

/// Surface publique de tiktok.com utilisée par la source `tt/`. Comme x.com,
/// TikTok ne sert les médias d'un profil qu'à un navigateur : les pages et
/// l'API interne exigent les cookies posés par WebKit (`sessionid` pour la
/// session, `ttwid` pour l'appareil, `msToken` pour les appels paginés), voir
/// `TikTokSession`. Les `queryId` de X n'ont pas d'équivalent stable ici :
/// la route `api/post/item_list` est adressée sans signature, et son échec se
/// manifeste par une réponse vide signalée `invalidTimeline`.
public enum TikTokAPI {
    /// Profil WebKit et page web attendent un navigateur : TikTok refuse l'UA
    /// applicatif comme le stockage X-Fetish refuse le sien.
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

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

    /// Une page du fil des publications du compte. `cursor` nil = première
    /// page ; sinon le curseur renvoyé par la page précédente.
    public static func itemListURL(secUid: String, cursor: String?, msToken: String?) -> URL {
        var components = URLComponents(string: "https://www.tiktok.com/api/post/item_list/")!
        var items = [
            URLQueryItem(name: "aid", value: "1988"),
            URLQueryItem(name: "cookie_enabled", value: "true"),
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "sourceType", value: "8"),
            URLQueryItem(name: "secUid", value: secUid)
        ]
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let msToken, !msToken.isEmpty { items.append(URLQueryItem(name: "msToken", value: msToken)) }
        components.queryItems = items
        return components.url!
    }

    /// En-têtes des requêtes TikTok (page profil et API). Le Referer de la
    /// page profil est exigé par l'API web, et l'UA navigateur par les deux.
    public static func headers(referer: URL) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": referer.absoluteString,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    /// En-têtes des transferts de médias. Les URL vidéo exigent le Referer de
    /// tiktok.com (anti-hotlink) et l'UA navigateur lié aux cookies.
    public static func mediaHeaders() -> [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": "https://www.tiktok.com/"
        ]
    }
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

    public init(id: String, kind: Kind, url: URL) {
        self.id = id; self.kind = kind; self.url = url
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

/// Lecteur des pages TikTok : HTML du profil (données `__UNIVERSAL_DATA_
/// FOR_REHYDRATION__`) et réponses `api/post/item_list`.
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
        let json = String(html[open.upperBound..<close.lowerBound])
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
        for key in ["playAddr", "downloadAddr"] {
            guard let raw = text(video, key), let url = URL(string: raw),
                  isMediaHost(url), seen.insert(url.absoluteString).inserted else { continue }
            out.append(TikTokMedia(id: itemID(item), kind: .video, url: url))
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

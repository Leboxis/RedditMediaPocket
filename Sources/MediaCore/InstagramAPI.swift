import Foundation

public enum InstagramError: LocalizedError {
    case invalidUsername, postUnsupported, unknownAccount, loginRequired, invalidResponse, tooManyPages, rateLimited

    public var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return L("Pseudo Instagram invalide (1 à 30 lettres, chiffres, points ou underscores, ex. ig/pseudo).", "Invalid Instagram username (1 to 30 letters, digits, dots or underscores, e.g. ig/username).")
        case .postUnsupported:
            return L("Les publications Instagram isolées ne sont pas prises en charge. Colle l'adresse du profil : les médias de ses publications seront parcourus.", "Single Instagram posts are not supported. Paste the profile address instead: the media of its posts will be scanned.")
        case .unknownAccount:
            return L("Compte Instagram introuvable, privé ou fermé : les médias publics de ce profil sont inaccessibles.", "Instagram account not found, private or closed: this profile's public media is inaccessible.")
        case .loginRequired:
            return L("Instagram exige une connexion pour servir ce profil (mur de connexion). Les profils publics anonymes restent lisibles, celui-ci ne l'est pas présentement.", "Instagram requires a sign-in to serve this profile (login wall). Anonymous public profiles remain readable; this one is not at the moment.")
        case .invalidResponse:
            return L("Réponse Instagram illisible : l'interface d'Instagram a peut-être changé, ou une vérification est exigée. Réessaie plus tard.", "Unreadable Instagram response: Instagram's interface may have changed, or a verification is required. Try again later.")
        case .tooManyPages:
            return L("Trop de pages de publications Instagram à parcourir.", "Too many Instagram post pages to scan.")
        case .rateLimited:
            return L("Instagram limite les requêtes anonymes (quota dépassé). Réessaie dans quelques minutes.", "Instagram is rate-limiting anonymous requests (quota exceeded). Try again in a few minutes.")
        }
    }
}

/// Surface publique web d'Instagram utilisée par la source `ig/`.
///
/// L'ancienne API anonyme (`api/v1/users/web_profile_info`, puis
/// `api/v1/feed/user/<id>`) est fermée : Instagram répond désormais 404 à tout
/// client non connecté, quel que soit l'agent ou l'en-tête d'application. Le
/// seul chemin anonyme qui reste est celui qu'emprunte le site lui-même :
///
/// 1. la page publique du profil, qui livre le jeton `lsd` (et `fb_dtsg`) ;
/// 2. `POST graphql/query` avec l'identifiant de requête `doc_id` des
///    publications du profil et la variable `username`.
///
/// Fin octobre 2026, Instagram a renommé la requête
/// (`PolarisProfilePostsQuery` → `PolarisProfilePostsTabContentQuery`),
/// changé son `doc_id` et durci ses variables obligatoires : les anciens
/// clients reçoivent `missing_required_variable_value` et ne gardent que le
/// repli SEO, sans vidéos. La forme ci-dessous est celle que le site envoie
/// lui-même depuis ce changement.
///
/// Cette route reste soumise à un quota par adresse : quand Instagram le
/// signale (`Rate limit exceeded`, code 1675004), le parcours se rabat sur le
/// rendu SEO de la page (agent Googlebot), qui expose les douze dernières
/// publications avec leurs images, sans pagination ni URL vidéo.
public enum InstagramAPI {
    /// Agent du site web : l'identifiant d'application ci-dessous est celui de
    /// cette interface, et un agent différent se voit opposer un refus.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// Agent du rendu SEO : Instagram sert alors la page du profil déjà remplie
    /// (douze dernières publications), sans jeton ni quota.
    public static let crawlerUserAgent = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

    /// Identifiant d'application web, embarqué dans le site et exigé sur
    /// chaque appel `api/graphql` anonyme.
    public static let appID = "936619743392459"

    /// Identifiant de la requête GraphQL « publications d'un profil »
    /// (`PolarisProfilePostsTabContentQuery`), lu dans le paquet web
    /// d'instagram.com. Instagram l'a changé fin octobre 2026 avec le
    /// renommage de la requête : l'ancien identifiant répond
    /// `missing_required_variable_value`.
    public static let postsQueryID = "28544666141895803"

    /// Nom de la requête tel que le site l'envoie, repris dans l'en-tête
    /// `X-FB-Friendly-Name` et le champ `fb_api_req_friendly_name` du corps.
    public static let postsQueryName = "PolarisProfilePostsTabContentQuery_connection"

    /// Champ racine de la réponse, annoncé par l'en-tête `X-Root-Field-Name`.
    static let postsRootField = "xdt_api__v1__feed__user_timeline_graphql_connection"

    /// Un pseudo Instagram fait 1 à 30 caractères : lettres, chiffres, points
    /// ou underscores, et ne finit pas par un point.
    public static func username(_ text: String) throws -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("ig/") { name = String(name.dropFirst(3)) }
        else if name.hasPrefix("@") { name = String(name.dropFirst()) }
        // Adresse de profil collée depuis un partage : `instagram.com/<pseudo>`.
        if let range = name.range(of: "(?:^|//)(?:www\\.)?instagram\\.com/", options: .regularExpression) {
            name = String(name[range.upperBound...])
            name = String(name.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name = String(name.dropFirst()) }
        guard name.range(of: "^[A-Za-z0-9._]{1,30}$", options: .regularExpression) != nil,
              !name.hasSuffix(".") else {
            throw InstagramError.invalidUsername
        }
        return name
    }

    /// Adresse d'une publication isolée (`instagram.com/p/<code>`, `/reel/`,
    /// `/reels/`, `/tv/`). Détectée seulement pour refuser la saisie avec un
    /// message utile : ce cas n'est pas pris en charge, et le dire vaut mieux
    /// qu'une erreur de pseudo (« p » n'est pas un compte).
    public static func isPostURL(_ text: String) -> Bool {
        text.range(of: "(?:^|//)(?:www\\.)?instagram\\.com/(?:p|reel|reels|tv)/",
                   options: .regularExpression) != nil
    }

    /// Page publique du profil : elle porte les jetons d'API anonymes
    /// (`lsd`, `csrf_token`) et, servie à l'agent SEO, les publications.
    public static func profilePageURL(username: String) -> URL {
        URL(string: "https://www.instagram.com/\(username)/")!
    }

    /// Point GraphQL paginé du site : c'est lui que le navigateur appelle
    /// pour la liste paginée des publications d'un profil (la route
    /// `api/graphql` ne sert plus que les requêtes isolées).
    public static var postsURL: URL { URL(string: "https://www.instagram.com/graphql/query")! }

    /// Jetons lus dans la page du profil. Sans eux, l'appel GraphQL est refusé.
    public struct Tokens: Sendable, Equatable {
        public let lsd: String
        public let csrf: String
        /// Jeton `fb_dtsg` de la page, facultatif : le point `graphql/query`
        /// le redemanderait sinon. Vide quand la page n'en publie pas.
        public let dtsg: String

        public init(lsd: String, csrf: String, dtsg: String = "") {
            self.lsd = lsd; self.csrf = csrf; self.dtsg = dtsg
        }
    }

    /// Extrait `lsd` (exigé) et `csrf_token` (facultatif, absent de certaines
    /// variantes de page) du HTML de la page de profil.
    /// `cookies` porte les en-têtes `Set-Cookie` de la page : le `csrf_token`
    /// n'est plus publié dans le HTML, il n'arrive que par ce cookie.
    public static func tokens(inHTML data: Data, cookies: String? = nil) -> Tokens? {
        let html = String(decoding: data, as: UTF8.self)
        guard let lsd = firstGroup(#""LSD",\[\],\{"token":"([^"]+)""#, in: html) else { return nil }
        let csrf = firstGroup(#""csrf_token":"([A-Za-z0-9_-]+)""#, in: html)
            ?? firstGroup(#"csrftoken=([A-Za-z0-9_-]+)"#, in: cookies ?? "")
            ?? ""
        let dtsg = firstGroup(#""dtsg":\{"token":"([^"]+)""#, in: html) ?? ""
        return Tokens(lsd: lsd, csrf: csrf, dtsg: dtsg)
    }

    /// En-têtes de la page du profil, lue avec l'agent du site.
    public static func pageHeaders(referer: URL, sessionCookies: String? = nil) -> [String: String] {
        var fields = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": referer.absoluteString
        ]
        // Session connectée : la page est lue avec ses cookies, sans mur de
        // connexion, et livre ses propres jetons.
        if let cookies = sessionCookies, !cookies.isEmpty { fields["Cookie"] = cookies }
        return fields
    }

    /// En-têtes du rendu SEO (repli), lu avec l'agent d'indexation.
    public static func crawlerHeaders() -> [String: String] {
        [
            "User-Agent": crawlerUserAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    /// En-têtes de l'appel `graphql/query` : identifiant d'application, jetons
    /// de la page et marqueurs d'origine que le site envoie lui-même.
    public static func graphqlHeaders(tokens: Tokens, referer: URL,
                                      sessionCookies: String? = nil) -> [String: String] {
        var fields = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "X-IG-App-ID": appID,
            "X-IG-D": "www",
            "X-FB-LSD": tokens.lsd,
            // Nom de requête et marqueurs du client web connecté ; sans eux,
            // Instagram peut servir la coquille HTML de l'application.
            "X-FB-Friendly-Name": postsQueryName,
            "X-ASBD-ID": "359341",
            "X-IG-Max-Touch-Points": "0",
            "X-Root-Field-Name": postsRootField,
            "Alt-Used": "www.instagram.com",
            "X-IG-WWW-Claim": "0",
            "Origin": "https://www.instagram.com",
            "Referer": referer.absoluteString,
            // Sans ces marqueurs d'origine, Instagram sert la coquille HTML de
            // l'application au lieu de la réponse d'API.
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin"
        ]
        if let cookies = sessionCookies, !cookies.isEmpty {
            // Session connectée : ses cookies portent `sessionid` et son propre
            // `csrftoken`, et remplacent les jetons anonymes.
            fields["Cookie"] = cookies
            if let csrf = firstGroup(#"csrftoken=([A-Za-z0-9_-]+)"#, in: cookies) {
                fields["X-CSRFToken"] = csrf
                fields["X-CSRF-Token"] = csrf
            }
        } else if !tokens.csrf.isEmpty {
            fields["X-CSRFToken"] = tokens.csrf
            fields["X-CSRF-Token"] = tokens.csrf
            fields["Cookie"] = "csrftoken=\(tokens.csrf)"
        }
        return fields
    }

    /// Corps `application/x-www-form-urlencoded` de la requête des
    /// publications : jetons, identification de la requête Relay (`doc_id`,
    /// nom amical), variables (JSON) et horodatages serveur. `after` est le
    /// curseur de la page précédente. Les champs `data`, `include_multi_captions`
    /// et le relais `PolarisSEOIsCrawler` sont exigés par la requête renommée
    /// d'octobre 2026 : sans eux, Instagram répond
    /// `missing_required_field_value`.
    public static func postsRequestBody(tokens: Tokens, username: String, cursor: String?,
                                        count: Int = 12,
                                        operation: InstagramRelayOperation? = nil) -> Data {
        let data: [String: Any] = [
            "count": count,
            "include_reel_media_seen_timestamp": true,
            "include_relationship_info": true,
            "latest_besties_reel_media": true,
            "latest_reel_media": true
        ]
        var variables: [String: Any] = [
            "after": cursor ?? NSNull(),
            "before": NSNull(),
            "data": data,
            "first": count,
            "include_multi_captions": true,
            "last": NSNull(),
            "username": username
        ]
        // Variables Relay : leur liste vient des paquets de la page, elle
        // change avec l'interface. `PolarisSEOIsCrawler` vaut faux pour un
        // client ordinaire, les autres reprennent la valeur par défaut du
        // site.
        for param in operation?.relayParams ?? ["PolarisSEOIsCrawler"] {
            variables["__relay_internal__pv__\(param)relayprovider"] = (param != "PolarisSEOIsCrawler")
        }
        let json = (try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        // `jazoest` est une somme de contrôle héritée que le site joint à
        // chaque envoi Relay ; le serveur ne la vérifie pas. La valeur du
        // client web est reprise telle quelle plutôt que recalculée sur un
        // jeton `dtsg` facultatif.
        let pairs = [
            // Champs de session du client web, constants pour un client anonyme
            // comme pour un compte connecté.
            "av=17841415137994167",
            "__d=www",
            "__user=0",
            "__a=1",
            "__req=0",
            "dpr=1",
            "__ccg=EXCELLENT",
            "__rev=1049285836",
            "__hsi=7693193318680449885",
            "__hs=20731.HYP%3Ainstagram_web_pkg.2.1...0",
            "__comet_req=7",
            "fb_dtsg=" + formEncode(tokens.dtsg),
            "jazoest=26461",
            "lsd=" + formEncode(tokens.lsd),
            "fb_api_caller_class=RelayModern",
            "fb_api_req_friendly_name=" + formEncode(postsQueryName),
            "server_timestamps=true",
            "variables=" + formEncode(String(decoding: json, as: UTF8.self)),
            "doc_id=" + formEncode(operation?.docID ?? postsQueryID)
        ]
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// Route REST du site, servie au client connecté : la même réponse que la
    /// page de profil, mais en JSON, avec `video_url` sur les vidéos. Lecture
    /// seule (GET), donc sans jeton CSRF — c'est le chemin le plus robuste
    /// quand `api/graphql` refuse la requête connectée.
    public static func profileInfoURL(username: String, count: Int = 50) -> URL {
        URL(string: "https://www.instagram.com/api/v1/users/web_profile_info/?username=\(formEncode(username))&count=\(count)")!
    }

    /// En-têtes de la route REST : identifiant d'application, marqueurs
    /// d'origine et cookies de session. Sans session, elle répond 429.
    public static func profileInfoHeaders(referer: URL, sessionCookies: String?) -> [String: String] {
        var fields = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "X-IG-App-ID": appID,
            "X-IG-D": "www",
            "X-Requested-With": "XMLHttpRequest",
            "Referer": referer.absoluteString,
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin"
        ]
        if let cookies = sessionCookies, !cookies.isEmpty { fields["Cookie"] = cookies }
        return fields
    }

    /// En-têtes des transferts de médias : le CDN d'Instagram exige le
    /// Referer du profil contre l'appel à chaud depuis une autre page.
    public static func mediaHeaders(referer: URL) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": referer.absoluteString
        ]
    }

    /// En-têtes des paquets JavaScript servis avec la page : le CDN statique
    /// les rend à l'agent du site, avec le Referer de la page.
    public static func scriptHeaders(referer: URL) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Referer": referer.absoluteString
        ]
    }

    static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    static func firstGroup(_ pattern: String, in text: String,
                           options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Requête Relay des publications, telle que le paquet web d'Instagram la
/// publie. Le nom et le `doc_id` changent quand Instagram renomme son
/// interface, et la liste des variables `__relay_internal__pv__…` qu'elle
/// exige change aussi — sans prévenir, et sans être déductible de la réponse
/// d'erreur. Seule source fiable : les paquets JavaScript servis avec la page.
public struct InstagramRelayOperation: Sendable, Equatable {
    public let docID: String
    /// Noms des fournisseurs Relay exigés, sans le préfixe
    /// `__relay_internal__pv__` ni le suffixe `relayprovider`.
    public let relayParams: [String]

    public init(docID: String, relayParams: [String]) {
        self.docID = docID; self.relayParams = relayParams
    }
}

public enum InstagramRelay {
    /// Nom de la requête de publications. Il sert à retrouver son `doc_id` et
    /// ses variables dans les paquets ; un renommage côté Instagram le rend
    /// introuvable, ce que le parcours signale au lieu de deviner.
    public static let operationName = "PolarisProfilePostsTabContentQuery_connection"

    /// Adresses des paquets JavaScript servis avec la page, dans l'ordre du
    /// document. Les doublons sont retirés.
    public static func scriptURLs(inHTML data: Data) -> [URL] {
        let html = String(decoding: data, as: UTF8.self)
        let pattern = #"https://static\.cdninstagram\.com/rsrc\.php/[^"'\s]+\.js"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var urls: [URL] = []
        for match in regex.matches(in: html, range: range) {
            guard let found = Range(match.range, in: html) else { continue }
            // Dans le document, l'adresse peut être échappée (`\u0025` pour
            // `%`, `\/` pour `/`) : elle est remise en forme avant usage.
            let raw = String(html[found])
                .replacingOccurrences(of: "\\u0025", with: "%")
                .replacingOccurrences(of: "\\u0026", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
            guard seen.insert(raw).inserted, let url = URL(string: raw) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// `doc_id` de la requête, lu dans un paquet JavaScript.
    public static func docID(in script: String) -> String? {
        let name = NSRegularExpression.escapedPattern(for: operationName)
        let pattern = #"__d\(""# + name + #"_instagramRelayOperation",\[\],\(function\([^)]+\).+?\bexports="([^"]+)""#
        // Un paquet est minifié sur une seule ligne, mais la définition peut
        // être coupée par un retour à la ligne : le motif traverse les lignes.
        return InstagramAPI.firstGroup(pattern, in: script, options: [.dotMatchesLineSeparators])
    }

    /// Variables Relay exigées par la requête, lues dans un paquet
    /// JavaScript : les entrées `"…relayprovider"` de sa liste de paramètres.
    public static func relayParams(in script: String) -> [String] {
        let name = NSRegularExpression.escapedPattern(for: operationName)
        let pattern = #"__d\(""# + name + #"(?:\.graphql|\$Parameters)",\[([^\]]+)\]"#
        guard let list = InstagramAPI.firstGroup(pattern, in: script,
                                                 options: [.dotMatchesLineSeparators]) else { return [] }
        return list.split(separator: ",").compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\""), text.hasSuffix(".relayprovider\"") else { return nil }
            // Retire le guillemet ouvrant et le suffixe `.relayprovider"`.
            return String(text.dropFirst().dropLast(15))
        }
    }

    /// Requête complète, quand un seul paquet porte les deux informations.
    public static func operation(in scripts: [String]) -> InstagramRelayOperation? {
        var foundDocID: String?
        var foundParams: [String] = []
        for script in scripts {
            if foundDocID == nil { foundDocID = docID(in: script) }
            if foundParams.isEmpty { foundParams = relayParams(in: script) }
            if foundDocID != nil, !foundParams.isEmpty { break }
        }
        guard let foundDocID, !foundDocID.isEmpty else { return nil }
        return InstagramRelayOperation(docID: foundDocID, relayParams: foundParams)
    }
}

/// Quels hôtes reçoivent les cookies de session Instagram. Le CDN
/// (`*.cdninstagram.com`, `*.fbcdn.net`) en reste exclu : ses URL sont signées
/// et publiques, et le jeton de session n'a aucune raison de les accompagner.
public enum InstagramCookiePolicy {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    /// Session détectée dès qu'un `sessionid` non expiré existe.
    public static func hasLoginCookie(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        matchingCookies(cookies, for: InstagramAPI.profilePageURL(username: "instagram"), now: now)
            .contains { $0.name == "sessionid" && !$0.value.isEmpty }
    }

    /// `csrftoken` accompagne obligatoirement `sessionid` sur `api/graphql` :
    /// sans lui, la requête connectée est refusée.
    public static func hasCredentials(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        let matching = matchingCookies(cookies, for: InstagramAPI.profilePageURL(username: "instagram"), now: now)
        return ["sessionid", "csrftoken"].allSatisfy { name in
            matching.contains { $0.name == name && !$0.value.isEmpty }
        }
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
            guard bare == "instagram.com" || bare.hasSuffix(".instagram.com") else { return false }
            let hostMatches = host == bare || host.hasSuffix("." + bare)
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return hostMatches && pathMatches && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        }
    }
}

/// Connexion WebKit à Instagram, sur le modèle de `TikTokWebNavigation`.
public enum InstagramWebNavigation {
    public static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!

    /// Fournisseurs de connexion sociale proposés par Instagram. Ils ne
    /// reçoivent jamais les cookies de session : `InstagramCookiePolicy` reste
    /// limitée à instagram.com.
    static let oauthHosts: Set<String> = [
        "accounts.google.com", "facebook.com", "www.facebook.com",
        "m.facebook.com", "web.facebook.com", "appleid.apple.com"
    ]

    public static func allowsLogin(_ url: URL) -> Bool {
        InstagramCookiePolicy.allows(url) || isOAuthHost(url)
    }

    public static func allowsPopup(_ url: URL) -> Bool { allowsLogin(url) }

    static func isOAuthHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return oauthHosts.contains(host)
    }
}

/// Un média Instagram : URL directe du CDN, clé stable `igm-<pk>` (image) ou
/// `igv-<pk>` (vidéo) qui entre dans le nom de fichier et sert de
/// dédoublonnage au lancement suivant.
public struct InstagramMedia: Hashable, Sendable {
    public let storageKey: String
    public let url: URL
    public let isVideo: Bool

    public init(storageKey: String, url: URL, isVideo: Bool) {
        self.storageKey = storageKey; self.url = url; self.isVideo = isVideo
    }
}

public struct InstagramPost: Sendable, Equatable {
    public let id: String
    /// Code public de la publication (`instagram.com/p/<code>/`), quand il
    /// est exposé. Les identifiants numériques ne sont pas des adresses.
    public let code: String?
    public let text: String
    public let publishedAt: Date?
    public let media: [InstagramMedia]

    public init(id: String, code: String?, text: String, publishedAt: Date?, media: [InstagramMedia]) {
        self.id = id; self.code = code; self.text = text; self.publishedAt = publishedAt; self.media = media
    }
}

public struct InstagramPage: Sendable {
    public let posts: [InstagramPost]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(posts: [InstagramPost], nextCursor: String?, hasMore: Bool) {
        self.posts = posts; self.nextCursor = nextCursor; self.hasMore = hasMore
    }
}

public enum InstagramWeb {
    /// Réponse de `graphql/query` : `data.xdt_api__v1__feed__user_timeline_graphql_connection`
    /// porte les publications (`edges[].node`) et `page_info`
    /// (`end_cursor`, `has_next_page`).
    public static func parseTimeline(_ data: Data) throws -> InstagramPage {
        guard let root = try? JSONSerialization.jsonObject(with: strippedGuard(data)) as? [String: Any] else {
            throw InstagramError.invalidResponse
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            // Quota anonyme : Instagram répond 200 avec un message d'API.
            let limited = errors.contains { error in
                (error["code"] as? Int) == 1675004
                    || ((error["message"] as? String)?.lowercased().contains("rate limit") ?? false)
            }
            throw limited ? InstagramError.rateLimited : InstagramError.invalidResponse
        }
        guard let payload = root["data"] as? [String: Any] else { throw InstagramError.invalidResponse }
        if let connection = payload["xdt_api__v1__feed__user_timeline_graphql_connection"] as? [String: Any] {
            return page(from: connection)
        }
        // La requête peut être renommée par Instagram : la connexion est alors
        // retrouvée par sa forme plutôt que par sa clé.
        guard let connection = findTimelineConnection(payload) else { throw InstagramError.invalidResponse }
        return page(from: connection)
    }

    /// `graphql/query` fait parfois précéder son JSON du garde anti-hijack
    /// `for (;;);`. Le préfixe est retiré avant le décodage ; un corps qui
    /// commence déjà par `{` est rendu tel quel.
    static func strippedGuard(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard let brace = text.firstIndex(of: "{"), brace != text.startIndex,
              text[..<brace].contains("for") else { return data }
        return Data(text[brace...].utf8)
    }

    /// Rendu SEO de la page de profil : la connexion est enfouie dans un
    /// `<script type="application/json">` du document, sous
    /// `polaris_timeline_connection`.
    public static func parseCrawlerPage(_ data: Data) throws -> InstagramPage {
        let html = String(decoding: data, as: UTF8.self)
        for script in jsonScripts(in: html) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(script.utf8)) else { continue }
            guard let connection = findTimelineConnection(root) else { continue }
            return page(from: connection)
        }
        throw InstagramError.invalidResponse
    }

    /// Réponse de `api/v1/users/web_profile_info` : `data.user` porte
    /// `edge_owner_to_timeline_media` (`edges[].node`), où chaque nœud expose
    /// `video_url` (vidéo) ou `display_url` (image), `is_video`, `shortcode` et
    /// `edge_sidecar_to_children`. Cette route ne pagine pas ici : une page
    /// unique, sans curseur.
    public static func parseProfileInfo(_ data: Data) throws -> InstagramPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstagramError.invalidResponse
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            throw InstagramError.rateLimited
        }
        guard let user = (root["data"] as? [String: Any])?["user"] as? [String: Any],
              let media = user["edge_owner_to_timeline_media"] as? [String: Any] else {
            // Corps vide ou page de connexion : aucun compte lisible.
            throw InstagramError.invalidResponse
        }
        let edges = (media["edges"] as? [[String: Any]]) ?? []
        var posts: [InstagramPost] = []
        for edge in edges {
            guard let node = edge["node"] as? [String: Any] else { continue }
            if let post = profilePost(node) { posts.append(post) }
        }
        guard !posts.isEmpty else { throw InstagramError.invalidResponse }
        return InstagramPage(posts: posts, nextCursor: nil, hasMore: false)
    }

    /// Nœud de `edge_owner_to_timeline_media` : `is_video` et `video_url` pour
    /// une vidéo, `edge_sidecar_to_children` pour un carrousel.
    private static func profilePost(_ node: [String: Any]) -> InstagramPost? {
        guard let pk = (node["id"] as? String) ?? (node["pk"] as? String), !pk.isEmpty else { return nil }
        var media: [InstagramMedia] = []
        if let children = ((node["edge_sidecar_to_children"] as? [String: Any])?["edges"] as? [[String: Any]]) {
            for edge in children {
                guard let child = edge["node"] as? [String: Any],
                      let value = profileMedia(child, postPK: pk, position: media.count + 1) else { continue }
                media.append(value)
            }
        }
        if media.isEmpty, let value = profileMedia(node, postPK: pk, position: 1) { media.append(value) }
        guard !media.isEmpty else { return nil }
        let caption = (((node["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]])?
            .first?["node"] as? [String: Any])?["text"] as? String
        let taken = node["taken_at_timestamp"] as? Double
        return InstagramPost(id: pk, code: node["shortcode"] as? String, text: caption ?? "",
                             publishedAt: taken.map { Date(timeIntervalSince1970: $0) },
                             media: media)
    }

    private static func profileMedia(_ item: [String: Any], postPK: String, position: Int) -> InstagramMedia? {
        let pk = (item["id"] as? String) ?? "\(postPK)-\(position)"
        let isVideo = (item["is_video"] as? Bool) == true
        if isVideo, let raw = item["video_url"] as? String,
           let url = URL(string: raw), url.scheme == "https" {
            return InstagramMedia(storageKey: mediaKey(pk, video: true), url: url, isVideo: true)
        }
        guard let url = bestDisplayResource(item)
            ?? (item["display_url"] as? String).flatMap(URL.init(string:)),
              url.scheme == "https" else { return nil }
        return InstagramMedia(storageKey: mediaKey(pk, video: false), url: url, isVideo: false)
    }

    /// Construit une page depuis une connexion de publications, commune aux
    /// deux formats (GraphQL et rendu SEO).
    private static func page(from connection: [String: Any]) -> InstagramPage {
        let edges = (connection["edges"] as? [[String: Any]]) ?? []
        var posts: [InstagramPost] = []
        for edge in edges {
            guard let node = edge["node"] as? [String: Any],
                  let post = feedPost(node) else { continue }
            posts.append(post)
        }
        let info = connection["page_info"] as? [String: Any]
        let cursor = info?["end_cursor"] as? String
        let more = (info?["has_next_page"] as? Bool) ?? false
        return InstagramPage(posts: posts, nextCursor: cursor, hasMore: more && !posts.isEmpty)
    }

    private static func findTimelineConnection(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            for key in ["polaris_timeline_connection", "xdt_api__v1__feed__user_timeline_graphql_connection"] {
                if let connection = dict[key] as? [String: Any] { return connection }
            }
            for child in dict.values {
                if let found = findTimelineConnection(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findTimelineConnection(child) { return found }
            }
        }
        return nil
    }

    private static func jsonScripts(in html: String) -> [String] {
        let pattern = #"<script[^>]*type="application/json"[^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    /// Publication du format `XDTMediaDict` : `pk`, `code`, `taken_at`,
    /// `caption.text`, un média ou les enfants de `carousel_media`.
    private static func feedPost(_ item: [String: Any]) -> InstagramPost? {
        guard let pk = (item["pk"] as? String) ?? (item["id"] as? String), !pk.isEmpty else { return nil }
        let taken = item["taken_at"] as? Double
        var media: [InstagramMedia] = []
        if let carousel = item["carousel_media"] as? [[String: Any]] {
            for child in carousel {
                if let value = feedMedia(child, postPK: pk, position: media.count + 1) { media.append(value) }
            }
        }
        if media.isEmpty, let value = feedMedia(item, postPK: pk, position: 1) { media.append(value) }
        guard !media.isEmpty else { return nil }
        let text = ((item["caption"] as? [String: Any])?["text"] as? String) ?? ""
        return InstagramPost(id: pk, code: item["code"] as? String, text: text,
                             publishedAt: taken.map { Date(timeIntervalSince1970: $0) },
                             media: media)
    }

    /// Média : `image_versions2.candidates` pour une image, `video_versions`
    /// pour une vidéo (`media_type` 2). Le rendu SEO ne publie jamais d'URL
    /// vidéo : la vidéo y est alors remplacée par son affiche, téléchargée
    /// comme image (clé `igm-`, extension d'image) et non comme un faux
    /// fichier vidéo.
    private static func feedMedia(_ item: [String: Any], postPK: String, position: Int) -> InstagramMedia? {
        let mediaType = item["media_type"] as? Int
        let versions = item["video_versions"] as? [[String: Any]]
        let candidates = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])
        // Dans un carrousel, chaque enfant porte son propre `pk` ; isolé,
        // l'identifiant du média est celui du post.
        let pk = (item["pk"] as? String) ?? "\(postPK)-\(position)"
        let isVideo = mediaType == 2 || versions?.isEmpty == false
        if isVideo, let url = bestVariantURL(versions, video: true) {
            return InstagramMedia(storageKey: mediaKey(pk, video: true), url: url, isVideo: true)
        }
        guard let url = bestVariantURL(candidates, video: false) else { return nil }
        return InstagramMedia(storageKey: mediaKey(pk, video: false), url: url, isVideo: false)
    }

    /// Meilleure variante d'une liste `image_versions2.candidates` ou
    /// `video_versions` : celle qui couvre la plus grande surface.
    ///
    /// L'ordre du serveur n'est pas une garantie — l'image est servie du plus
    /// grand au plus petit, la vidéo dans l'autre sens — donc se fier à la
    /// première entrée livrait la plus petite vidéo disponible. La surface
    /// tranche quel que soit l'ordre. Sans aucune dimension publiée, le repli
    /// suit l'ordre documenté : dernière entrée pour une vidéo, première pour
    /// une image.
    static func bestVariantURL(_ variants: [[String: Any]]?, video: Bool) -> URL? {
        guard let variants, !variants.isEmpty else { return nil }
        let usable = variants.filter { variant in
            guard let raw = variant["url"] as? String else { return false }
            return URL(string: raw)?.scheme == "https"
        }
        guard !usable.isEmpty else { return nil }
        let sized = usable.compactMap { variant -> (url: URL, area: Int)? in
            guard let raw = variant["url"] as? String, let url = URL(string: raw) else { return nil }
            let width = dimension(variant["width"])
            let height = dimension(variant["height"])
            guard width > 0, height > 0 else { return nil }
            return (url, width * height)
        }
        if let best = sized.max(by: { $0.area < $1.area }) { return best.url }
        let fallback = video ? usable.last : usable.first
        return (fallback?["url"] as? String).flatMap(URL.init(string:))
    }

    /// Nombre d'un champ JSON, quel que soit le type que le décodeur lui a
    /// donné (`Int`, `Double` ou `NSNumber`).
    static func dimension(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    /// Plus grande des `display_resources` d'un nœud `api/v1` : ces entrées
    /// énumèrent toutes les tailles et `display_url` n'est pas garanti d'être
    /// la plus grande.
    private static func bestDisplayResource(_ item: [String: Any]) -> URL? {
        let resources = item["display_resources"] as? [[String: Any]] ?? []
        let sized = resources.compactMap { resource -> (url: URL, area: Int)? in
            guard let raw = resource["src"] as? String, let url = URL(string: raw),
                  url.scheme == "https" else { return nil }
            let area = dimension(resource["config_width"]) * dimension(resource["config_height"])
            guard area > 0 else { return nil }
            return (url, area)
        }
        return sized.max(by: { $0.area < $1.area })?.url
    }

    /// Clé stable `igm-<chiffres>` / `igv-<chiffres>`. Les identifiants
    /// Instagram sont numériques ; un identifiant inattendu retombe sur une
    /// empreinte déterministe (jamais le hachage Swift, aléatoire à chaque
    /// exécution).
    public static func mediaKey(_ pk: String?, video: Bool) -> String {
        let prefix = video ? "igv-" : "igm-"
        let digits = (pk ?? "").filter { "0123456789".contains($0) }
        if !digits.isEmpty { return prefix + digits }
        return prefix + String(stableHash(pk ?? "instagram"))
    }

    /// Empreinte djb2 : stable entre exécutions et entre appareils.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash << 5) &+ hash &+ UInt64(byte)
        }
        return hash
    }
}

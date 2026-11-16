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
/// 1. la page publique du profil, qui livre le jeton `lsd` et le jeton
///    `csrf_token` de la session ;
/// 2. `POST /api/graphql` avec l'identifiant de requête `doc_id` des
///    publications du profil et la variable `username`.
///
/// Cette route anonyme est soumise à un quota par adresse : quand Instagram le
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
    /// (`PolarisProfilePostsQuery`), lu dans le paquet web d'instagram.com.
    public static let postsQueryID = "29114630661562380"

    /// Indicateurs de fonctionnalité joints par le site à la requête. Tous sont
    /// exigés par le serveur ; `false` reproduit le client web déconnecté.
    static let featureFlags = [
        "PolarisMultiCaptionCarouselEnabled", "PolarisShortDramaEnabled", "PolarisSEOIsCrawler",
        "PolarisThreadsStyleCommentsEnabled", "PolarisReelsRecoDebugOverlayEnabled"
    ]

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

    /// Point d'entrée GraphQL du site web, seul appel anonyme encore servi.
    public static var graphqlURL: URL { URL(string: "https://www.instagram.com/api/graphql")! }

    /// Jetons lus dans la page du profil. Sans eux, l'appel GraphQL est refusé.
    public struct Tokens: Sendable, Equatable {
        public let lsd: String
        public let csrf: String

        public init(lsd: String, csrf: String) {
            self.lsd = lsd; self.csrf = csrf
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
        return Tokens(lsd: lsd, csrf: csrf)
    }

    /// En-têtes de la page du profil, lue avec l'agent du site.
    public static func pageHeaders(referer: URL) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": referer.absoluteString
        ]
    }

    /// En-têtes du rendu SEO (repli), lu avec l'agent d'indexation.
    public static func crawlerHeaders() -> [String: String] {
        [
            "User-Agent": crawlerUserAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    /// En-têtes de l'appel `api/graphql` : identifiant d'application, jetons de
    /// la page et marqueurs d'origine que le site envoie lui-même.
    public static func graphqlHeaders(tokens: Tokens, referer: URL) -> [String: String] {
        var fields = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "X-IG-App-ID": appID,
            "X-IG-D": "www",
            "X-FB-LSD": tokens.lsd,
            "Origin": "https://www.instagram.com",
            "Referer": referer.absoluteString,
            // Sans ces marqueurs d'origine, Instagram sert la coquille HTML de
            // l'application au lieu de la réponse d'API.
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin"
        ]
        if !tokens.csrf.isEmpty {
            fields["X-CSRF-Token"] = tokens.csrf
            fields["Cookie"] = "csrftoken=\(tokens.csrf)"
        }
        return fields
    }

    /// Corps `application/x-www-form-urlencoded` de la requête des
    /// publications : `lsd`, `doc_id`, `variables` (JSON) et horodatages
    /// serveur. `after` est le curseur de la page précédente.
    public static func postsRequestBody(tokens: Tokens, username: String, cursor: String?,
                                        count: Int = 12) -> Data {
        var variables: [String: Any] = [
            "after": cursor ?? NSNull(),
            "before": NSNull(),
            "data": ["count": count],
            "first": count,
            "last": NSNull(),
            "username": username
        ]
        for flag in featureFlags {
            variables["__relay_internal__pv__\(flag)relayprovider"] = false
        }
        let json = (try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let pairs = [
            "lsd=" + formEncode(tokens.lsd),
            "doc_id=" + postsQueryID,
            "variables=" + formEncode(String(decoding: json, as: UTF8.self)),
            "server_timestamps=true"
        ]
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// En-têtes des transferts de médias : le CDN d'Instagram exige le
    /// Referer du profil contre l'appel à chaud depuis une autre page.
    public static func mediaHeaders(referer: URL) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": referer.absoluteString
        ]
    }

    static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
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
    /// Réponse de `api/graphql` : `data.xdt_api__v1__feed__user_timeline_graphql_connection`
    /// porte les publications (`edges[].node`) et `page_info`
    /// (`end_cursor`, `has_next_page`).
    public static func parseTimeline(_ data: Data) throws -> InstagramPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
    /// pour une vidéo (`media_type` 2), la meilleure candidate étant la
    /// première. Le rendu SEO ne publie jamais d'URL vidéo : la vidéo y est
    /// alors remplacée par son affiche, téléchargée comme image (clé `igm-`,
    /// extension d'image) et non comme un faux fichier vidéo.
    private static func feedMedia(_ item: [String: Any], postPK: String, position: Int) -> InstagramMedia? {
        let mediaType = item["media_type"] as? Int
        let versions = item["video_versions"] as? [[String: Any]]
        let candidates = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])
        // Dans un carrousel, chaque enfant porte son propre `pk` ; isolé,
        // l'identifiant du média est celui du post.
        let pk = (item["pk"] as? String) ?? "\(postPK)-\(position)"
        let isVideo = mediaType == 2 || versions?.isEmpty == false
        if isVideo, let raw = (versions?.first)?["url"] as? String,
           let url = URL(string: raw), url.scheme == "https" {
            return InstagramMedia(storageKey: mediaKey(pk, video: true), url: url, isVideo: true)
        }
        guard let raw = (candidates?.first)?["url"] as? String,
              let url = URL(string: raw), url.scheme == "https" else { return nil }
        return InstagramMedia(storageKey: mediaKey(pk, video: false), url: url, isVideo: false)
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

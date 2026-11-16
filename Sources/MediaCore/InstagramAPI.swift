import Foundation

public enum InstagramError: LocalizedError {
    case invalidUsername, postUnsupported, unknownAccount, loginRequired, invalidResponse, tooManyPages

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
        }
    }
}

/// Surface publique web d'Instagram utilisée par la source `ig/`. Contrairement
/// à X et TikTok, Instagram sert ses profils publics à un client anonyme qui
/// présente l'identifiant d'application web (`x-ig-app-id`) : pas de session,
/// pas de signature. Deux formats coexistent — le profil
/// (`users/web_profile_info`, style GraphQL) et le fil paginé
/// (`feed/user/<id>`, style API v1) — tous deux lus ici.
public enum InstagramAPI {
    /// Instagram exige un vrai navigateur : l'UA applicatif reçoit le mur de
    /// connexion, l'UA Safari iPhone les pages publiques.
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// Identifiant d'application web qu'instagram.com valide sur chaque appel
    /// `api/v1` anonyme. Publique, embarquée dans le site.
    public static let appID = "936619743392459"

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

    /// Page publique du profil : sert à résoudre l'identifiant numérique du
    /// compte et embarque les publications les plus récentes.
    public static func profileInfoURL(username: String) -> URL {
        var components = URLComponents(string: "https://www.instagram.com/api/v1/users/web_profile_info/")!
        components.queryItems = [URLQueryItem(name: "username", value: username)]
        return components.url!
    }

    /// Fil paginé des publications du compte, après la page de profil.
    public static func userFeedURL(userID: String, cursor: String?) -> URL {
        var components = URLComponents(string: "https://www.instagram.com/api/v1/feed/user/\(userID)/")!
        var items = [URLQueryItem(name: "count", value: "33")]
        if let cursor { items.append(URLQueryItem(name: "max_id", value: cursor)) }
        components.queryItems = items
        return components.url!
    }

    /// En-têtes des appels `api/v1` (profil et fil). L'identifiant
    /// d'application et l'UA navigateur sont exigés par Instagram.
    public static func headers(referer: URL) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "X-IG-App-ID": appID,
            "Referer": referer.absoluteString
        ]
    }

    /// En-têtes des transferts de médias : le CDN d'Instagram exige le
    /// Referer du profil contre l'appel à chaud depuis une autre page.
    public static func mediaHeaders(referer: URL) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": referer.absoluteString
        ]
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
    public struct Profile: Sendable {
        public let userID: String
        public let posts: [InstagramPost]

        public init(userID: String, posts: [InstagramPost]) {
            self.userID = userID; self.posts = posts
        }
    }

    /// Profil `web_profile_info` : `data.user.id` et les publications
    /// embarquées dans `edge_owner_to_timeline_media` (style GraphQL).
    public static func parseProfile(_ data: Data) throws -> Profile {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["data"] as? [String: Any],
              let userValue = user["user"] as? [String: Any],
              let userID = userValue["id"] as? String,
              !userID.isEmpty else {
            throw InstagramError.invalidResponse
        }
        let timeline = userValue["edge_owner_to_timeline_media"] as? [String: Any]
        let edges = (timeline?["edges"] as? [[String: Any]]) ?? []
        var posts: [InstagramPost] = []
        for edge in edges {
            guard let node = edge["node"] as? [String: Any],
                  let post = timelinePost(node) else { continue }
            posts.append(post)
        }
        return Profile(userID: userID, posts: posts)
    }

    /// Fil paginé `feed/user/<id>` (style API v1) : `items`, `next_max_id`,
    /// `more_available`.
    public static func parseFeed(_ data: Data) throws -> InstagramPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstagramError.invalidResponse
        }
        // Mur de connexion : Instagram répond 200 avec un message d'API
        // (`login_required`, `feedback_required`, …) plutôt qu'avec un fil.
        // Sans `items`, un corps message n'est jamais une fin de fil muette.
        guard root["items"] != nil else {
            if root["message"] != nil || root["error_type"] != nil {
                throw InstagramError.loginRequired
            }
            throw InstagramError.invalidResponse
        }
        let items = (root["items"] as? [[String: Any]]) ?? []
        var posts: [InstagramPost] = []
        for item in items {
            guard let post = feedPost(item) else { continue }
            posts.append(post)
        }
        let cursor = root["next_max_id"] as? String
        let more = (root["more_available"] as? Bool) ?? (cursor != nil)
        return InstagramPage(posts: posts, nextCursor: cursor, hasMore: more && !posts.isEmpty)
    }

    /// Publication style GraphQL (page de profil).
    private static func timelinePost(_ node: [String: Any]) -> InstagramPost? {
        guard let id = node["id"] as? String else { return nil }
        let taken = node["taken_at_timestamp"] as? Double
        var media: [InstagramMedia] = []
        if let sidecar = node["edge_sidecar_to_children"] as? [String: Any],
           let edges = sidecar["edges"] as? [[String: Any]] {
            for edge in edges {
                guard let child = edge["node"] as? [String: Any] else { continue }
                if let item = timelineMedia(child) { media.append(item) }
            }
        }
        if media.isEmpty, let item = timelineMedia(node) { media.append(item) }
        guard !media.isEmpty else { return nil }
        let caption = captionText(node["edge_media_to_caption"])
        return InstagramPost(id: id, code: node["shortcode"] as? String, text: caption,
                             publishedAt: taken.map { Date(timeIntervalSince1970: $0) },
                             media: media)
    }

    /// Média style GraphQL : `display_url` pour une image, `video_url` pour
    /// une vidéo (`is_video`).
    private static func timelineMedia(_ node: [String: Any]) -> InstagramMedia? {
        let isVideo = (node["is_video"] as? Bool) ?? false
        guard let raw = isVideo ? (node["video_url"] as? String) : (node["display_url"] as? String),
              let url = URL(string: raw), url.scheme == "https" else { return nil }
        return InstagramMedia(storageKey: mediaKey(node["id"] as? String, video: isVideo),
                              url: url, isVideo: isVideo)
    }

    /// Publication style API v1 (fil paginé).
    private static func feedPost(_ item: [String: Any]) -> InstagramPost? {
        guard let pk = item["pk"] as? String, !pk.isEmpty else { return nil }
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

    /// Média style API v1 : `image_versions2.candidates` pour une image,
    /// `video_versions` pour une vidéo (`media_type` 2), la meilleure
    /// candidate étant la première.
    private static func feedMedia(_ item: [String: Any], postPK: String, position: Int) -> InstagramMedia? {
        let mediaType = item["media_type"] as? Int
        let isVideo = mediaType == 2 || (item["video_versions"] as? [[String: Any]])?.isEmpty == false
        let versions = item["video_versions"] as? [[String: Any]]
        let candidates = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])
        let raw: String?
        if isVideo, let first = versions?.first {
            raw = first["url"] as? String
        } else if let first = candidates?.first {
            raw = first["url"] as? String
        } else {
            raw = nil
        }
        guard let value = raw, let url = URL(string: value), url.scheme == "https" else { return nil }
        // Dans un carrousel, chaque enfant porte son propre `pk` ; isolé,
        // l'identifiant du média est celui du post.
        let pk = (item["pk"] as? String) ?? "\(postPK)-\(position)"
        return InstagramMedia(storageKey: mediaKey(pk, video: isVideo),
                              url: url, isVideo: isVideo)
    }

    private static func captionText(_ node: Any?) -> String {
        guard let edges = (node as? [String: Any])?["edges"] as? [[String: Any]],
              let first = edges.first,
              let text = (first["node"] as? [String: Any])?["text"] as? String else { return "" }
        return text
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

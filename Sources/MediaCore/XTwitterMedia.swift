import Foundation

/// Un média retentionné par le fil `/media` d'un compte X, avec l'URL déjà
/// choisie dans la meilleure qualité que X publie pour ce média.
///
/// Images : `name=orig` (l'original téléversé, pas une vignette).
/// Vidéos et GIF animés : la variante `video/mp4` de plus haut débit, jamais le
/// flux HLS `application/x-mpegURL` car il n'est pas téléchargeable tel quel.
public struct XMedia: Hashable, Sendable {
    /// Nature du média, pour l'extension et la déduplication.
    public enum Kind: String, Sendable {
        case image, video, gif

        /// `animated_gif` est un GIF X : sa seule forme téléchargeable est un
        /// MP4, pas un fichier `.gif`.
        public var fileExtension: String {
            switch self {
            case .image: return "jpg"
            case .video, .gif: return "mp4"
            }
        }
    }

    /// Identifiant du média (`media_key` / `id_str`). Immutable : il sert de
    /// clé de dédoublonnage sur disque.
    public let id: String
    public let kind: Kind
    public let url: URL
    /// Résolution publiée, pour le journal et le choix entre deux variantes.
    public let width: Int
    public let height: Int
    public let bitrate: Int

    public init(id: String, kind: Kind, url: URL, width: Int, height: Int, bitrate: Int) {
        self.id = id; self.kind = kind; self.url = url
        self.width = width; self.height = height; self.bitrate = bitrate
    }
}

/// Un post du fil `/media`, avec tous ses médias.
public struct XPost: Sendable {
    public let id: String
    public let text: String
    public let publishedAt: Date?
    public let media: [XMedia]

    public init(id: String, text: String, publishedAt: Date?, media: [XMedia]) {
        self.id = id; self.text = text; self.publishedAt = publishedAt; self.media = media
    }
}

/// Une page du fil `/media`, avec le curseur de la page suivante.
public struct XMediaPage: Sendable {
    public let posts: [XPost]
    public let nextCursor: String?

    public init(posts: [XPost], nextCursor: String?) {
        self.posts = posts; self.nextCursor = nextCursor
    }
}

/// Lecteur des réponses `UserByScreenName` et `UserMedia`.
///
/// Le format est un graphe profondément imbriqué dont les niveaux changent
/// quand X ajuste son front. Le parcours est donc volontairement tolérant : un
/// nœud absent est ignoré, et seule l'absence de *toute* structure exploitable
/// est signalée comme `invalidTimeline`, ce qui couvre un `queryId` périmé sans
/// le confondre avec un compte sans média.
public enum XTwitterMedia {
    /// Résolution du compte : renvoie l'identifiant numérique.
    public static func parseUser(_ data: Data) throws -> String {
        let root = try object(data)
        // data.user.result.__typename == "User" puis .legacy.id_str
        let user = root["data"]?["user"]?["result"]
        let legacy = user?["legacy"] as? [String: Any]
        if let id = legacy?["id_str"] as? String, !id.isEmpty { return id }
        // Un compte inexistant ou protégé arrive ici : X renvoie un objet sans
        // `legacy`, ou un typename "UserUnavailable".
        throw XTwitterError.unknownAccount
    }

    /// Une page du fil média. Les entrées sans média exploitable (texte seul,
    /// carte, réponse citant un média déjà retenu) sont ignorées.
    public static func parseMediaPage(_ data: Data) throws -> XMediaPage {
        let root = try object(data)
        guard let instructions = root["data"]?["user"]?["result"]?["timeline_v2"]?["timeline"]?["instructions"] as? [[String: Any]] else {
            throw XTwitterError.invalidTimeline
        }
        var posts: [XPost] = []
        var nextCursor: String?
        var sawEntry = false

        for instruction in instructions {
            guard let entries = instruction["entries"] as? [[String: Any]] else { continue }
            for entry in entries {
                sawEntry = true
                let entryID = entry["entryId"] as? String ?? ""
                // Le curseur de bas de page se trouve dans une entrée dédiée,
                // pas dans un post. Il est la seule voie de pagination.
                if entryID.hasPrefix("cursor-bottom") {
                    let value = entry["content"]?["value"] as? String
                    if let value, !value.isEmpty { nextCursor = value }
                    continue
                }
                if entryID.hasPrefix("profile-conversation") || entryID.hasPrefix("tweetdetailreflow") { continue }
                guard let result = entry["content"]?["itemContent"]?["tweet_results"]?["result"] as? [String: Any] else { continue }
                guard let legacy = result["legacy"] as? [String: Any] else { continue }
                let tweetID = legacy["id_str"] as? String
                    ?? (result["rest_id"] as? String)
                guard let tweetID, !tweetID.isEmpty else { continue }
                let media = mediaList(legacy)
                guard !media.isEmpty else { continue }
                posts.append(XPost(id: tweetID,
                                   text: (legacy["full_text"] as? String) ?? "",
                                   publishedAt: parseDate(legacy["created_at"] as? String),
                                   media: media))
            }
        }
        guard sawEntry else { throw XTwitterError.invalidTimeline }
        return XMediaPage(posts: posts, nextCursor: nextCursor)
    }

    /// Médias d'un post, dans l'ordre publié, sans doublon d'identifiant.
    /// `extended_entities.media` est la source la plus complète ; à défaut,
    /// `entities.media`. Les médias d'une citation appartiennent au post cité et
    /// sont donc ignorés : le parcours du post cité les prendra à son tour.
    static func mediaList(_ legacy: [String: Any]) -> [XMedia] {
        let raw = (legacy["extended_entities"]?["media"] as? [[String: Any]])
            ?? (legacy["entities"]?["media"] as? [[String: Any]])
            ?? []
        var seen = Set<String>()
        var out: [XMedia] = []
        for entry in raw {
            guard let id = mediaID(entry), seen.insert(id).inserted else { continue }
            guard let media = bestVariant(entry) else { continue }
            out.append(media)
        }
        return out
    }

    private static func mediaID(_ entry: [String: Any]) -> String? {
        if let key = entry["media_key"] as? String, !key.isEmpty {
            // `3_1234567890` → l'identifiant nu suffit et reste stable.
            return key.split(separator: "_").last.map(String.init) ?? key
        }
        if let id = entry["id_str"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// Choisit la meilleure qualité téléchargeable parmi les variantes publiées.
    ///
    /// Pour `photo` : `name=orig` est l'original téléversé, la seule version non
    /// réduite. Pour `video` et `animated_gif` : `video_info.variants` contient
    /// des `video/mp4` par débit et un `application/x-mpegURL`. Seuls les MP4
    /// sont retenus, le plus haut débit d'abord. Un flux HLS seul ne donne rien
    /// de téléchargeable : le média est alors ignoré, et non compté en échec.
    static func bestVariant(_ entry: [String: Any]) -> XMedia? {
        let id = mediaID(entry)
        let type = (entry["type"] as? String) ?? "photo"
        let width = (entry["original_width"] as? NSNumber)?.intValue ?? 0
        let height = (entry["original_height"] as? NSNumber)?.intValue ?? 0

        if type == "photo" {
            guard let id, let raw = entry["url"] as? String, var components = URLComponents(string: raw) else { return nil }
            // `name=orig` est l'original téléversé ; X sert aussi `format`.
            components.queryItems = [URLQueryItem(name: "name", value: "orig")]
            guard let url = components.url, isMediaHost(url) else { return nil }
            return XMedia(id: id, kind: .image, url: url, width: width, height: height, bitrate: 0)
        }

        guard type == "video" || type == "animated_gif" else { return nil }
        let variants = entry["video_info"]?["variants"] as? [[String: Any]] ?? []
        var best: (url: URL, bitrate: Int)?
        for variant in variants {
            guard (variant["content_type"] as? String) == "video/mp4",
                  let raw = variant["url"] as? String,
                  let url = URL(string: raw), isMediaHost(url) else { continue }
            let bitrate = (variant["bitrate"] as? NSNumber)?.intValue ?? 0
            if best == nil || bitrate > best!.bitrate { best = (url, bitrate) }
        }
        guard let id, let chosen = best else { return nil }
        return XMedia(id: id, kind: type == "animated_gif" ? .gif : .video,
                       url: chosen.url, width: width, height: height, bitrate: chosen.bitrate)
    }

    /// Seuls les hôtes de publication de X sont acceptés : une URL d'hôte tiers
    /// dans la réponse ne doit pas être téléchargée.
    private static func isMediaHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "pbs.twimg.com" || host == "video.twimg.com"
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw XTwitterError.invalidTimeline
        }
        return root
    }

    /// `created_at` de X est toujours `EEE MMM dd HH:mm:ss Z yyyy` en anglais.
    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: text)
    }
}
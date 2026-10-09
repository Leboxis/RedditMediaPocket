import Foundation

/// Un média retentionné par le fil `/media` d'un compte X, avec l'URL déjà
/// choisie dans la meilleure qualité que X publie pour ce média.
///
/// Images : `name=orig` (l'original téléversé, pas une vignette).
/// Vidéos et GIF animés : la variante `video/mp4` de plus haut débit, jamais le
/// flux HLS `application/x-mpegURL` car il n'est pas téléchargeable tel quel.
public struct XMedia: Hashable, Sendable {
    /// Nature du média, pour l'extension et la dédouplication.
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

    /// Identifiant du média (`media_key` ou `id_str`). Il est immuable et sert
    /// de clé de dédoublonnage sur disque.
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
        let user = dictionary(dictionary(dictionary(root, "data"), "user"), "result")
        if let id = text(user, "rest_id"), !id.isEmpty { return id }
        if let legacy = dictionary(user, "legacy"),
           let id = text(legacy, "id_str"), !id.isEmpty { return id }
        // Un compte inexistant ou protégé arrive ici : X renvoie un objet sans
        // `legacy`, ou un typename `UserUnavailable`.
        throw XTwitterError.unknownAccount
    }

    /// Une page du fil média. Les entrées sans média exploitable (texte seul,
    /// carte, citation) sont ignorées.
    public static func parseMediaPage(_ data: Data) throws -> XMediaPage {
        let root = try object(data)
        let user = dictionary(dictionary(dictionary(root, "data"), "user"), "result")
        let timeline = dictionary(dictionary(user, "timeline_v2"), "timeline")
        guard let instructions = objects(timeline, "instructions") else {
            throw XTwitterError.invalidTimeline
        }
        var posts: [XPost] = []
        var nextCursor: String?
        var sawTimelineItem = false
        var terminated = false
        var seenPosts = Set<String>()

        func appendItem(_ item: [String: Any]) {
            // Entrée directe : content.itemContent. Grille : item.itemContent.
            let content = dictionary(item, "content") ?? dictionary(item, "item") ?? item
            guard let itemContent = dictionary(content, "itemContent") else { return }
            sawTimelineItem = true
            guard var result = dictionary(dictionary(itemContent, "tweet_results"), "result") else { return }
            if let tweet = dictionary(result, "tweet") { result = tweet }
            guard let legacy = dictionary(result, "legacy"),
                  let id = text(legacy, "id_str") ?? text(result, "rest_id"),
                  !id.isEmpty, seenPosts.insert(id).inserted else { return }
            let media = mediaList(legacy)
            guard !media.isEmpty else { return }
            posts.append(XPost(id: id, text: text(legacy, "full_text") ?? "",
                               publishedAt: parseDate(text(legacy, "created_at")), media: media))
        }

        for instruction in instructions {
            if text(instruction, "type") == "TimelineTerminateTimeline",
               text(instruction, "direction") == "Bottom" { terminated = true }
            for item in objects(instruction, "moduleItems") ?? [] { appendItem(item) }
            var entries = objects(instruction, "entries") ?? []
            if let entry = dictionary(instruction, "entry") { entries.append(entry) }
            for entry in entries {
                let entryID = text(entry, "entryId") ?? ""
                let content = dictionary(entry, "content")
                if text(content, "cursorType") == "Bottom" || entryID.hasPrefix("cursor-bottom") {
                    if let value = text(content, "value"), !value.isEmpty { nextCursor = value }
                    continue
                }
                // Première page UserMedia : TimelineTimelineModule.content.items.
                for item in objects(content, "items") ?? [] { appendItem(item) }
                if !entryID.hasPrefix("profile-conversation") && !entryID.hasPrefix("tweetdetailreflow") {
                    appendItem(entry)
                }
            }
        }
        // X peut continuer à fournir un Bottom sur une page composée seulement
        // de curseurs. Il ne justifie pas une nouvelle requête sans aucun item.
        return XMediaPage(posts: posts, nextCursor: terminated || !sawTimelineItem ? nil : nextCursor)
    }

    /// Médias d'un post, dans l'ordre publié, sans doublon d'identifiant.
    /// `extended_entities.media` est la source la plus complète ; à défaut,
    /// `entities.media`. Les médias d'une citation appartiennent au post cité :
    /// le parcours de ce post les prendra à son tour.
    static func mediaList(_ legacy: [String: Any]) -> [XMedia] {
        let raw = objects(dictionary(legacy, "extended_entities"), "media")
            ?? objects(dictionary(legacy, "entities"), "media")
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
        if let key = text(entry, "media_key"), !key.isEmpty {
            // `3_1234567890` : l'identifiant nu suffit et reste stable.
            return key.split(separator: "_").last.map(String.init) ?? key
        }
        if let id = text(entry, "id_str"), !id.isEmpty { return id }
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
        guard let id = mediaID(entry) else { return nil }
        let type = text(entry, "type") ?? "photo"
        let original = dictionary(entry, "original_info")
        let width = number(original ?? entry, original == nil ? "original_width" : "width")
        let height = number(original ?? entry, original == nil ? "original_height" : "height")

        if type == "photo" {
            guard let raw = text(entry, "media_url_https") ?? text(entry, "url"),
                  var components = URLComponents(string: raw) else { return nil }
            // `name=orig` est l'original téléversé ; X sert aussi `format`.
            components.queryItems = [URLQueryItem(name: "name", value: "orig")]
            guard let url = components.url, isMediaHost(url) else { return nil }
            return XMedia(id: id, kind: .image, url: url, width: width, height: height, bitrate: 0)
        }

        guard type == "video" || type == "animated_gif" else { return nil }
        var bestURL: URL?
        var bestBitrate = 0
        for variant in objects(dictionary(entry, "video_info"), "variants") ?? [] {
            guard text(variant, "content_type") == "video/mp4",
                  let raw = text(variant, "url"),
                  let url = URL(string: raw), isMediaHost(url) else { continue }
            let bitrate = number(variant, "bitrate")
            if bestURL == nil || bitrate > bestBitrate {
                bestURL = url
                bestBitrate = bitrate
            }
        }
        guard let chosen = bestURL else { return nil }
        return XMedia(id: id, kind: type == "animated_gif" ? .gif : .video,
                      url: chosen, width: width, height: height, bitrate: bestBitrate)
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

    // Les aides ci-dessous évitent d'écrire `a?["b"]?["c"]` : sur `Any`, un
    // sous-script optionnel n'a pas de type de sortie, et l'enchaînement de
    // quatre niveaux ne se compile pas.

    /// Une liste d'objets. `instructions` est un tableau, pas un objet : le lire
/// avec `dictionary` le ferait échouer à chaque fois.
    private static func objects(_ node: [String: Any]?, _ key: String) -> [[String: Any]]? {
        guard let node else { return nil }
        return node[key] as? [[String: Any]]
    }

    

    private static func dictionary(_ node: Any?, _ key: String) -> [String: Any]? {
        guard let container = node as? [String: Any] else { return nil }
        return container[key] as? [String: Any]
    }

    private static func text(_ node: [String: Any]?, _ key: String) -> String? {
        guard let node else { return nil }
        return node[key] as? String
    }

    private static func number(_ node: [String: Any]?, _ key: String) -> Int {
        guard let node else { return 0 }
        return (node[key] as? NSNumber)?.intValue ?? 0
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

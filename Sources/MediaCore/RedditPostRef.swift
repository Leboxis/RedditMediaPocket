import Foundation

/// Posts Reddit isolés, désignés par leur adresse. Même modèle que
/// `XFetishAlbums.Target` : une cible porte une ou plusieurs adresses, et le
/// parcours ne lit que celles-là au lieu de remonter un flux entier.
///
/// Aucun accès réseau ici : uniquement de l'analyse d'URL.
public enum RedditPostRef {
    /// Un post retenu : son identifiant `t3_…` (celui du flux) et son adresse.
    public struct Post: Hashable, Sendable {
        public let id: String
        public let url: URL
        /// Sous-reddit lu dans l'adresse, quand elle le porte.
        public let subreddit: String?

        public init(id: String, url: URL, subreddit: String? = nil) {
            self.id = id; self.url = url; self.subreddit = subreddit
        }
    }

    /// Une ou plusieurs adresses de posts, dédoublonnées par identifiant.
    public struct Target: Hashable, Sendable {
        public let posts: [Post]

        public init(posts: [Post]) { self.posts = posts }

        /// Nom de collection stable : une sélection de posts partage toujours
        /// la même entrée, comme `x/videos` pour X-Fetish.
        public var collectionName: String { "posts" }
    }

    /// Identifiant d'un post depuis les deux formes d'adresse Reddit :
    /// `/r/<sub>/comments/<id>/<slug>/`, `/comments/<id>/…`, et la forme
    /// courte `redd.it/<id>`. Retourne `nil` pour tout le reste.
    public static func postID(_ raw: String) -> Post? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: candidate),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "reddit.com" || host.hasSuffix(".reddit.com")
                || host == "redd.it" || host.hasSuffix(".redd.it"),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        // `redd.it/<id>` : forme courte, jamais préfixée par `/r/`.
        if host == "redd.it" || host.hasSuffix(".redd.it") {
            guard let first = parts.first, isPostID(first) else { return nil }
            return Post(id: "t3_" + first,
                        url: URL(string: "https://www.reddit.com/comments/\(first)/")!)
        }
        // `/r/<sub>/comments/<id>/…` : le sous-reddit est retenu pour l'affichage.
        var subreddit: String?
        if parts.count >= 2, parts[0].lowercased() == "r" {
            subreddit = parts[1]
            parts.removeFirst(2)
        }
        // `/r/<sub>/s/<share>/` : lien de partage, l'identifiant est absent de
        // l'adresse elle-même. Il est refusé plutôt que deviné.
        guard parts.count >= 2, parts[0].lowercased() == "comments", isPostID(parts[1]) else { return nil }
        let id = parts[1]
        // L'adresse canonique garde le sous-reddit quand il est connu : le JSON
        // du post n'exige que l'identifiant, mais l'adresse reste lisible.
        let canonical = subreddit.map { "https://www.reddit.com/r/\($0)/comments/\(id)/" }
            ?? "https://www.reddit.com/comments/\(id)/"
        guard let canonicalURL = URL(string: canonical) else { return nil }
        return Post(id: "t3_" + id, url: canonicalURL, subreddit: subreddit)
    }

    /// Plusieurs adresses (une par ligne, ou séparées par des virgules ou des
    /// espaces). Une adresse invalide est ignorée : une sélection peut mélanger
    /// un post et du texte recopié sans que tout échoue.
    public static func parseTarget(_ input: String) throws -> Target {
        let tokens = input.split { $0.isWhitespace || $0 == "," || $0 == ";" }.map(String.init)
        var posts: [Post] = []
        var seen = Set<String>()
        for token in tokens {
            guard let post = postID(token) else { continue }
            if seen.insert(post.id).inserted { posts.append(post) }
        }
        guard !posts.isEmpty else { throw FeedError.invalidFeed }
        return Target(posts: posts)
    }

    /// `comments/<id>.json` du post : la même route que la résolution des
    /// galeries, qui porte aussi `url`, `title` et `created_utc`.
    public static func jsonURL(for post: Post) -> URL? {
        let bare = post.id.hasPrefix("t3_") ? String(post.id.dropFirst(3)) : post.id
        guard isPostID(bare) else { return nil }
        var components = URLComponents(string: "https://www.reddit.com/comments/\(bare).json")!
        components.queryItems = [URLQueryItem(name: "raw_json", value: "1"), URLQueryItem(name: "limit", value: "1")]
        return components.url
    }

    /// Identifiant Reddit : lettres et chiffres, 4 à 12 caractères.
    static func isPostID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9]{4,12}$", options: .regularExpression) != nil
    }
}

/// Un post isolé résolu depuis son JSON : titre, date, adresse et médias.
public struct RedditPostDetail: Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let publishedAt: Date?
    public let media: [Media]

    public init(id: String, title: String, url: URL, publishedAt: Date?, media: [Media]) {
        self.id = id
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.media = media
    }
}

public extension RedditPostRef {
    /// Lit `comments/<id>.json` et en extrait les médias du post.
    ///
    /// La forme est un tableau de deux listings (post puis commentaires). Le
    /// post peut être un crosspost : ses propres médias priment, et à défaut
    /// ceux du parent sont repris, comme le fait `GalleryFeed`.
    static func parsePost(_ data: Data, fallback: Post) throws -> RedditPostDetail {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw FeedError.invalidFeed }
        guard let listing = root as? [Any], let first = listing.first as? [String: Any],
              let listingData = first["data"] as? [String: Any],
              let children = listingData["children"] as? [[String: Any]],
              let child = children.first, let post = child["data"] as? [String: Any] else {
            throw FeedError.invalidFeed
        }
        // Titre, date et adresse : le JSON les porte, l'adresse collée sert de
        // repli quand un champ manque.
        let title = (post["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = (post["created_utc"] as? NSNumber)?.doubleValue
        let permalink = post["permalink"] as? String
        let postURL = permalink.flatMap { URL(string: "https://www.reddit.com" + $0) } ?? fallback.url
        // Médias : la liste complète vient de `GalleryFeed`, qui gère déjà
        // galeries, crossposts et vidéos `v.redd.it`. Un post supprimé peut
        // renvoyer un listing vide : ce n'est pas une erreur, juste aucun
        // média — sinon une seule adresse morte annulerait toute la sélection.
        var media = (try? GalleryFeed.parse(data)) ?? []
        if media.isEmpty {
            // Post à média unique : `url_overridden_by_dest` porte l'original.
            if let raw = post["url_overridden_by_dest"] as? String,
               let url = URL(string: raw), url.scheme == "https",
               let host = url.host?.lowercased(),
               ["i.redd.it", "i.imgur.com", "v.redd.it"].contains(host) {
                if host == "v.redd.it", let id = url.pathComponents.dropFirst().first, !id.isEmpty,
                   let base = URL(string: "https://v.redd.it/\(id)") {
                    media = [.redditVideo(base)]
                } else if ["jpg", "jpeg", "png", "gif", "webp", "mp4"].contains(url.pathExtension.lowercased()) {
                    media = [.direct(QualityPolicy.originalImageURL(url))]
                }
            }
        }
        let id = (post["id"] as? String).map { "t3_\($0)" } ?? fallback.id
        return RedditPostDetail(
            id: id,
            title: title?.isEmpty == false ? title! : "Post \(id.dropFirst(3))",
            url: postURL,
            publishedAt: created.map { Date(timeIntervalSince1970: $0) },
            media: media
        )
    }
}

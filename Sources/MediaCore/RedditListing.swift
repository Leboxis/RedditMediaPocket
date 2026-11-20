import Foundation

/// Listing JSON `www.reddit.com/…​.json` (subreddits, profils, sauvegardés).
///
/// Depuis le 13 novembre 2026, Reddit ne sert plus aucun flux `.rss` : les
/// adresses `.rss` répondent HTTP 404 sur `www.reddit.com` **et**
/// `old.reddit.com`, y compris avec une session. Les listings `.json` des
/// pages classiques restent servis aux sessions connectées (anonyme :
/// HTTP 403 « blocked by network security »).
///
/// Le parseur produit les mêmes `Post` que `FeedParser` (Atom) : le `html`
/// est synthétisé avec des `href`/`img` afin que `MediaExtractor.extract` et
/// `GalleryFeed.linkedID` retrouvent les médias exactement comme dans un
/// contenu RSS.
public enum RedditListing {
    private struct Listing: Decodable { let data: ListingData }
    private struct ListingData: Decodable { let after: String?; let children: [Child] }
    private struct Child: Decodable { let kind: String; let data: ChildData }
    private struct ChildData: Decodable {
        let id: String?
        let name: String?
        let title: String?
        let permalink: String?
        let url: String?
        let createdUtc: Double?
        let isVideo: Bool?
        let media: MediaPayload?
        let preview: PreviewPayload?
    }
    private struct MediaPayload: Decodable { let redditVideo: RedditVideo? }
    private struct RedditVideo: Decodable { let fallbackUrl: String? }
    private struct PreviewPayload: Decodable { let images: [PreviewImage]? }
    private struct PreviewImage: Decodable { let source: PreviewSource? }
    private struct PreviewSource: Decodable { let url: String? }

    /// Parse une listing JSON `t3_…` en posts. Lève `FeedError.invalidFeed`
    /// si le document n'est pas une listing JSON.
    public static func parse(_ data: Data) throws -> [Post] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let listing = try? decoder.decode(Listing.self, from: data) else {
            throw FeedError.invalidFeed
        }
        var posts: [Post] = []
        for child in listing.data.children where child.kind == "t3" {
            if let post = post(from: child.data) { posts.append(post) }
        }
        return posts
    }

    /// Curseur de pagination (`data.after`) d'une listing, si présent.
    public static func after(_ data: Data) -> String? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(Listing.self, from: data))?.data.after
    }

    private static let mediaHosts = ["v.redd.it", "redgifs.com", "www.redgifs.com", "i.redd.it", "i.imgur.com"]

    private static func post(from d: ChildData) -> Post? {
        let id = d.name ?? d.id.map { "t3_" + $0 } ?? ""
        guard !id.isEmpty else { return nil }
        let link: String? = d.permalink.map {
            $0.hasPrefix("http") ? $0 : "https://www.reddit.com" + $0
        }
        let publishedAt = d.createdUtc.map { Date(timeIntervalSince1970: $0) }

        // HTML synthétisé : mêmes motifs (href média, href galerie, img
        // d'aperçu) que le `content:encoded` d'un flux Atom.
        var html = ""
        if let link { html += #"<a href="\#(link)"></a>"# }
        var candidates: [String] = []
        if d.isVideo == true, let fallback = d.media?.redditVideo?.fallbackUrl {
            candidates.append(fallback)
        }
        if let url = d.url { candidates.append(url) }
        for raw in candidates {
            guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() else { continue }
            let isGallery = host.hasSuffix("reddit.com") && url.path.contains("/gallery/")
            if isGallery || mediaHosts.contains(host) {
                html += #"<a href="\#(raw)"></a>"#
            }
        }
        if let preview = d.preview?.images?.first?.source?.url {
            html += #"<img src="\#(preview)">"#
        }
        return Post(id: id, title: d.title ?? "", html: html, publishedAt: publishedAt, link: link)
    }
}

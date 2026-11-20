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
/// `GalleryFeed.linkedID` retrouvent les médias. Quand le listing porte
/// déjà `gallery_data` + `media_metadata`, la galerie est résolue
/// immédiatement (`Post.galleryMedia`) : aucun appel `/comments/<id>.json`
/// supplémentaire.
public enum RedditListing {
    private static let mediaHosts = ["v.redd.it", "redgifs.com", "www.redgifs.com", "i.redd.it", "i.imgur.com"]

    /// Parse une listing JSON `t3_…` en posts. Lève `FeedError.invalidFeed`
    /// si le document n'est pas une listing JSON.
    public static func parse(_ data: Data) throws -> [Post] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let listing = root as? [String: Any],
              let listingData = listing["data"] as? [String: Any],
              let children = listingData["children"] as? [[String: Any]] else {
            throw FeedError.invalidFeed
        }
        var posts: [Post] = []
        for child in children {
            guard (child["kind"] as? String) == "t3",
                  let d = child["data"] as? [String: Any],
                  let post = post(from: d) else { continue }
            posts.append(post)
        }
        return posts
    }

    /// Curseur de pagination (`data.after`) d'une listing, si présent.
    public static func after(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let listing = root as? [String: Any],
              let listingData = listing["data"] as? [String: Any] else { return nil }
        return listingData["after"] as? String
    }

    private static func post(from d: [String: Any]) -> Post? {
        let id = (d["name"] as? String) ?? (d["id"] as? String).map { "t3_" + $0 } ?? ""
        guard !id.isEmpty else { return nil }
        let link = (d["permalink"] as? String).map {
            $0.hasPrefix("http") ? $0 : "https://www.reddit.com" + $0
        }
        let publishedAt: Date? = {
            guard let created = d["created_utc"] as? NSNumber else { return nil }
            return Date(timeIntervalSince1970: created.doubleValue)
        }()

        // HTML synthétisé : mêmes motifs (href média, href galerie, img
        // d'aperçu signé) que le `content:encoded` d'un flux Atom.
        var html = ""
        if let link { html += #"<a href="\#(link)"></a>"# }
        var candidates: [String] = []
        if (d["is_video"] as? Bool) == true,
           let fallback = ((d["media"] as? [String: Any])?["reddit_video"] as? [String: Any])?["fallback_url"] as? String {
            candidates.append(fallback)
        }
        if let url = d["url"] as? String { candidates.append(url) }
        for raw in candidates {
            guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() else { continue }
            let isGallery = host.hasSuffix("reddit.com") && url.path.contains("/gallery/")
            if isGallery || mediaHosts.contains(host) {
                html += #"<a href="\#(raw)"></a>"#
            }
        }
        // Aperçu signé (preview.images[].source.url, `&amp;` déséchappé à la
        // lecture par MediaExtractor.previewImage) : sert de miroir full-res
        // si l'original i.redd.it est refusé.
        if let preview = (((d["preview"] as? [String: Any])?["images"] as? [[String: Any]])?.first?["source"] as? [String: Any])?["url"] as? String {
            html += #"<img src="\#(preview)">"#
        }
        let gallery = GalleryFeed.media(inPost: d)
        return Post(id: id, title: d["title"] as? String ?? "", html: html,
                    publishedAt: publishedAt, link: link,
                    galleryMedia: gallery.isEmpty ? nil : gallery)
    }
}

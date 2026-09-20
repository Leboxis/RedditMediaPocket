import Foundation

/// Les posts multi-médias (carrousels) n'apparaissent dans le RSS public que
/// comme un lien vers la page `/gallery/<id>` et la miniature de couverture ;
/// la liste ordonnée des originaux ne se trouve que dans le JSON du post.
public enum GalleryFeed {
    /// Vrai quand le contenu RSS pointe la page galerie d'un post.
    public static func linked(_ html: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: #"(?i)href\s*=\s*["']https://www\.reddit\.com/gallery/[A-Za-z0-9]+["']"#)
        return regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) != nil
    }

    /// Premier identifiant de page galerie du contenu RSS, s'il existe.
    public static func linkedID(_ html: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"(?i)href\s*=\s*["']https://www\.reddit\.com/gallery/([A-Za-z0-9]+)["']"#)
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// JSON du post (`t3_…` du flux RSS accepté).
    public static func commentsJSONURL(feedID: String) -> URL? {
        let id = feedID.hasPrefix("t3_") ? String(feedID.dropFirst(3)) : feedID
        guard id.range(of: "^[A-Za-z0-9]{4,12}$", options: .regularExpression) != nil else { return nil }
        var components = URLComponents(string: "https://www.reddit.com/comments/\(id).json")!
        components.queryItems = [URLQueryItem(name: "raw_json", value: "1"), URLQueryItem(name: "limit", value: "1")]
        return components.url
    }

    /// Liste ordonnée des originaux de la galerie : l'ordre vient de
    /// `gallery_data.items`, chaque entrée est résolue par `media_metadata`
    /// vers l'original `i.redd.it` (la source `preview.redd.it` est une copie
    /// réduite) ou vers `v.redd.it` pour les vidéos (manifest DASH réutilisant
    /// le pipeline `redditVideo` existant). Une galerie crosspostée porte ses
    /// données dans `crosspost_parent_list` ; hors galerie, la liste est vide.
    public static func parse(_ data: Data) throws -> [Media] {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw FeedError.invalidFeed }
        guard let listing = root as? [Any], let first = listing.first as? [String: Any],
              let listingData = first["data"] as? [String: Any],
              let children = listingData["children"] as? [[String: Any]],
              let child = children.first, let post = child["data"] as? [String: Any] else {
            throw FeedError.invalidFeed
        }
        // L'entrée porteuse est le post lui-même, sinon son parent de crosspost.
        var entry = post
        if entry["gallery_data"] == nil, let parents = post["crosspost_parent_list"] as? [[String: Any]],
           let parent = parents.last(where: { $0["gallery_data"] != nil }) { entry = parent }
        guard let gallery = entry["gallery_data"] as? [String: Any],
              let items = gallery["items"] as? [[String: Any]],
              let metadata = entry["media_metadata"] as? [String: Any] else { return [] }
        var seen = Set<Media>()
        var media: [Media] = []
        for item in items {
            guard let id = item["media_id"] as? String,
                  let meta = metadata[id] as? [String: Any],
                  (meta["status"] as? String ?? "valid") == "valid",
                  let mime = meta["m"] as? String,
                  let source = meta["s"] as? [String: Any] else { continue }
            // Vidéos de galerie : manifest DASH `v.redd.it`, même pipeline que
            // les vidéos simples (`Media.redditVideo` + `DASHParser` + fusion).
            let entryType = meta["e"] as? String ?? ""
            if entryType == "RedditVideo" || mime == "video/mp4" {
                guard let dashRaw = source["dashUrl"] as? String,
                      let dashURL = URL(string: dashRaw),
                      dashURL.scheme == "https",
                      dashURL.host?.lowercased() == "v.redd.it" else { continue }
                let base = dashURL.deletingLastPathComponent()
                guard base.scheme == "https",
                      base.host?.lowercased() == "v.redd.it",
                      !base.pathComponents.filter({ $0 != "/" }).isEmpty else { continue }
                let candidate: Media = .redditVideo(base)
                if seen.insert(candidate).inserted { media.append(candidate) }
                continue
            }
            let ext: String
            switch mime {
            case "image/jpg", "image/jpeg": ext = "jpg"
            case "image/png": ext = "png"
            case "image/webp": ext = "webp"
            case "image/gif": ext = "gif"
            default: continue
            }
            guard let raw = source["u"] as? String ?? source["gif"] as? String,
                  var components = URLComponents(string: raw) else { continue }
            components.query = nil
            guard let url = components.url, url.scheme == "https",
                  let host = url.host?.lowercased(), ["preview.redd.it", "i.redd.it"].contains(host),
                  !url.deletingPathExtension().lastPathComponent.isEmpty else { continue }
            let original = URL(string: "https://i.redd.it/\(url.deletingPathExtension().lastPathComponent).\(ext)")
            guard let original else { continue }
            let candidate: Media = .direct(original)
            if seen.insert(candidate).inserted { media.append(candidate) }
        }
        return media
    }
}

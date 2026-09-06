import Foundation

public struct SavedEntry {
    public let id: String
    public let media: [Media]
}

public struct SavedPage {
    public let entries: [SavedEntry]
    public let after: String?

    public static func url(username: String, after: String? = nil) throws -> URL {
        let name = try MediaExtractor.username(username)
        var url = URLComponents(string: "https://www.reddit.com/user/\(name)/saved.json")!
        url.queryItems = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "raw_json", value: "1")]
        if let after { url.queryItems?.append(URLQueryItem(name: "after", value: after)) }
        return url.url!
    }

    public static func account(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["data"] as? [String: Any], let name = account["name"] as? String else {
            throw FeedError.loginRequired
        }
        return try MediaExtractor.username(name)
    }

    public static func parse(_ data: Data) throws -> SavedPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["kind"] as? String == "Listing",
              let listing = root["data"] as? [String: Any], let children = listing["children"] as? [[String: Any]] else {
            throw FeedError.invalidFeed
        }
        let after: String?
        if let value = listing["after"], !(value is NSNull) {
            guard let cursor = value as? String, cursor.range(of: "^t[13]_[A-Za-z0-9]+$", options: .regularExpression) != nil else {
                throw FeedError.invalidFeed
            }
            after = cursor
        } else { after = nil }
        let entries = try children.map { child -> SavedEntry in
            guard let post = child["data"] as? [String: Any], let id = post["name"] as? String else {
                throw FeedError.invalidFeed
            }
            return SavedEntry(id: id, media: media(post))
        }
        return SavedPage(entries: entries, after: after)
    }

    private static func media(_ post: [String: Any], depth: Int = 0) -> [Media] {
        var result: [Media] = []
        func link(_ value: Any?) {
            guard let url = value as? String else { return }
            // Reuse the existing HTTPS/original-media allowlist, never thumbnails.
            let escaped = url.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "'", with: "%27")
            result += MediaExtractor.extract("<a href=\"\(escaped)\"></a>")
        }
        link(post["url_overridden_by_dest"] ?? post["url"])
        for key in ["body_html", "selftext_html"] {
            if let html = post[key] as? String { result += MediaExtractor.extract(html) }
        }
        if let metadata = post["media_metadata"] as? [String: [String: Any]],
           let gallery = post["gallery_data"] as? [String: Any], let items = gallery["items"] as? [[String: Any]] {
            for item in items {
                guard let id = item["media_id"] as? String, let asset = metadata[id], asset["status"] as? String == "valid",
                      let source = asset["s"] as? [String: Any] else { continue }
                link(source["mp4"] ?? source["gif"] ?? source["u"])
            }
        }
        for key in ["secure_media", "media"] {
            if let container = post[key] as? [String: Any], let video = container["reddit_video"] as? [String: Any] {
                link(video["fallback_url"])
            }
        }
        if depth < 2, let parents = post["crosspost_parent_list"] as? [[String: Any]] {
            for parent in parents { result += media(parent, depth: depth + 1) }
        }
        var seen = Set<Media>()
        return result.filter { seen.insert($0).inserted }
    }
}

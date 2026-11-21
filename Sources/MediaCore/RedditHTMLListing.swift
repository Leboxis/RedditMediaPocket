import Foundation

/// Listing HTML de subreddit, lu quand Reddit refuse le `.json`
/// (`/r/<sub>/<tri>.json` → HTTP 403 « blocked by network security », y compris
/// depuis Safari connecté, alors que la page HTML du subreddit charge).
///
/// `old.reddit.com` garde une structure de listing stable : chaque publication
/// est un `div` portant `data-fullname="t3_…"`. On synthétise le même `html`
/// que `RedditListing` afin que `MediaExtractor` et `GalleryFeed` retrouvent
/// les médias sans changer le reste du pipeline.
public enum RedditHTMLListing {
    private static let thingPattern = #"<div\b[^>]*\bdata-fullname="(t3_[A-Za-z0-9]+)"[^>]*>(.*?)(?=<div\b[^>]*\bdata-fullname="t3_|$)"#
    private static let anchorPattern = #"<a\b([^>]*)>(.*?)</a>"#
    private static let imagePattern = #"<img\b[^>]*\bsrc="([^"]+)"#
    private static let timePattern = #"<time\b[^>]*\bdatetime="([^"]+)""#

    /// Adresse du listing HTML. Le tri et le curseur restent ceux du `.json`.
    public static func url(subreddit: String, sort: String, after: String?) -> URL {
        let acknowledged = FeedSource.subredditSorts.contains(sort) ? sort : "new"
        var components = URLComponents(string: "https://old.reddit.com/r/\(subreddit)/\(acknowledged)/")!
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "100")]
        if acknowledged == "top" { items.append(URLQueryItem(name: "t", value: "month")) }
        if let after { items.append(URLQueryItem(name: "after", value: after)) }
        components.queryItems = items
        return components.url!
    }

    public static func parse(_ data: Data) throws -> [Post] {
        let html = String(decoding: data, as: UTF8.self)
        let ns = html as NSString
        guard let thingRegex = try? NSRegularExpression(pattern: thingPattern,
                                                        options: .dotMatchesLineSeparators),
              let anchorRegex = try? NSRegularExpression(pattern: anchorPattern,
                                                         options: .dotMatchesLineSeparators),
              let imageRegex = try? NSRegularExpression(pattern: imagePattern),
              let timeRegex = try? NSRegularExpression(pattern: timePattern) else {
            throw FeedError.invalidFeed
        }
        var posts: [Post] = []
        for thing in thingRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: thing.range(at: 1))
            let block = ns.substring(with: thing.range(at: 2))
            let blockNS = block as NSString

            var titleLink: String?
            var permalink: String?
            var title = ""
            for anchor in anchorRegex.matches(in: block, range: NSRange(location: 0, length: blockNS.length)) {
                let attributes = blockNS.substring(with: anchor.range(at: 1))
                let inner = blockNS.substring(with: anchor.range(at: 2))
                let isTitle = attributes.localizedCaseInsensitiveContains("title")
                    && (attributes.range(of: "class=", options: .caseInsensitive) != nil)
                let isComments = attributes.localizedCaseInsensitiveContains("comments")
                    && (attributes.range(of: "class=", options: .caseInsensitive) != nil)
                guard let href = attribute("href", in: attributes) else { continue }
                if isTitle, titleLink == nil {
                    titleLink = absolute(href)
                    title = cleanText(inner)
                } else if isComments, permalink == nil {
                    permalink = absolute(href)
                }
            }
            let link = permalink ?? titleLink
            var synthesized = ""
            if let link { synthesized += #"<a href="\#(link)"></a>"# }
            // Le lien du titre est l'URL du média pour un post lien. Une
            // galerie (`/gallery/<id>`) est laissée telle quelle : `prepareDownloads`
            // la résout ensuite via `/comments/<id>.json`.
            if let titleLink, titleLink != link {
                synthesized += #"<a href="\#(titleLink)"></a>"#
            }
            if let image = imageRegex.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length)),
               let src = Optional(blockNS.substring(with: image.range(at: 1))).map({ cleanURL($0) }) {
                synthesized += #"<img src="\#(src)">"#
            }
            let published = timeRegex.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length))
                .map { blockNS.substring(with: $0.range(at: 1)) }
                .flatMap { ISO8601DateFormatter().date(from: $0) }
            posts.append(Post(id: id, title: title, html: synthesized,
                              publishedAt: published, link: link))
        }
        return posts
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return cleanURL((tag as NSString).substring(with: match.range(at: 1)))
    }

    private static func cleanURL(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&#x26;", with: "&", options: .caseInsensitive)
    }

    private static func absolute(_ href: String) -> String? {
        let clean = cleanURL(href)
        guard !clean.isEmpty else { return nil }
        if clean.hasPrefix("http") { return clean }
        if clean.hasPrefix("/") { return "https://www.reddit.com" + clean }
        return nil
    }

    private static func cleanText(_ raw: String) -> String {
        var text = raw
        if let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

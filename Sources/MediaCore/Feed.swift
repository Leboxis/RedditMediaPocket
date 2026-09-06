import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct Post: Identifiable {
    public let id: String
    public let title: String
    public let html: String
    public init(id: String, title: String, html: String) { self.id = id; self.title = title; self.html = html }
}

public enum Media: Hashable, Sendable {
    case direct(URL), redditVideo(URL), redgifs(String)
    public var key: String {
        switch self {
        case .direct(let url): return url.absoluteString
        case .redditVideo(let url): return url.absoluteString
        case .redgifs(let id): return "redgifs:" + id
        }
    }
}

public enum FeedError: LocalizedError {
    case invalidFeed, invalidUsername, invalidSubreddit, loginRequired, unsupportedVideo
    public var errorDescription: String? {
        switch self {
        case .unsupportedVideo: return "Manifest vidéo segmenté non pris en charge ; aucune qualité inférieure téléchargée."
        case .invalidFeed: return "Réponse RSS invalide : Reddit peut refuser cet accès anonyme."
        case .invalidUsername: return "Pseudo invalide (3 à 20 lettres, chiffres, tirets ou underscores, ex. u/pseudo)."
        case .invalidSubreddit: return "Subreddit invalide (2 à 21 lettres, chiffres ou underscores, ex. r/pics)."
        case .loginRequired: return "Connecte-toi à Reddit dans les Réglages, puis relance : les éléments sauvegardés exigent une session."
        }
    }
}

/// Source d'un parcours RSS : profil utilisateur, subreddit ou éléments
/// sauvegardés du compte connecté. Les trois exposent le même format Atom,
/// donc le même `FeedParser` s'applique. Pour `saved`, résoudre le lien privé
/// avec `SavedFeed` depuis les préférences du compte connecté avant le parcours.
public enum FeedSource: Hashable, Sendable {
    case user(String)
    case subreddit(String)
    case saved(String)

    /// Tri disponible pour les subreddits. `top` utilise `t=month` côté serveur.
    public static let subredditSorts = ["new", "hot", "top"]

    /// Accepte `u/pseudo`, `r/sub`, `saved/pseudo` ou un pseudo nu
    /// (compatibilité : profil utilisateur).
    public static func parse(_ text: String) throws -> FeedSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("saved/") {
            return try .saved(MediaExtractor.username(String(trimmed.dropFirst(6))))
        }
        if lower.hasPrefix("r/") {
            return try .subreddit(subredditName(String(trimmed.dropFirst(2))))
        }
        if lower.hasPrefix("u/") {
            return try .user(MediaExtractor.username(String(trimmed.dropFirst(2))))
        }
        return try .user(MediaExtractor.username(trimmed))
    }

    public static func subredditName(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9_]{2,21}$", options: .regularExpression) != nil else {
            throw FeedError.invalidSubreddit
        }
        return name
    }

    /// Identifiant canonique stable (`u/pseudo`, `r/sub` ou `saved/pseudo`),
    /// utilisé comme clé de collection.
    public var id: String {
        switch self {
        case .user(let name): return "u/\(name)"
        case .subreddit(let name): return "r/\(name)"
        case .saved(let name): return "saved/\(name)"
        }
    }

    public var displayName: String {
        switch self {
        case .saved(let name): return "♥ \(name)"
        default: return id
        }
    }

    /// Dossier de stockage. Les préfixes `r.` et `saved.` (point interdit dans
    /// les pseudos) évitent toute collision entre profil, subreddit et sauvegardés.
    public var folderName: String {
        switch self {
        case .user(let name): return name
        case .subreddit(let name): return "r.\(name)"
        case .saved(let name): return "saved.\(name)"
        }
    }

    /// URL RSS publique (non authentifiée pour saved ; utiliser SavedFeed).
    /// `after` est le curseur `t3_…` du dernier post vu.
    /// `sort` ne s'applique qu'aux subreddits (`new`, `hot`, `top` + `t=month`).
    public func feedURL(sort: String = "new", after: String? = nil) -> URL {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "100")]
        if let after { items.append(URLQueryItem(name: "after", value: after)) }
        switch self {
        case .user(let name):
            var components = URLComponents(string: "https://www.reddit.com/user/\(name)/submitted.rss")!
            components.queryItems = items
            return components.url!
        case .saved(let name):
            var components = URLComponents(string: "https://www.reddit.com/user/\(name)/saved.rss")!
            components.queryItems = items
            return components.url!
        case .subreddit(let name):
            let acknowledged = Self.subredditSorts.contains(sort) ? sort : "new"
            let path: String
            switch acknowledged {
            case "hot": path = "hot"
            case "top": path = "top"
            default: path = "new"
            }
            var components = URLComponents(string: "https://www.reddit.com/r/\(name)/\(path).rss")!
            if acknowledged == "top" {
                components.queryItems = [URLQueryItem(name: "t", value: "month")] + items
            } else {
                components.queryItems = items
            }
            return components.url!
        }
    }
}

public final class FeedParser: NSObject, XMLParserDelegate {
    private var posts: [Post] = []
    private var inEntry = false
    private var element = ""
    private var id = "", title = "", html = ""
    private var isFeed = false
    public static func parse(_ data: Data) throws -> [Post] {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isFeed else { throw FeedError.invalidFeed }
        return delegate.posts
    }
    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "feed" { isFeed = true }
        if name == "entry" { inEntry = true; id = ""; title = ""; html = "" }
    }
    public func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard inEntry else { return }
        switch element { case "id": id += text; case "title": title += text; case "content": html += text; default: break }
    }
    public func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "entry" { if !id.isEmpty { posts.append(Post(id: id, title: title, html: html)) }; inEntry = false }
        element = ""
    }
}

public enum MediaExtractor {
    public static func username(_ text: String) throws -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("u/") { name.removeFirst(2) }
        guard name.range(of: "^[A-Za-z0-9_-]{3,20}$", options: .regularExpression) != nil else { throw FeedError.invalidUsername }
        return name
    }
    public static func extract(_ html: String) -> [Media] {
        // Only linked originals; RSS thumbnails and preview.redd.it are intentionally ignored.
        let regex = try! NSRegularExpression(pattern: #"(?i)href\s*=\s*["']([^"']+)["']"#)
        let ns = html as NSString
        var seen = Set<Media>()
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
            var media: Media?
            if host == "v.redd.it", let id = url.pathComponents.dropFirst().first, !id.isEmpty {
                media = .redditVideo(URL(string: "https://v.redd.it/\(id)")!)
            } else if host == "redgifs.com" || host == "www.redgifs.com" {
                let parts = url.pathComponents
                if parts.count >= 3, ["watch", "ifr"].contains(parts[1]), parts[2].range(of: "^[a-zA-Z]+$", options: .regularExpression) != nil {
                    media = .redgifs(parts[2].lowercased())
                }
            } else if ["i.redd.it", "i.imgur.com"].contains(host), ["jpg", "jpeg", "png", "gif", "webp", "mp4"].contains(url.pathExtension.lowercased()) {
                media = .direct(QualityPolicy.originalImageURL(url))
            }
            guard let media, seen.insert(media).inserted else { return nil }
            return media
        }
    }
}

public struct DASHTracks {
    public let video: URL
    public let audio: URL?
}
public final class DASHParser: NSObject, XMLParserDelegate {
    private struct Track {
        let path: String
        let height: Int
        let width: Int
        let fps: Double
        let bandwidth: Int
    }
    private var adaptation: [String: String] = [:]
    private var attributes: [String: String] = [:]
    private var base = "", element = ""
    private var inRepresentation = false
    private var segmented = false
    private var adaptationSegmented = false
    private var unsupportedSegments = false
    private var videos: [Track] = [], audios: [Track] = []

    public static func parse(_ data: Data, relativeTo url: URL) throws -> DASHTracks {
        let d = DASHParser(); let p = XMLParser(data: data); p.delegate = d
        p.shouldResolveExternalEntities = false
        guard p.parse() else { throw FeedError.invalidFeed }
        guard !d.unsupportedSegments else { throw FeedError.unsupportedVideo }
        guard let best = d.videos.max(by: {
            if $0.height != $1.height { return $0.height < $1.height }
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.fps != $1.fps { return $0.fps < $1.fps }
            return $0.bandwidth < $1.bandwidth
        }), let video = URL(string: best.path, relativeTo: url)?.absoluteURL else { throw FeedError.invalidFeed }
        let audio = d.audios.max(by: { $0.bandwidth < $1.bandwidth }).flatMap { URL(string: $0.path, relativeTo: url)?.absoluteURL }
        return DASHTracks(video: video, audio: audio)
    }
    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        element = name
        if name == "AdaptationSet" { adaptation = attrs; adaptationSegmented = false }
        if name == "Representation" {
            inRepresentation = true; attributes = adaptation.merging(attrs) { _, new in new }; base = ""; segmented = adaptationSegmented
        }
        if name == "SegmentTemplate" || name == "SegmentList" {
            unsupportedSegments = true
            if inRepresentation { segmented = true } else { adaptationSegmented = true }
        }
    }
    public func parser(_ parser: XMLParser, foundCharacters text: String) {
        if element == "BaseURL", inRepresentation { base += text }
    }
    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "Representation" {
            let value = base.trimmingCharacters(in: .whitespacesAndNewlines)
            let mime = attributes["mimeType"] ?? attributes["contentType"] ?? ""
            let fpsParts = (attributes["frameRate"] ?? "0").split(separator: "/").compactMap { Double($0) }
            let fps = fpsParts.count == 2 && fpsParts[1] > 0 ? fpsParts[0] / fpsParts[1] : (fpsParts.first ?? 0)
            if !value.isEmpty, !segmented {
                let track = Track(path: value, height: Int(attributes["height"] ?? "0") ?? 0,
                    width: Int(attributes["width"] ?? "0") ?? 0, fps: fps,
                    bandwidth: Int(attributes["bandwidth"] ?? "0") ?? 0)
                if mime.hasPrefix("video") { videos.append(track) }
                if mime.hasPrefix("audio") { audios.append(track) }
            }
            inRepresentation = false
        }
        if name == "AdaptationSet" { adaptation = [:]; adaptationSegmented = false }
        element = ""
    }
}

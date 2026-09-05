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
    case invalidFeed, invalidUsername
    public var errorDescription: String? {
        switch self {
        case .invalidFeed: return "Réponse RSS invalide : Reddit peut refuser cet accès anonyme."
        case .invalidUsername: return "Pseudo invalide (3 à 20 lettres, chiffres, tirets ou underscores)."
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
                media = .direct(url)
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
    private var adaptationMime = "", mime = "", height = 0, base = ""
    private var readingBase = false
    private var inRepresentation = false
    private var videos: [(Int, String)] = [], audios: [String] = []
    public static func parse(_ data: Data, relativeTo url: URL) throws -> DASHTracks {
        let d = DASHParser(); let p = XMLParser(data: data); p.delegate = d
        p.shouldResolveExternalEntities = false
        guard p.parse(), let best = d.videos.max(by: { $0.0 < $1.0 }), let video = URL(string: best.1, relativeTo: url)?.absoluteURL else { throw FeedError.invalidFeed }
        let audio = d.audios.first.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        return DASHTracks(video: video, audio: audio)
    }
    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "AdaptationSet" { adaptationMime = attributes["mimeType"] ?? attributes["contentType"] ?? "" }
        if name == "Representation" { inRepresentation = true; mime = attributes["mimeType"] ?? adaptationMime; height = Int(attributes["height"] ?? "0") ?? 0; base = "" }
        if name == "BaseURL", inRepresentation { readingBase = true }
    }
    public func parser(_ parser: XMLParser, foundCharacters text: String) { if readingBase { base += text } }
    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "BaseURL" { readingBase = false }
        if name == "Representation" {
            let value = base.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { if mime.hasPrefix("video") { videos.append((height, value)) }; if mime.hasPrefix("audio") { audios.append(value) } }
            inRepresentation = false
        }
    }
}

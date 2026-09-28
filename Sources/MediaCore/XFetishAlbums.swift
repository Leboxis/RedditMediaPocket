import Foundation

public enum XFetishError: LocalizedError {
    case invalidListing, invalidGallery, tooManyPages

    public var errorDescription: String? {
        switch self {
        case .invalidListing:
            return L("Liste des albums X-Fetish illisible ou refusée par le site.", "X-Fetish album list is unreadable or denied by the site.")
        case .invalidGallery:
            return L("Album X-Fetish illisible ou incomplet.", "X-Fetish album is unreadable or incomplete.")
        case .tooManyPages:
            return L("Trop de pages d’albums X-Fetish à parcourir.", "Too many X-Fetish album pages to scan.")
        }
    }
}

/// Parses only public album links and full image links published by X-Fetish.
/// Site HTML and its asynchronous gallery fragments are intentionally separate
/// from Reddit's RSS parser.
public enum XFetishAlbums {
    public struct Album: Sendable {
        public let id: String
        public let title: String
        public let url: URL

        public init(id: String, title: String, url: URL) {
            self.id = id; self.title = title; self.url = url
        }
    }

    public struct Image: Sendable {
        public let id: String
        public let url: URL

        public init(id: String, url: URL) {
            self.id = id; self.url = url
        }
    }

    public struct ListingPage: Sendable {
        public let albums: [Album]
        public let nextPage: Int?
    }

    public struct GalleryPage: Sendable {
        public let images: [Image]
        public let extraPages: Int
    }

    private static let anchorRegex = try! NSRegularExpression(pattern: #"(?is)<a\b[^>]*>"#)
    private static let divRegex = try! NSRegularExpression(pattern: #"(?is)</?div\b[^>]*>"#)
    private static let attributeRegex = try! NSRegularExpression(pattern: #"(?i)\b([a-z][a-z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let slugRegex = try! NSRegularExpression(pattern: #"^[a-z0-9_-]{1,80}$"#)
    private static let imageIDRegex = try! NSRegularExpression(pattern: #"^[0-9]+$"#)

    public static func modelName(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard slugRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else {
            throw FeedError.invalidXFetishProfile
        }
        return name
    }

    public static func listingURL(model: String, page: Int) -> URL {
        let suffix = page <= 1 ? "" : "\(page)/"
        return URL(string: "https://x-fetish.tube/models/\(model)/albums/\(suffix)")!
    }

    public static func extraImagesURL(album: Album, page: Int) -> URL {
        var parts = URLComponents(url: album.url, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "mode", value: "async"),
            URLQueryItem(name: "function", value: "get_block"),
            URLQueryItem(name: "block_id", value: "album_view_album_view"),
            URLQueryItem(name: "load", value: "more"),
            URLQueryItem(name: "from", value: String(page))
        ]
        return parts.url!
    }

    public static func parseListing(_ data: Data, model: String, page: Int) throws -> ListingPage {
        let html = String(decoding: data, as: UTF8.self)
        guard let listingHTML = divSection(id: "list_albums_common_albums_list", in: html) else {
            throw XFetishError.invalidListing
        }
        let base = listingURL(model: model, page: page)
        var albums: [Album] = []
        var seen = Set<String>()
        var nextPage: Int?
        for tag in anchorTags(listingHTML) {
            let attrs = attributes(tag)
            guard let raw = attrs["href"], let url = siteURL(raw, relativeTo: base) else { continue }
            let parts = pathParts(url)
            if parts.count == 3, parts[0] == "albums", numeric(parts[1]),
               slugRegex.firstMatch(in: parts[2].lowercased(), range: NSRange(parts[2].startIndex..., in: parts[2])) != nil {
                if seen.insert(parts[1]).inserted {
                    let title = decoded(attrs["title"] ?? parts[2].replacingOccurrences(of: "-", with: " "))
                    albums.append(Album(id: parts[1], title: title, url: url))
                }
            } else if parts.count == 4, parts[0] == "models", parts[1].lowercased() == model.lowercased(),
                      parts[2] == "albums", let candidate = Int(parts[3]), candidate > page {
                nextPage = min(nextPage ?? candidate, candidate)
            }
        }
        return ListingPage(albums: albums, nextPage: nextPage)
    }

    public static func parseGallery(_ data: Data, album: Album) throws -> GalleryPage {
        let html = String(decoding: data, as: UTF8.self)
        guard let galleryHTML = divSection(id: "albumGallery", in: html) else {
            throw XFetishError.invalidGallery
        }
        var extraPages = 0
        for tag in anchorTags(html) {
            let attrs = attributes(tag)
            let classes = (attrs["class"] ?? "").split(separator: " ")
            if classes.contains("js-ajax-images2") {
                guard let raw = attrs["data-total"], let count = Int(raw), (0...1000).contains(count) else {
                    throw XFetishError.invalidGallery
                }
                extraPages = count
                break
            }
            if classes.contains("js-ajax-images") { extraPages = 1 }
        }
        let images = parseImages(Data(galleryHTML.utf8), albumID: album.id)
        if images.isEmpty && extraPages == 0 { throw XFetishError.invalidGallery }
        return GalleryPage(images: images, extraPages: extraPages)
    }

    public static func parseImages(_ data: Data, albumID: String) -> [Image] {
        let html = String(decoding: data, as: UTF8.self)
        let base = URL(string: "https://x-fetish.tube/")!
        var images: [Image] = []
        var seen = Set<String>()
        for tag in anchorTags(html) {
            let attrs = attributes(tag)
            guard (attrs["rel"] ?? "").split(separator: " ").contains("screenshots"),
                  let raw = attrs["href"], let url = siteURL(raw, relativeTo: base) else { continue }
            let parts = pathParts(url)
            guard parts.count == 7, parts[0] == "get_image", parts[3] == "sources",
                  parts[5] == albumID, numeric(parts[4]) else { continue }
            let file = URL(fileURLWithPath: parts[6])
            let id = file.deletingPathExtension().lastPathComponent
            guard numeric(id), ["jpg", "jpeg", "png", "webp", "gif"].contains(file.pathExtension.lowercased()),
                  seen.insert(id).inserted else { continue }
            images.append(Image(id: id, url: url))
        }
        return images
    }

    public static func parseExtraImages(_ data: Data, albumID: String, hasEarlierImages: Bool) throws -> [Image]? {
        let images = parseImages(data, albumID: albumID)
        guard !images.isEmpty else { throw XFetishError.invalidGallery }
        return images
    }

    private static func numeric(_ value: String) -> Bool {
        imageIDRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func pathParts(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    private static func siteURL(_ raw: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: decoded(raw), relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host?.lowercased() == "x-fetish.tube",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private static func decoded(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func anchorTags(_ html: String) -> [String] {
        let ns = html as NSString
        return anchorRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private static func divSection(id: String, in html: String) -> String? {
        let ns = html as NSString
        let tags = divRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var start: Int?
        var depth = 0
        for match in tags {
            let tag = ns.substring(with: match.range)
            if start == nil {
                guard !tag.hasPrefix("</"), attributes(tag)["id"] == id else { continue }
                start = match.range.location
            }
            depth += tag.hasPrefix("</") ? -1 : 1
            if depth == 0, let start {
                return ns.substring(with: NSRange(location: start, length: NSMaxRange(match.range) - start))
            }
        }
        return nil
    }

    private static func attributes(_ tag: String) -> [String: String] {
        let ns = tag as NSString
        var attrs: [String: String] = [:]
        for match in attributeRegex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let valueRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            attrs[key] = ns.substring(with: valueRange)
        }
        return attrs
    }
}

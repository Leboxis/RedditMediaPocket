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
    public struct Album: Hashable, Sendable {
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

    /// Cible d'un champ X-Fetish : un profil (catalogue complet), des adresses
    /// de vidéo ou d'album (sélection), ou un mélange. Quand le modèle est
    /// nommé à côté d'une sélection, il ne donne que le nom de la collection.
    public struct Target: Hashable, Sendable {
        public let model: String?
        public let videos: [XFetishVideos.Video]
        public let albums: [Album]

        public init(model: String?, videos: [XFetishVideos.Video], albums: [Album]) {
            self.model = model; self.videos = videos; self.albums = albums
        }

        /// Nom de collection : le modèle, ou un nom neutre stable pour une
        /// sélection sans modèle (`videos`, `albums` pour des albums seuls).
        public var collectionName: String {
            if let model { return model }
            return !videos.isEmpty ? "videos" : "albums"
        }
    }

    public static func modelName(_ text: String) throws -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("x/") { name.removeFirst(2) }
        // Adresse du profil collée telle quelle : seul `/models/<nom>/` vaut
        // profil. Une adresse `/video/` ou `/albums/` n'est pas un modèle.
        if name.contains("://"), let url = URL(string: name),
           url.host?.lowercased() == "x-fetish.tube" || url.host?.lowercased().hasSuffix(".x-fetish.tube") == true {
            let parts = XFetishHTML.pathParts(url)
            guard parts.count >= 2, parts[0].lowercased() == "models" else {
                throw FeedError.invalidXFetishProfile
            }
            name = parts[1]
        }
        name = name.lowercased()
        guard XFetishHTML.slug(name) else { throw FeedError.invalidXFetishProfile }
        return name
    }

    /// Une page `/video/<id>/<titre>/` désigne une vidéo précise, pas un modèle.
    public static func parseVideoRef(_ raw: String) -> XFetishVideos.Video? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let url = URL(string: value.contains("://") ? value : "https://" + value),
              url.scheme == "https",
              url.host?.lowercased() == "x-fetish.tube" || url.host?.lowercased().hasSuffix(".x-fetish.tube") == true,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        let parts = XFetishHTML.pathParts(url)
        guard parts.count >= 2, parts[0] == "video", XFetishHTML.numeric(parts[1]) else { return nil }
        let slug = parts.count >= 3 ? parts[2] : ""
        let title = XFetishHTML.decoded(slug.replacingOccurrences(of: "-", with: " "))
        return XFetishVideos.Video(id: parts[1], title: title.isEmpty ? "Vidéo \(parts[1])" : title,
                                    url: URL(string: "https://x-fetish.tube/video/\(parts[1])/\(slug.isEmpty ? "" : slug + "/")")!)
    }

    /// Une page `/albums/<id>/<titre>/` désigne un album précis, pas un modèle.
    public static func parseAlbumRef(_ raw: String) -> Album? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let url = URL(string: value.contains("://") ? value : "https://" + value),
              url.scheme == "https",
              url.host?.lowercased() == "x-fetish.tube" || url.host?.lowercased().hasSuffix(".x-fetish.tube") == true,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        let parts = XFetishHTML.pathParts(url)
        guard parts.count >= 2, parts[0] == "albums", XFetishHTML.numeric(parts[1]) else { return nil }
        let slug = parts.count >= 3 ? parts[2] : ""
        guard slug.isEmpty || XFetishHTML.pathComponent(slug) else { return nil }
        let title = XFetishHTML.decoded(slug.replacingOccurrences(of: "-", with: " "))
        return Album(id: parts[1], title: title.isEmpty ? "Album \(parts[1])" : title,
                     url: URL(string: "https://x-fetish.tube/albums/\(parts[1])/\(slug.isEmpty ? "" : slug + "/")")!)
    }

    /// Le champ accepte plusieurs adresses (une par ligne, ou séparées par des
    /// virgules) : profil, vidéos, albums, ou un mélange.
    public static func parseTarget(_ input: String) throws -> Target {
        var model: String?
        var videos: [XFetishVideos.Video] = []
        var albums: [Album] = []
        var seenVideos = Set<String>()
        var seenAlbums = Set<String>()
        let tokens = input.split { $0.isWhitespace || $0 == "," || $0 == ";" }.map(String.init)
        for token in tokens {
            if let video = parseVideoRef(token) {
                if seenVideos.insert(video.id).inserted { videos.append(video) }
                continue
            }
            if let album = parseAlbumRef(token) {
                if seenAlbums.insert(album.id).inserted { albums.append(album) }
                continue
            }
            model = try modelName(token)
        }
        guard model != nil || !videos.isEmpty || !albums.isEmpty else {
            throw FeedError.invalidXFetishProfile
        }
        return Target(model: model, videos: videos, albums: albums)
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
        guard let listingHTML = XFetishHTML.divSection(id: "list_albums_common_albums_list", in: html) else {
            throw XFetishError.invalidListing
        }
        let base = listingURL(model: model, page: page)
        var albums: [Album] = []
        var seen = Set<String>()
        var nextPage: Int?
        for tag in XFetishHTML.anchorTags(listingHTML) {
            let attrs = XFetishHTML.attributes(tag)
            guard let raw = attrs["href"], let url = XFetishHTML.siteURL(raw, relativeTo: base) else { continue }
            let parts = XFetishHTML.pathParts(url)
            if parts.count == 3, parts[0] == "albums", XFetishHTML.numeric(parts[1]),
               XFetishHTML.pathComponent(parts[2]) {
                if seen.insert(parts[1]).inserted {
                    let title = XFetishHTML.decoded(attrs["title"] ?? parts[2].replacingOccurrences(of: "-", with: " "))
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
        guard let galleryHTML = XFetishHTML.divSection(id: "albumGallery", in: html) else {
            throw XFetishError.invalidGallery
        }
        var extraPages = 0
        for tag in XFetishHTML.anchorTags(html) {
            let attrs = XFetishHTML.attributes(tag)
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
        let base = XFetishHTML.siteRoot
        var images: [Image] = []
        var seen = Set<String>()
        for tag in XFetishHTML.anchorTags(html) {
            let attrs = XFetishHTML.attributes(tag)
            guard (attrs["rel"] ?? "").split(separator: " ").contains("screenshots"),
                  let raw = attrs["href"], let url = XFetishHTML.siteURL(raw, relativeTo: base) else { continue }
            let parts = XFetishHTML.pathParts(url)
            guard parts.count == 7, parts[0] == "get_image", parts[3] == "sources",
                  parts[5] == albumID, XFetishHTML.numeric(parts[4]) else { continue }
            let file = URL(fileURLWithPath: parts[6])
            let id = file.deletingPathExtension().lastPathComponent
            guard XFetishHTML.numeric(id),
                  ["jpg", "jpeg", "png", "webp", "gif"].contains(file.pathExtension.lowercased()),
                  seen.insert(id).inserted else { continue }
            images.append(Image(id: id, url: url))
        }
        return images
    }

    public static func parseExtraImages(_ data: Data, albumID: String, hasEarlierImages: Bool) throws -> [Image]? {
        if data.isEmpty {
            guard hasEarlierImages else { throw XFetishError.invalidGallery }
            return nil
        }
        let images = parseImages(data, albumID: albumID)
        guard !images.isEmpty else { throw XFetishError.invalidGallery }
        return images
    }
}

import Foundation

public enum XFetishVideoError: LocalizedError {
    case invalidListing, invalidPlayer

    public var errorDescription: String? {
        switch self {
        case .invalidListing:
            return L("Liste des vidéos X-Fetish illisible ou refusée par le site.", "X-Fetish video list is unreadable or denied by the site.")
        case .invalidPlayer:
            return L("Page vidéo X-Fetish illisible : aucun fichier signé n’y est publié.", "X-Fetish video page is unreadable: no signed file is published on it.")
        }
    }
}

/// Sélecteur de médias des collections X-Fetish. `images` reste la valeur par
/// défaut : le comportement historique (albums seuls) ne doit pas changer pour
/// les installations existantes.
public enum XFetishMediaKind: String, CaseIterable, Sendable {
    case images, videos, both

    public static let defaultsKey = "xFetishMediaKind"

    public var includesImages: Bool { self != .videos }
    public var includesVideos: Bool { self != .images }
}

/// Lecteur des pages vidéo publiques de X-Fetish. La liste `/models/<n>/videos/`
/// ne publie que des liens `/video/<id>/<slug>/` ; le fichier signé
/// `get_file` n'apparaît que dans le script du lecteur de la page vidéo et
/// n'est valable que peu de temps, d'où une lecture de page par vidéo et par
/// exécution. La même adresse IPv4 que `get_file` sert ensuite au téléchargement.
public enum XFetishVideos {
    public struct Video: Sendable {
        public let id: String
        public let title: String
        public let url: URL

        public init(id: String, title: String, url: URL) {
            self.id = id; self.title = title; self.url = url
        }
    }

    public struct ListingPage: Sendable {
        public let videos: [Video]
        public let nextPage: Int?
    }

    /// Le lecteur publie la route signée sous `video_url: '…'`. `event_reporting2`
    /// et `preview_url` pointent vers d'autres ressources : ils ne sont pas lus.
    private static let playerURLRegex = try! NSRegularExpression(
        pattern: #"video_url\s*:\s*'([^']+)'"#, options: [.caseInsensitive])
    /// `/get_file/<id>/<hash>/<dossier>/<id>/<fichier>.mp4` : rien d'autre n'est
    /// accepté comme média téléchargeable.
    private static let signedRouteRegex = try! NSRegularExpression(
        pattern: #"^/get_file/\d+/[0-9a-f]{8,64}/\d+/\d+/([0-9]+(?:_[0-9A-Za-z._-]+)?\.mp4)$"#)

    public static func listingURL(model: String, page: Int) -> URL {
        let suffix = page <= 1 ? "" : "\(page)/"
        return URL(string: "https://x-fetish.tube/models/\(model)/videos/\(suffix)")!
    }

    public static func parseListing(_ data: Data, model: String, page: Int) throws -> ListingPage {
        let html = String(decoding: data, as: UTF8.self)
        guard let listingHTML = XFetishHTML.divSection(id: "list_videos_common_videos_list", in: html) else {
            throw XFetishVideoError.invalidListing
        }
        let base = listingURL(model: model, page: page)
        var videos: [Video] = []
        var seen = Set<String>()
        var nextPage: Int?
        for tag in XFetishHTML.anchorTags(listingHTML) {
            let attrs = XFetishHTML.attributes(tag)
            guard let raw = attrs["href"], let url = XFetishHTML.siteURL(raw, relativeTo: base) else { continue }
            let parts = XFetishHTML.pathParts(url)
            if parts.count == 3, parts[0] == "video", XFetishHTML.numeric(parts[1]),
               XFetishHTML.pathComponent(parts[2]) {
                if seen.insert(parts[1]).inserted {
                    let title = XFetishHTML.decoded(attrs["title"] ?? parts[2].replacingOccurrences(of: "-", with: " "))
                    videos.append(Video(id: parts[1], title: title, url: url))
                }
            } else if parts.count == 4, parts[0] == "models", parts[1].lowercased() == model.lowercased(),
                      parts[2] == "videos", let candidate = Int(parts[3]), candidate > page {
                nextPage = min(nextPage ?? candidate, candidate)
            }
        }
        return ListingPage(videos: videos, nextPage: nextPage)
    }

    /// Route signée du lecteur. Le jeton reste dans l'URL retournée et n'est
    /// jamais journalisé (`LogDiagnostics`).
    public static func parseFileURL(_ data: Data, video: Video) throws -> URL {
        let html = String(decoding: data, as: UTF8.self)
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = playerURLRegex.firstMatch(in: html, range: range) else {
            throw XFetishVideoError.invalidPlayer
        }
        let raw = ns.substring(with: match.range(at: 1))
        guard let url = XFetishHTML.siteURL(raw, relativeTo: XFetishHTML.siteRoot),
              let route = signedRouteRegex.firstMatch(in: url.path,
                                                      range: NSRange(url.path.startIndex..., in: url.path)) else {
            throw XFetishVideoError.invalidPlayer
        }
        // The route must be the file of this very video: the same page also
        // advertises other `get_file` resources for previews and reporting.
        let name = (url.path as NSString).substring(with: route.range(at: 1))
        guard name == "\(video.id).mp4" || name.hasPrefix("\(video.id)_") else {
            throw XFetishVideoError.invalidPlayer
        }
        return url
    }
}

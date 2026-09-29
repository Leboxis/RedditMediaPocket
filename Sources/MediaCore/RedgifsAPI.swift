import Foundation

/// Requête RedGIFs alignée sur les implémentations de référence
/// (yt-dlp, gallery-dl) : ID en minuscules, `?views=yes`, en-têtes
/// Referer/Origin/x-customheader. Le jeton temporaire de RedGIFs est
/// lié à l'agent et à l'adresse ; ces en-têtes reproduisent le trafic
/// du lecteur web au lieu d'un appel nu.
public enum RedgifsAPI {
    public static func gifURL(id: String) -> URL {
        var components = URLComponents(string: "https://api.redgifs.com/v2/gifs/\(id.lowercased())")!
        components.queryItems = [URLQueryItem(name: "views", value: "yes")]
        return components.url!
    }

    public static func headers(id: String) -> [String: String] {
        let lowered = id.lowercased()
        return [
            "Referer": "https://www.redgifs.com/",
            "Origin": "https://www.redgifs.com",
            "x-customheader": "https://www.redgifs.com/watch/\(lowered)"
        ]
    }

    /// Pseudo RedGifs : 3 à 30 lettres, chiffres, underscores ou tirets.
    /// Plus large que les pseudos Reddit (3-20) pour les comptes existants.
    public static func username(_ text: String) throws -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("rg/") { name = String(name.dropFirst(3)) }
        else if name.lowercased().hasPrefix("g/") { name = String(name.dropFirst(2)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9_-]{3,30}$", options: .regularExpression) != nil else {
            throw FeedError.invalidUsername
        }
        return name
    }

    /// Recherche paginée des contenus d'un compte (`order=new`, `count=80`).
    /// Vérifié le 29/09/2026 sur `upset_trash_3094` : 158 gifs, 2 pages,
    /// `urls.hd == detail hd`, HD 1080x1920 ~22 Mo vs SD ~3,7 Mo.
    public static func userSearchURL(username: String, page: Int = 1, count: Int = 80) -> URL {
        var components = URLComponents(string: "https://api.redgifs.com/v2/users/\(username.lowercased())/search")!
        components.queryItems = [
            URLQueryItem(name: "order", value: "new"),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "count", value: String(min(100, max(1, count))))
        ]
        return components.url!
    }
}

/// Réponse `GET /v2/users/<pseudo>/search` : seule la liste `gifs` et la
/// pagination sont exploitées (`hd` = meilleure qualité, `sd` = repli).
public struct RedgifsUserSearchResponse: Decodable {
    public struct URLs: Decodable {
        public let hd: URL?
        public let sd: URL?
    }
    public struct Gif: Decodable {
        public let id: String
        public let urls: URLs
    }
    public let gifs: [Gif]
    public let page: Int
    public let pages: Int
    public let total: Int?

    public init(gifs: [Gif], page: Int, pages: Int, total: Int? = nil) {
        self.gifs = gifs
        self.page = page
        self.pages = pages
        self.total = total
    }
}

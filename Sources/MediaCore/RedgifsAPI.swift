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

    /// Recherche paginée par mot-clé ou tag (`order=new`). C'est la route que
    /// le lecteur web appelle quand on ouvre un tag : même pagination que la
    /// recherche de compte, donc le même parcours peut la consommer.
    public static func searchURL(text: String, page: Int = 1, count: Int = 80) -> URL {
        var components = URLComponents(string: "https://api.redgifs.com/v2/gifs/search")!
        components.queryItems = [
            URLQueryItem(name: "search_text", value: text),
            URLQueryItem(name: "order", value: "new"),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "count", value: String(min(100, max(1, count))))
        ]
        return components.url!
    }

    /// Tag ou mot-clé : minuscules, lettres/chiffres, tirets et underscores.
    /// Les espaces sont convertis en tirets, comme dans les adresses du site.
    public static func tag(_ text: String) throws -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("rg/") { name = String(name.dropFirst(3)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Forme `#tag` et adresse `redgifs.com/niches/<tag>` ou
        // `/gifs/search?search_text=<tag>` acceptées telles quelles.
        if name.hasPrefix("#") { name = String(name.dropFirst()) }
        if let range = name.range(of: "(?:^|//)(?:www\\.)?redgifs\\.com/(?:niches/|gifs/search/?)",
                                  options: .regularExpression) {
            name = String(name[range.upperBound...])
            if let query = name.firstIndex(of: "?") { name = String(name[name.startIndex..<query]) }
        }
        if let query = name.firstIndex(of: "?") {
            let tail = String(name[name.index(after: query)...])
            if let value = tail.split(separator: "&")
                .first(where: { $0.hasPrefix("search_text=") })?
                .dropFirst("search_text=".count) {
                name = String(value)
            } else {
                name = String(name[name.startIndex..<query])
            }
        }
        name = name.replacingOccurrences(of: " ", with: "-").lowercased()
        guard name.range(of: "^[a-z0-9_-]{2,40}$", options: .regularExpression) != nil else {
            throw FeedError.invalidUsername
        }
        return name
    }

    /// Identifiant d'un GIF unique depuis une adresse `/watch/<id>` ou
    /// `/ifr/<id>`, ou depuis l'identifiant nu.
    public static func gifID(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("rg/") { value = String(value.dropFirst(3)) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "(?:^|//)(?:www\\.)?redgifs\\.com/(?:watch|ifr)/",
                                   options: .regularExpression) {
            value = String(value[range.upperBound...])
            value = String(value.prefix { $0.isLetter || $0.isNumber })
        }
        let lowered = value.lowercased()
        guard lowered.range(of: "^[a-z0-9]{5,32}$", options: .regularExpression) != nil else { return nil }
        return lowered
    }
}

/// Réponse `GET /v2/users/<pseudo>/search` ou `GET /v2/gifs/search` : seule la
/// liste `gifs` et la pagination sont exploitées (`hd` = meilleure qualité,
/// `sd` = repli).
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

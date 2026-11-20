import Foundation

/// Catégories d'éléments stockés dans la base, adaptées à RedditMediaPocket.
public enum TypeItem: String, Codable, Sendable {
    case collection
    case reglage
    case log
    case compteSuivi = "compte_suivi"
}

/// Un élément tel que renvoyé par le Worker.
/// `datetime('now')` de SQLite renvoie "AAAA-MM-JJ HH:MM:SS", qui n'est PAS du ISO-8601 :
/// les dates restent donc des String et aucun decoder.dateDecodingStrategy n'est utilisé.
public struct Item: Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String?
    public let type: String?
    public let data: JSONValue?
    public let createdAt: String
    public let updatedAt: String?

    public init(
        id: Int,
        name: String,
        description: String?,
        type: String?,
        data: JSONValue?,
        createdAt: String,
        updatedAt: String?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.data = data
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Données envoyées pour créer ou modifier un élément.
public struct ItemDraft: Encodable, Sendable {
    public var name: String
    public var type: String?
    public var description: String?
    public var data: JSONValue?

    public init(name: String, type: String? = nil, description: String? = nil, data: JSONValue? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.data = data
    }
}

/// Page d'éléments renvoyée par GET /api/items.
public struct ItemPage: Decodable, Sendable {
    public let page: Int
    public let limit: Int
    public let total: Int
    public let pages: Int
    public let items: [Item]
}

// MARK: - Structures typées des catégories choisies

/// Champs d'une collection, alignés sur `UserCollection` de l'app.
public struct DonneesCollection: Codable, Sendable {
    public var isSubreddit: Bool
    public var isSaved: Bool
    public var isXFetish: Bool
    public var isRedGifs: Bool
    public var isTwitter: Bool
    public var isTikTok: Bool
    public var isTikTokVideo: Bool
    public var isTikTokSaved: Bool
    public var isInstagram: Bool
    public var isRedGifsTag: Bool
    public var isRedGifsGif: Bool
    public var isRedditPosts: Bool
    public var archived: Bool
    public var lastRun: String?

    private enum CodingKeys: String, CodingKey {
        case isSubreddit, isSaved, isXFetish, isRedGifs, isTwitter, isTikTok, isTikTokVideo
        case isTikTokSaved, isInstagram, isRedGifsTag, isRedGifsGif, isRedditPosts
        case archived, lastRun
    }

    public init(
        isSubreddit: Bool = false,
        isSaved: Bool = false,
        isXFetish: Bool = false,
        isRedGifs: Bool = false,
        isTwitter: Bool = false,
        isTikTok: Bool = false,
        isTikTokVideo: Bool = false,
        isTikTokSaved: Bool = false,
        isInstagram: Bool = false,
        isRedGifsTag: Bool = false,
        isRedGifsGif: Bool = false,
        isRedditPosts: Bool = false,
        archived: Bool = false,
        lastRun: String? = nil
    ) {
        self.isSubreddit = isSubreddit
        self.isSaved = isSaved
        self.isXFetish = isXFetish
        self.isRedGifs = isRedGifs
        self.isTwitter = isTwitter
        self.isTikTok = isTikTok
        self.isTikTokVideo = isTikTokVideo
        self.isTikTokSaved = isTikTokSaved
        self.isInstagram = isInstagram
        self.isRedGifsTag = isRedGifsTag
        self.isRedGifsGif = isRedGifsGif
        self.isRedditPosts = isRedditPosts
        self.archived = archived
        self.lastRun = lastRun
    }

    public init(from decoder: Decoder) throws {
        let conteneur = try decoder.container(keyedBy: CodingKeys.self)
        isSubreddit = try conteneur.decodeIfPresent(Bool.self, forKey: .isSubreddit) ?? false
        isSaved = try conteneur.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
        isXFetish = try conteneur.decodeIfPresent(Bool.self, forKey: .isXFetish) ?? false
        isRedGifs = try conteneur.decodeIfPresent(Bool.self, forKey: .isRedGifs) ?? false
        isTwitter = try conteneur.decodeIfPresent(Bool.self, forKey: .isTwitter) ?? false
        isTikTok = try conteneur.decodeIfPresent(Bool.self, forKey: .isTikTok) ?? false
        isTikTokVideo = try conteneur.decodeIfPresent(Bool.self, forKey: .isTikTokVideo) ?? false
        isTikTokSaved = try conteneur.decodeIfPresent(Bool.self, forKey: .isTikTokSaved) ?? false
        isInstagram = try conteneur.decodeIfPresent(Bool.self, forKey: .isInstagram) ?? false
        isRedGifsTag = try conteneur.decodeIfPresent(Bool.self, forKey: .isRedGifsTag) ?? false
        isRedGifsGif = try conteneur.decodeIfPresent(Bool.self, forKey: .isRedGifsGif) ?? false
        isRedditPosts = try conteneur.decodeIfPresent(Bool.self, forKey: .isRedditPosts) ?? false
        archived = try conteneur.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        lastRun = try conteneur.decodeIfPresent(String.self, forKey: .lastRun)
    }

    /// Les noms de clés sont déjà en camelCase dans le JSON envoyé par l'app.
    public func encode(to encoder: Encoder) throws {
        var conteneur = encoder.container(keyedBy: CodingKeys.self)
        try conteneur.encode(isSubreddit, forKey: .isSubreddit)
        try conteneur.encode(isSaved, forKey: .isSaved)
        try conteneur.encode(isXFetish, forKey: .isXFetish)
        try conteneur.encode(isRedGifs, forKey: .isRedGifs)
        try conteneur.encode(isTwitter, forKey: .isTwitter)
        try conteneur.encode(isTikTok, forKey: .isTikTok)
        try conteneur.encode(isTikTokVideo, forKey: .isTikTokVideo)
        try conteneur.encode(isTikTokSaved, forKey: .isTikTokSaved)
        try conteneur.encode(isInstagram, forKey: .isInstagram)
        try conteneur.encode(isRedGifsTag, forKey: .isRedGifsTag)
        try conteneur.encode(isRedGifsGif, forKey: .isRedGifsGif)
        try conteneur.encode(isRedditPosts, forKey: .isRedditPosts)
        try conteneur.encode(archived, forKey: .archived)
        try conteneur.encodeIfPresent(lastRun, forKey: .lastRun)
    }
}

/// Un réglage : `name` est la clé, `valeur` le contenu.
public struct DonneesReglage: Codable, Sendable {
    public var valeur: String

    private enum CodingKeys: String, CodingKey { case valeur }

    public init(valeur: String = "") { self.valeur = valeur }

    public init(from decoder: Decoder) throws {
        let conteneur = try decoder.container(keyedBy: CodingKeys.self)
        valeur = try conteneur.decodeIfPresent(String.self, forKey: .valeur) ?? ""
    }
}

/// Une ligne du journal de bord (date en chaîne ISO, niveau, message).
public struct DonneesLog: Codable, Sendable {
    public var date: String
    public var niveau: String
    public var message: String

    private enum CodingKeys: String, CodingKey { case date, niveau, message }

    public init(date: String = "", niveau: String = "", message: String = "") {
        self.date = date
        self.niveau = niveau
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let conteneur = try decoder.container(keyedBy: CodingKeys.self)
        date = try conteneur.decodeIfPresent(String.self, forKey: .date) ?? ""
        niveau = try conteneur.decodeIfPresent(String.self, forKey: .niveau) ?? ""
        message = try conteneur.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// Un compte suivi ou sauvegardé (pseudo Reddit en minuscules).
public struct DonneesCompteSuivi: Codable, Sendable {
    public var pseudo: String

    private enum CodingKeys: String, CodingKey { case pseudo }

    public init(pseudo: String = "") { self.pseudo = pseudo }

    public init(from decoder: Decoder) throws {
        let conteneur = try decoder.container(keyedBy: CodingKeys.self)
        pseudo = try conteneur.decodeIfPresent(String.self, forKey: .pseudo) ?? ""
    }
}

extension Item {
    /// Décode `data` dans la structure typée correspondante et en tire un résumé lisible.
    public var resumeDonnees: String? {
        guard let data, let octets = try? JSONEncoder().encode(data) else { return nil }
        let decodeur = JSONDecoder()
        decodeur.keyDecodingStrategy = .convertFromSnakeCase
        switch TypeItem(rawValue: type ?? "") {
        case .collection:
            guard let donnees = try? decodeur.decode(DonneesCollection.self, from: octets) else { return nil }
            return donnees.archived
                ? L("Collection archivée", "Archived collection")
                : L("Collection active", "Active collection")
        case .reglage:
            guard let donnees = try? decodeur.decode(DonneesReglage.self, from: octets) else { return nil }
            return donnees.valeur
        case .log:
            guard let donnees = try? decodeur.decode(DonneesLog.self, from: octets) else { return nil }
            return "\(donnees.niveau) · \(donnees.message)"
        case .compteSuivi:
            guard let donnees = try? decodeur.decode(DonneesCompteSuivi.self, from: octets) else { return nil }
            return donnees.pseudo
        case nil:
            return nil
        }
    }
}

import Foundation
import MediaCore

/// Seule catégorie stockée sur le serveur : l'état des comptes Reddit suivis.
public enum TypeItem: String, Codable, Sendable {
    case suivi
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

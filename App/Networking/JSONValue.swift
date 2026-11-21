import Foundation

/// Valeur JSON générique utilisée pour le champ `data` des éléments distants.
/// Les champs connus de RedditMediaPocket sont décrits par des structs typés dans `Item.swift` :
/// ce type ne sert que de transport pour les valeurs dont la structure n'est pas figée.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let conteneur = try decoder.singleValueContainer()
        if conteneur.decodeNil() {
            self = .null
            return
        }
        if let valeur = try? conteneur.decode(Bool.self) {
            self = .bool(valeur)
            return
        }
        if let valeur = try? conteneur.decode(Double.self) {
            self = .number(valeur)
            return
        }
        if let valeur = try? conteneur.decode(String.self) {
            self = .string(valeur)
            return
        }
        if let valeur = try? conteneur.decode([JSONValue].self) {
            self = .array(valeur)
            return
        }
        if let valeur = try? conteneur.decode([String: JSONValue].self) {
            self = .object(valeur)
            return
        }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Valeur JSON non reconnue")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var conteneur = encoder.singleValueContainer()
        switch self {
        case .object(let valeur): try conteneur.encode(valeur)
        case .array(let valeur): try conteneur.encode(valeur)
        case .string(let valeur): try conteneur.encode(valeur)
        case .number(let valeur): try conteneur.encode(valeur)
        case .bool(let valeur): try conteneur.encode(valeur)
        case .null: try conteneur.encodeNil()
        }
    }
}

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

    /// Convertit une valeur issue de `JSONSerialization`/UserDefaults en `JSONValue`.
    public static func depuis(_ valeur: Any) -> JSONValue? {
        if valeur is NSNull { return .null }
        if let nombre = valeur as? NSNumber {
            if CFGetTypeID(nombre as CFTypeRef) == CFBooleanGetTypeID() { return .bool(nombre.boolValue) }
            return .number(nombre.doubleValue)
        }
        if let texte = valeur as? String { return .string(texte) }
        if let tableau = valeur as? [Any] {
            return .array(tableau.compactMap { depuis($0) })
        }
        if let dictionnaire = valeur as? [String: Any] {
            var resultat: [String: JSONValue] = [:]
            for (cle, valeur) in dictionnaire {
                if let convertie = depuis(valeur) { resultat[cle] = convertie }
            }
            return .object(resultat)
        }
        return nil
    }

    /// Convertit vers des types fondamentaux utilisables dans UserDefaults.
    public var valeurFondamentale: Any? {
        switch self {
        case .object(let dictionnaire):
            var resultat: [String: Any] = [:]
            for (cle, valeur) in dictionnaire {
                resultat[cle] = valeur.valeurFondamentale ?? NSNull()
            }
            return resultat
        case .array(let tableau):
            return tableau.compactMap { $0.valeurFondamentale }
        case .string(let texte): return texte
        case .number(let nombre): return NSNumber(value: nombre)
        case .bool(let booleen): return NSNumber(value: booleen)
        case .null: return NSNull()
        }
    }

    /// Sérialise en `Data` pour décoder un modèle typé.
    public func donneesJSON() -> Data? {
        guard let objet = valeurFondamentale,
              JSONSerialization.isValidJSONObject(objet) else { return nil }
        return try? JSONSerialization.data(withJSONObject: objet)
    }
}

import Foundation
import MediaCore

/// URL de base du Worker. Remplace l'hôte par celui affiché par `wrangler deploy`.
public enum ConfigurationAPI {
    public static let baseURL = URL(string: "https://mon-api.kedyaelfontaine.workers.dev/")!
}

/// Contrat du client, injectable dans les vues et les tests.
public protocol ItemsAPIClientProtocol: Sendable {
    func list(type: String?, search: String?, page: Int, limit: Int) async throws -> ItemPage
    func get(id: Int) async throws -> Item
    func create(_ brouillon: ItemDraft) async throws -> Item
    func update(id: Int, _ brouillon: ItemDraft) async throws -> Item
    func delete(id: Int) async throws
}

/// Client URLSession async/await, sans dépendance tierce.
public struct ItemsAPIClient: ItemsAPIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    /// Lit la clé dans le Keychain à chaque requête ; injectable pour les tests.
    private let fournisseurCle: @Sendable () -> String?

    public init(
        baseURL: URL = ConfigurationAPI.baseURL,
        session: URLSession? = nil,
        fournisseurCle: @escaping @Sendable () -> String? = { KeychainStore.get() }
    ) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.fournisseurCle = fournisseurCle
    }

    // MARK: - Construction des requêtes

    /// Construit l'URL avec URLComponents : aucune URL dynamique forcée.
    private func url(chemin: String, parametres: [URLQueryItem] = []) throws -> URL {
        var composants = URLComponents(
            url: baseURL.appendingPathComponent(chemin),
            resolvingAgainstBaseURL: false
        )
        guard composants != nil else { throw APIError.invalidResponse }
        if !parametres.isEmpty { composants?.queryItems = parametres }
        guard let url = composants?.url else { throw APIError.invalidResponse }
        return url
    }

    private func requete(_ url: URL, methode: String, corps: Data? = nil) throws -> URLRequest {
        var requete = URLRequest(url: url)
        requete.httpMethod = methode
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        if let corps {
            requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
            requete.httpBody = corps
        }
        guard let cle = fournisseurCle(), !cle.isEmpty else {
            throw APIError.httpError(statusCode: 401, message: L("Clé API absente du Keychain.", "API key missing from Keychain."))
        }
        requete.setValue(cle, forHTTPHeaderField: "X-API-Key")
        return requete
    }

    /// Exécute la requête, valide le code HTTP avant de décoder, puis mappe les erreurs.
    private func reponse(_ requete: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let donnees: Data
        let reponse: URLResponse
        do {
            (donnees, reponse) = try await session.data(for: requete)
        } catch let erreur as URLError {
            throw APIError.transport(erreur)
        } catch is CancellationError {
            throw APIError.transport(URLError(.cancelled))
        }
        guard let http = reponse as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = try? JSONDecoder().decode(ErreurServeur.self, from: donnees).erreur
            throw APIError.httpError(statusCode: http.statusCode, message: message)
        }
        return (donnees, http)
    }

    private func envoyer<T: Decodable & Sendable>(_ type: T.Type, _ requete: URLRequest) async throws -> T {
        let (donnees, _) = try await reponse(requete)
        let decodeur = JSONDecoder()
        decodeur.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decodeur.decode(T.self, from: donnees)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func encoder(_ brouillon: ItemDraft) throws -> Data {
        let encodeur = JSONEncoder()
        encodeur.keyEncodingStrategy = .convertToSnakeCase
        return try encodeur.encode(brouillon)
    }

    // MARK: - Opérations

    public func list(
        type: String? = nil,
        search: String? = nil,
        page: Int = 1,
        limit: Int = 20
    ) async throws -> ItemPage {
        var parametres: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
        ]
        if let type, !type.isEmpty {
            parametres.append(URLQueryItem(name: "type", value: type))
        }
        if let search, !search.isEmpty {
            parametres.append(URLQueryItem(name: "search", value: search))
        }
        let cible = try url(chemin: "api/items", parametres: parametres)
        return try await envoyer(ItemPage.self, requete(cible, methode: "GET"))
    }

    public func get(id: Int) async throws -> Item {
        let cible = try url(chemin: "api/items/\(id)")
        return try await envoyer(Item.self, requete(cible, methode: "GET"))
    }

    public func create(_ brouillon: ItemDraft) async throws -> Item {
        let cible = try url(chemin: "api/items")
        let requeteHTTP = try requete(cible, methode: "POST", corps: encoder(brouillon))
        return try await envoyer(Item.self, requeteHTTP)
    }

    public func update(id: Int, _ brouillon: ItemDraft) async throws -> Item {
        let cible = try url(chemin: "api/items/\(id)")
        let requeteHTTP = try requete(cible, methode: "PUT", corps: encoder(brouillon))
        return try await envoyer(Item.self, requeteHTTP)
    }

    public func delete(id: Int) async throws {
        let cible = try url(chemin: "api/items/\(id)")
        _ = try await reponse(requete(cible, methode: "DELETE"))
    }
}

/// Corps d'erreur du serveur : {"erreur": "..."}.
private struct ErreurServeur: Decodable {
    let erreur: String
}

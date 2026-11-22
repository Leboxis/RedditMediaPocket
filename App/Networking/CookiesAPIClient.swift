import Foundation
import MediaCore

/// Un cookie WebKit sérialisé : assez de champs pour reconstruire un `HTTPCookie`
/// équivalent dans le magasin WebKit de l'iPhone après une réinstallation.
/// Les valeurs ne sont jamais journalisées.
public struct CookieRecord: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    /// Nil pour un cookie de session (sans date d'expiration).
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool
    public var version: Int
    public var comment: String?
    public var commentURL: String?
    public var portList: [Int]?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expires: Date? = nil,
        secure: Bool = false,
        httpOnly: Bool = false,
        version: Int = 0,
        comment: String? = nil,
        commentURL: String? = nil,
        portList: [Int]? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.version = version
        self.comment = comment
        self.commentURL = commentURL
        self.portList = portList
    }

    public init?(cookie: HTTPCookie) {
        guard !cookie.name.isEmpty, !cookie.domain.isEmpty else { return nil }
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path
        self.expires = cookie.expiresDate
        self.secure = cookie.isSecure
        self.httpOnly = cookie.isHTTPOnly
        self.version = cookie.version
        self.comment = cookie.comment
        self.commentURL = cookie.commentURL?.absoluteString
        self.portList = cookie.portList?.map { $0.intValue }
    }

    /// Reconstruit un cookie, en ignorant les entrées expirées ou incomplètes.
    public func makeCookie(now: Date = Date()) -> HTTPCookie? {
        guard !name.isEmpty, !domain.isEmpty else { return nil }
        if let expires, expires <= now { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
            .version: version,
            .secure: secure,
        ]
        // Foundation ne publie pas de constante pour HttpOnly : la clé brute
        // est reconnue par HTTPCookie et par le magasin WebKit.
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires }
        if let comment { properties[.comment] = comment }
        if let commentURL, let url = URL(string: commentURL) { properties[.commentURL] = url }
        if let portList { properties[.port] = portList.map { NSNumber(value: $0) } }
        return HTTPCookie(properties: properties)
    }
}

/// Copie distante renvoyée par `GET /api/cookies`, par site.
public struct CookiesBackup: Codable, Sendable, Equatable {
    public var sites: [String: [CookieRecord]]
    public var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case sites
        case updatedAt = "updated_at"
    }

    public init(sites: [String: [CookieRecord]] = [:], updatedAt: String? = nil) {
        self.sites = sites
        self.updatedAt = updatedAt
    }
}

/// Corps envoyé à `PUT /api/cookies`. La date est gérée par le serveur.
private struct CookiesPayload: Encodable, Sendable {
    let sites: [String: [CookieRecord]]
}

/// Contrat injectable dans les vues et les tests.
public protocol CookiesAPIClientProtocol: Sendable {
    func lire() async throws -> CookiesBackup
    func ecrire(sites: [String: [CookieRecord]]) async throws
    func supprimer() async throws
}

/// Client URLSession async/await des sessions, avec la même clé que `/api/items`.
public struct CookiesAPIClient: CookiesAPIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
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

    private func url(chemin: String) throws -> URL {
        guard let cible = URLComponents(
            url: baseURL.appendingPathComponent(chemin),
            resolvingAgainstBaseURL: false
        )?.url else { throw APIError.invalidResponse }
        return cible
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
            throw APIError.httpError(
                statusCode: 401,
                message: L("Clé API absente du Keychain.", "API key missing from Keychain.")
            )
        }
        requete.setValue(cle, forHTTPHeaderField: "X-API-Key")
        return requete
    }

    private func reponse(_ requete: URLRequest) async throws -> Data {
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
        return donnees
    }

    public func lire() async throws -> CookiesBackup {
        let cible = try url(chemin: "api/cookies")
        let donnees = try await reponse(try requete(cible, methode: "GET"))
        do {
            return try JSONDecoder().decode(CookiesBackup.self, from: donnees)
        } catch {
            throw APIError.decoding(error)
        }
    }

    public func ecrire(sites: [String: [CookieRecord]]) async throws {
        let cible = try url(chemin: "api/cookies")
        let corps = try JSONEncoder().encode(CookiesPayload(sites: sites))
        _ = try await reponse(try requete(cible, methode: "PUT", corps: corps))
    }

    public func supprimer() async throws {
        let cible = try url(chemin: "api/cookies")
        _ = try await reponse(try requete(cible, methode: "DELETE"))
    }
}

/// Corps d'erreur du serveur : {"erreur": "..."}.
private struct ErreurServeur: Decodable {
    let erreur: String
}

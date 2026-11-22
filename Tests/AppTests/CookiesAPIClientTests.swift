import XCTest
@testable import RedditMediaPocket

/// Aucun réseau réel : URLProtocol intercepte les requêtes du client de sessions.
final class CookiesAPIClientTests: XCTestCase {
    private var client: CookiesAPIClient!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ProtocoleCookiesFaux.self)
        ProtocoleCookiesFaux.statut = 200
        ProtocoleCookiesFaux.corps = Data()
        ProtocoleCookiesFaux.derniereCle = nil
        ProtocoleCookiesFaux.derniereMethode = nil
        ProtocoleCookiesFaux.dernierCorps = nil
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [ProtocoleCookiesFaux.self]
        client = CookiesAPIClient(
            baseURL: URL(string: "https://worker-test.local/")!,
            session: URLSession(configuration: configuration),
            fournisseurCle: { "cle-de-test" }
        )
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ProtocoleCookiesFaux.self)
        client = nil
        super.tearDown()
    }

    func testLireEnvoieLaCleEtDecodeLesSites() async throws {
        ProtocoleCookiesFaux.corps = """
        {"sites":{"x":[{"name":"auth_token","value":"v","domain":"x.com","path":"/",\
        "expires":null,"secure":true,"httpOnly":true,"version":0}]},"updated_at":null}
        """.data(using: .utf8)!

        let sauvegarde = try await client.lire()

        XCTAssertEqual(ProtocoleCookiesFaux.derniereMethode, "GET")
        XCTAssertEqual(ProtocoleCookiesFaux.derniereCle, "cle-de-test")
        XCTAssertEqual(sauvegarde.sites["x"]?.first?.name, "auth_token")
    }

    func testEcrireEnvoieUnPUTAvecLesSites() async throws {
        ProtocoleCookiesFaux.corps = Data("{}".utf8)
        let cookie = CookieRecord(
            name: "sessionid", value: "v", domain: ".tiktok.com", path: "/"
        )

        try await client.ecrire(sites: ["tiktok": [cookie]])

        XCTAssertEqual(ProtocoleCookiesFaux.derniereMethode, "PUT")
        XCTAssertEqual(ProtocoleCookiesFaux.derniereCle, "cle-de-test")
        let corps = try XCTUnwrap(ProtocoleCookiesFaux.dernierCorps)
        let objet = try XCTUnwrap(JSONSerialization.jsonObject(with: corps) as? [String: Any])
        XCTAssertNotNil(objet["sites"])
    }

    func testSupprimerEnvoieUnDELETE() async throws {
        ProtocoleCookiesFaux.corps = Data(#"{"message":"Sessions effacées"}"#.utf8)

        try await client.supprimer()

        XCTAssertEqual(ProtocoleCookiesFaux.derniereMethode, "DELETE")
        XCTAssertEqual(ProtocoleCookiesFaux.derniereCle, "cle-de-test")
    }

    func testReponse401LeveUneErreur() async throws {
        ProtocoleCookiesFaux.statut = 401
        ProtocoleCookiesFaux.corps = Data(#"{"erreur":"Non autorisé"}"#.utf8)

        do {
            _ = try await client.lire()
            XCTFail("Une réponse 401 doit lever une erreur.")
        } catch APIError.httpError(let statut, let message) {
            XCTAssertEqual(statut, 401)
            XCTAssertEqual(message, "Non autorisé")
        }
    }
}

// MARK: - Faux transport

private final class ProtocoleCookiesFaux: URLProtocol {
    static var statut = 200
    static var corps = Data()
    static var derniereCle: String?
    static var derniereMethode: String?
    static var dernierCorps: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.derniereCle = request.value(forHTTPHeaderField: "X-API-Key")
        Self.derniereMethode = request.httpMethod
        Self.dernierCorps = request.httpBody
        guard let url = request.url else { return }
        let reponse = HTTPURLResponse(
            url: url,
            statusCode: Self.statut,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: reponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.corps)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

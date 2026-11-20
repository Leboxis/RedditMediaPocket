import XCTest
@testable import RedditMediaPocket

/// Les tests n'utilisent aucun réseau réel : URLProtocol intercepte les requêtes.
final class ItemsAPIClientTests: XCTestCase {
    private var client: ItemsAPIClient!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ProtocoleHTTPFaux.self)
        ProtocoleHTTPFaux.statut = 200
        ProtocoleHTTPFaux.corps = Data()
        ProtocoleHTTPFaux.derniereCle = nil
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [ProtocoleHTTPFaux.self]
        client = ItemsAPIClient(
            baseURL: URL(string: "https://worker-test.local/")!,
            session: URLSession(configuration: configuration),
            fournisseurCle: { "cle-de-test" }
        )
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ProtocoleHTTPFaux.self)
        client = nil
        super.tearDown()
    }

    /// (a) Une réponse 200 est décodée correctement, clé et en-têtes inclus.
    func testListeDecodeUneReponse200() async throws {
        ProtocoleHTTPFaux.corps = """
        {
          "page": 1,
          "limit": 20,
          "total": 1,
          "pages": 1,
          "items": [
            {
              "id": 1,
              "name": "u/alice",
              "description": null,
              "type": "collection",
              "data": {"is_subreddit": false, "archived": false},
              "created_at": "2026-11-20 22:00:00",
              "updated_at": null
            }
          ]
        }
        """.data(using: .utf8)!

        let page = try await client.list()

        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.id, 1)
        XCTAssertEqual(page.items.first?.name, "u/alice")
        XCTAssertEqual(page.items.first?.type, "collection")
        // datetime('now') n'est pas du ISO-8601 : la date reste une String brute.
        XCTAssertEqual(page.items.first?.createdAt, "2026-11-20 22:00:00")
        XCTAssertEqual(ProtocoleHTTPFaux.derniereCle, "cle-de-test")
    }

    /// (b) Une réponse 401 lève une erreur HTTP avec le message du serveur.
    func testReponse401LeveUneErreur() async throws {
        ProtocoleHTTPFaux.statut = 401
        ProtocoleHTTPFaux.corps = #"{"erreur":"Non autorisé"}"#.data(using: .utf8)!

        do {
            _ = try await client.list()
            XCTFail("Une réponse 401 doit lever une erreur.")
        } catch APIError.httpError(let statut, let message) {
            XCTAssertEqual(statut, 401)
            XCTAssertEqual(message, "Non autorisé")
        }
    }
}

// MARK: - Faux transport

private final class ProtocoleHTTPFaux: URLProtocol {
    static var statut = 200
    static var corps = Data()
    static var derniereCle: String?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.derniereCle = request.value(forHTTPHeaderField: "X-API-Key")
        let statut = Self.statut
        let corps = Self.corps
        guard let url = request.url else { return }
        let reponse = HTTPURLResponse(
            url: url,
            statusCode: statut,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: reponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: corps)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

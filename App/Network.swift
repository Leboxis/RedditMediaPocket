import Foundation

enum NetworkError: LocalizedError {
    case refused(Int), limited(Date), invalid(String)
    var errorDescription: String? {
        switch self {
        case .refused(let code): return "Accès refusé (HTTP \(code)). Aucun contournement ni nouvelle tentative automatique."
        case .limited(let date): return "Limite atteinte. Réessayez après \(date.formatted())."
        case .invalid(let message): return message
        }
    }
}

// Media starts immediately; only public RSS discovery is paced. No automatic retries.
@MainActor final class Network {
    private let session: URLSession
    private var nextRSSRequest = Date.distantPast
    private var cooldown: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "cooldown")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "cooldown") }
    }
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config)
    }
    private func request(_ url: URL, bearer: String?) async throws -> URLRequest {
        guard url.scheme == "https" else { throw NetworkError.invalid("Seuls les liens HTTPS sont acceptés.") }
        if cooldown > Date() { throw NetworkError.limited(cooldown) }
        if url.host == "www.reddit.com" {
            let reserved = max(Date(), nextRSSRequest)
            nextRSSRequest = reserved.addingTimeInterval(7)
            let delay = reserved.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        try Task.checkCancellation()
        if cooldown > Date() { throw NetworkError.limited(cooldown) }
        var request = URLRequest(url: url)
        request.setValue("RedditMediaPocket/0.1 (iOS; anonymous RSS reader)", forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalid("Réponse réseau invalide.") }
        if http.statusCode == 429 {
            let header = http.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            cooldown = max(Date().addingTimeInterval(60), Double(header).map { Date().addingTimeInterval($0) } ?? formatter.date(from: header) ?? Date().addingTimeInterval(900))
            throw NetworkError.limited(cooldown)
        }
        guard (200...299).contains(http.statusCode) else { throw NetworkError.refused(http.statusCode) }
    }
    func data(_ url: URL, bearer: String? = nil) async throws -> Data {
        let req = try await request(url, bearer: bearer)
        let (data, response) = try await session.data(for: req)
        try check(response)
        return data
    }
    func download(_ url: URL) async throws -> URL {
        let req = try await request(url, bearer: nil)
        let (temp, response) = try await session.download(for: req)
        do {
            try check(response)
            let mime = response.mimeType ?? ""
            guard mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/octet-stream" else {
                throw NetworkError.invalid("Le serveur n’a pas renvoyé un média (\(mime)).")
            }
            let persistent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
            try FileManager.default.moveItem(at: temp, to: persistent)
            return persistent
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
}

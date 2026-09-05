import Foundation
import MediaCore

enum NetworkError: LocalizedError {
    case refused(Int), limited(service: String, until: Date), invalid(String)
    var errorDescription: String? {
        switch self {
        case .refused(let code): return "Accès refusé (HTTP \(code)). Aucun contournement ni nouvelle tentative automatique."
        case .limited(let service, let date): return "\(service) · réessayer le \(date.formatted(date: .numeric, time: .shortened))"
        case .invalid(let message): return message
        }
    }
}

// Three concurrent media pipelines; service-specific pacing and persistent limits.
@MainActor final class Network {
    private let session: URLSession
    private var nextRequest: [String: Date] = [:]
    private var limits: ServiceLimits
    private let defaults = UserDefaults.standard

    private func checkLimit(_ service: String) throws {
        // Older versions did not record the source. Honor that existing deadline once.
        let legacy = Date(timeIntervalSince1970: defaults.double(forKey: "cooldown"))
        if legacy > Date() { throw NetworkError.limited(service: "Ancienne limite", until: legacy) }
        if let date = limits.blockedUntil(service: service, now: Date()) {
            throw NetworkError.limited(service: service, until: date)
        }
    }
    init() {
        let stored = UserDefaults.standard.dictionary(forKey: "serviceCooldowns") as? [String: Double] ?? [:]
        limits = ServiceLimits(deadlines: stored.mapValues { Date(timeIntervalSince1970: $0) })
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
        let service = RatePolicy.service(for: url.host ?? "Serveur")
        try checkLimit(service)
        // Space starts, not whole transfers: up to three large files still overlap.
        let interval: TimeInterval = url.host == "www.reddit.com" ? 7 : (url.host == "api.redgifs.com" ? 2 : 1)
        let reserved = max(Date(), nextRequest[service] ?? .distantPast)
        nextRequest[service] = reserved.addingTimeInterval(interval)
        let delay = reserved.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        try checkLimit(service)
        var request = URLRequest(url: url)
        request.setValue("RedditMediaPocket/0.1 (iOS; anonymous RSS reader)", forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func check(_ response: URLResponse, requestedURL: URL) throws {
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalid("Réponse réseau invalide.") }
        if http.statusCode == 429 {
            let service = RatePolicy.service(for: requestedURL.host ?? "Serveur")
            let date = RatePolicy.retryDate(header: http.value(forHTTPHeaderField: "Retry-After"), now: Date())
            limits.record(service: service, until: date)
            defaults.set(limits.deadlines.mapValues { $0.timeIntervalSince1970 }, forKey: "serviceCooldowns")
            throw NetworkError.limited(service: service, until: limits.deadlines[service] ?? date)
        }
        guard (200...299).contains(http.statusCode) else { throw NetworkError.refused(http.statusCode) }
    }
    func data(_ url: URL, bearer: String? = nil) async throws -> Data {
        let req = try await request(url, bearer: bearer)
        let (data, response) = try await session.data(for: req)
        try check(response, requestedURL: url)
        return data
    }
    func download(_ url: URL) async throws -> URL {
        let req = try await request(url, bearer: nil)
        let (temp, response) = try await session.download(for: req)
        do {
            try check(response, requestedURL: url)
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

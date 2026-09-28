import Foundation
import Combine
import MediaCore

// Configurable bounded media pipelines; server-stated service limits only.
@MainActor final class Network: ObservableObject {
    @Published private(set) var transfers = 0
    private let session: URLSession
    private var sessionRevision = -1
    private var requestGeneration = 0
    private var limits: ServiceLimits
    private var rssCache: [URL: (date: Date, data: Data)] = [:]
    private let defaults = UserDefaults.standard

    private func checkLimit(_ service: String) throws {
        // Older versions did not record the source. Honor that existing deadline once.
        let legacy = Date(timeIntervalSince1970: defaults.double(forKey: "cooldown"))
        if legacy > Date() { throw NetworkError.limited(service: "Ancienne limite", until: legacy) }
        if let date = limits.blockedUntil(service: service, now: Date()) {
            throw NetworkError.limited(service: service, until: date)
        }
    }
    /// Relance manuelle : oublie les pauses enregistrées (mémoire +
    /// UserDefaults) pour retenter vraiment le serveur.
    func resetRateLimits() {
        requestGeneration += 1
        limits = ServiceLimits()
        rssCache.removeAll()
        defaults.removeObject(forKey: "serviceCooldowns")
        defaults.removeObject(forKey: "cooldown")
    }
    init() {
        let stored = UserDefaults.standard.dictionary(forKey: "serviceCooldowns") as? [String: Double] ?? [:]
        limits = ServiceLimits(deadlines: stored.mapValues { Date(timeIntervalSince1970: $0) })
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config, delegate: SafeRedirects(), delegateQueue: nil)
    }
    private func request(_ url: URL, bearer: String?, headers: [String: String]? = nil) async throws -> URLRequest {
        guard url.scheme == "https" else { throw NetworkError.invalid(L("Seuls les liens HTTPS sont acceptés.", "Only HTTPS links are accepted.")) }
        let service = RatePolicy.service(for: url.host ?? "Serveur")
        try checkLimit(service)
        // No application-imposed delay: free workers start requests immediately.
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("RedditMediaPocket/0.1 (iOS; RSS reader)", forHTTPHeaderField: "User-Agent")
        if let cookie = await RedditSession.shared.cookieHeader(for: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        try Task.checkCancellation()
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let headers {
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }
    private func check(_ response: URLResponse, requestedURL: URL) throws {
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalid(L("Réponse réseau invalide.", "Invalid network response.")) }
        // Only an explicit refusal stops a run. A quota header on a successful
        // response is never enough on its own: it would stop downloads without
        // any request having been refused.
        guard (200...299).contains(http.statusCode) else {
            guard http.statusCode == 429 else {
                LogCenter.err("GET \(LogDiagnostics.requestSummary(requestedURL)) → \(LogDiagnostics.requestSummary(http.url ?? requestedURL)) : HTTP \(http.statusCode).")
                throw NetworkError.refused(http.statusCode)
            }
            let service = RatePolicy.service(for: requestedURL.host ?? "Serveur")
            // Reddit omits `Retry-After` here and advertises `x-ratelimit-reset`
            // instead. With neither, nothing is recorded and the next start is free.
            let date = RatePolicy.retryDate(retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                            reset: http.value(forHTTPHeaderField: "X-Ratelimit-Reset"),
                                            now: Date())
            if let date {
                limits.record(service: service, until: date)
                defaults.set(limits.deadlines.mapValues { $0.timeIntervalSince1970 }, forKey: "serviceCooldowns")
            }
            LogCenter.err(L("GET \(LogDiagnostics.requestSummary(requestedURL)) : \(service), HTTP 429, reprise \(date.map { $0.formatted() } ?? "non indiquée").", "GET \(LogDiagnostics.requestSummary(requestedURL)): \(service), HTTP 429, retry \(date.map { $0.formatted() } ?? "not specified")."))
            throw NetworkError.limited(service: service, until: date)
        }
    }
    func data(_ url: URL, bearer: String? = nil, headers: [String: String]? = nil) async throws -> Data {
        let generation = requestGeneration
        let revision = RedditSession.shared.revision
        if revision != sessionRevision { rssCache.removeAll(); sessionRevision = revision }
        let isRSS = url.host == "www.reddit.com" && url.path.hasSuffix(".rss") && !SavedFeed.containsCredential(url)
        if isRSS, let cached = rssCache[url], Date().timeIntervalSince(cached.date) < 120 {
            LogCenter.net(L("Page déjà en mémoire (\(cached.data.count / 1024) Ko), pas de nouvel appel.", "Page already in memory (\(cached.data.count / 1024) KB), no new call."))
            return cached.data
        }
        let req = try await request(url, bearer: bearer, headers: headers)
        guard generation == requestGeneration else { throw CancellationError() }
        let started = Date()
        LogCenter.net("GET \(LogDiagnostics.requestSummary(url))…")
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            if !Task.isCancelled {
                let code = (error as? URLError).map { "URLSession \($0.code.rawValue)" } ?? String(describing: type(of: error))
                LogCenter.err(L("GET \(LogDiagnostics.requestSummary(url)) : \(code) après \(String(format: "%.1f", Date().timeIntervalSince(started))) s.", "GET \(LogDiagnostics.requestSummary(url)): \(code) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s."))
            }
            throw error
        }
        let (data, response) = result
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let http = response as? HTTPURLResponse
        LogCenter.net(L("Réponse \(http?.statusCode ?? 0) de \(LogDiagnostics.requestSummary(response.url ?? url)) : \(data.count) octets, \(response.mimeType ?? "type inconnu"), \(String(format: "%.1f", Date().timeIntervalSince(started))) s.", "Response \(http?.statusCode ?? 0) from \(LogDiagnostics.requestSummary(response.url ?? url)): \(data.count) bytes, \(response.mimeType ?? "unknown type"), \(String(format: "%.1f", Date().timeIntervalSince(started))) s."))
        try check(response, requestedURL: url)
        if isRSS, data.count <= 2_000_000 {
            // Reuse successful pages within a run; manual restart clears them.
            if rssCache.count >= 16, let oldest = rssCache.min(by: { $0.value.date < $1.value.date })?.key { rssCache.removeValue(forKey: oldest) }
            rssCache[url] = (Date(), data)
        }
        return data
    }

    func savedFeed(username: String? = nil) async throws -> SavedFeed {
        LogCenter.net(L("Lecture du lien privé des sauvegardés…", "Reading private saved feed link…"))
        await RedditSession.shared.refresh()
        guard RedditSession.shared.hasSession else { throw FeedError.loginRequired }
        do {
            let html = try await data(URL(string: "https://old.reddit.com/prefs/feeds/")!)
            try Task.checkCancellation()
            let feed = try SavedFeed(preferencesHTML: String(decoding: html, as: UTF8.self), username: username)
            LogCenter.net(L("Flux sauvegardés trouvé : \(LogDiagnostics.requestSummary(feed.pageURL())).", "Saved feed found: \(LogDiagnostics.requestSummary(feed.pageURL()))."))
            return feed
        } catch NetworkError.refused(let code) where code == 401 || code == 403 {
            throw NetworkError.invalid(L("Reddit refuse l’accès aux flux RSS privés (HTTP \(code)).", "Reddit denied access to private RSS feeds (HTTP \(code))."))
        }
    }

    func savedPosts(_ feed: SavedFeed, after: String?) async throws -> [Post] {
        do {
            let body = try await data(feed.pageURL(after: after))
            try Task.checkCancellation()
            return try FeedParser.parse(body)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if case NetworkError.limited = error { throw error }
            if case NetworkError.refused(let code) = error {
                if (300...399).contains(code) {
                    throw NetworkError.invalid(L("Redirection du flux privé refusée : destination incompatible (HTTP \(code)).", "Private feed redirect refused: incompatible destination (HTTP \(code))."))
                }
                throw NetworkError.invalid(L("Flux privé des sauvegardés refusé par Reddit (HTTP \(code)).", "Reddit denied access to the private saved feed (HTTP \(code))."))
            }
            // URLSession errors can contain the private URL: never expose its token.
            throw NetworkError.invalid(L("Impossible de lire le flux RSS privé des sauvegardés.", "Unable to read the private saved RSS feed."))
        }
    }
    func download(_ url: URL, headers: [String: String]? = nil) async throws -> URL {
        let generation = requestGeneration
        let req = try await request(url, bearer: nil, headers: headers)
        guard generation == requestGeneration else { throw CancellationError() }
        transfers += 1
        defer { transfers -= 1 }
        let started = Date()
        LogCenter.net(L("Média GET \(LogDiagnostics.requestSummary(url))…", "Media GET \(LogDiagnostics.requestSummary(url))…"))
        let result: (URL, URLResponse)
        do {
            result = try await session.download(for: req)
        } catch {
            if !Task.isCancelled {
                let code = (error as? URLError).map { "URLSession \($0.code.rawValue)" } ?? String(describing: type(of: error))
                LogCenter.err(L("Média \(LogDiagnostics.requestSummary(url)) : \(code) après \(String(format: "%.1f", Date().timeIntervalSince(started))) s.", "Media \(LogDiagnostics.requestSummary(url)): \(code) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s."))
            }
            throw error
        }
        let (temp, response) = result
        do {
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            guard response.url?.scheme == "https" else { throw NetworkError.invalid(L("Redirection non HTTPS refusée.", "Non-HTTPS redirect refused.")) }
            try check(response, requestedURL: url)
            let mime = response.mimeType ?? ""
            guard mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/octet-stream" else {
                throw NetworkError.invalid(L("Le serveur n’a pas renvoyé un média (\(mime)).", "The server did not return media (\(mime))."))
            }
            let persistent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
            try FileManager.default.moveItem(at: temp, to: persistent)
            let sizeKB = (try? persistent.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 / 1024 } ?? 0
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            LogCenter.net(L("Reçu : \(LogDiagnostics.requestSummary(response.url ?? url)) (HTTP \(code), \(mime), \(sizeKB) Ko, \(String(format: "%.1f", Date().timeIntervalSince(started))) s).", "Received: \(LogDiagnostics.requestSummary(response.url ?? url)) (HTTP \(code), \(mime), \(sizeKB) KB, \(String(format: "%.1f", Date().timeIntervalSince(started))) s)."))
            return persistent
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
}

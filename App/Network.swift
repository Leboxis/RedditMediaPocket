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
    private var legacyCooldownDate: Date
    private var rssCache: [URL: (date: Date, data: Data)] = [:]
    private let defaults = UserDefaults.standard

    private func checkLimit(_ service: String) throws {
        // Older versions did not record the source. Honor that existing deadline once.
        if legacyCooldownDate > Date() { throw NetworkError.limited(service: "Ancienne limite", until: legacyCooldownDate) }
        if let date = limits.blockedUntil(service: service, now: Date()) {
            throw NetworkError.limited(service: service, until: date)
        }
    }
    /// Relance manuelle : oublie les pauses enregistrées (mémoire +
    /// UserDefaults) pour retenter vraiment le serveur.
    func resetRateLimits() {
        requestGeneration += 1
        limits = ServiceLimits()
        legacyCooldownDate = .distantPast
        rssCache.removeAll()
        defaults.removeObject(forKey: "serviceCooldowns")
        defaults.removeObject(forKey: "cooldown")
    }
    init() {
        let stored = UserDefaults.standard.dictionary(forKey: "serviceCooldowns") as? [String: Double] ?? [:]
        limits = ServiceLimits(deadlines: stored.mapValues { Date(timeIntervalSince1970: $0) })
        let legacySeconds = UserDefaults.standard.double(forKey: "cooldown")
        legacyCooldownDate = legacySeconds > 0 ? Date(timeIntervalSince1970: legacySeconds) : .distantPast
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Requête plus courte : une connexion morte libère son créneau au
        // bout de 30 s au lieu d'une minute, et le retry la reprend.
        config.timeoutIntervalForRequest = TimingPolicy.networkRequest
        // Filet de sécurité du watchdog : un transfert qui s'égoutte sans
        // jamais se bloquer franchit rarement 10 minutes utiles.
        config.timeoutIntervalForResource = TimingPolicy.networkResource
        config.httpMaximumConnectionsPerHost = ConcurrentDownloads.maximumLimit
        session = URLSession(configuration: config, delegate: SafeRedirects(), delegateQueue: nil)
    }
    private func request(_ url: URL, bearer: String?, headers: [String: String]? = nil,
                         body: Data? = nil) async throws -> URLRequest {
        guard url.scheme == "https" else { throw NetworkError.invalid(L("Seuls les liens HTTPS sont acceptés.", "Only HTTPS links are accepted.")) }
        let service = RatePolicy.service(for: url.host ?? "Serveur")
        try checkLimit(service)
        // No application-imposed delay: free workers start requests immediately.
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if XFetishAPI.isXFetish(url) {
            // Le stockage refuse l'UA applicatif (HTTP 403 même avec token +
            // Referer) : UA Safari iPhone identique pour galerie et médias,
            // sinon le jeton lié à l'UA serait invalidé.
            request.setValue(XFetishAPI.userAgent, forHTTPHeaderField: "User-Agent")
        } else {
            // Reddit bloque les UA applicatifs sur ses pages `.json`
            // (HTTP 403 « blocked by network security ») : UA Safari iPhone.
            request.setValue(XFetishAPI.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if XFetishAPI.isXFetish(url) {
            // Anti-hotlink `storage*.x-fetish.tube/remote_control.php` (HTTP 403
            // sans Referer) : valeurs par défaut navigateur, surchargeables par
            // `headers` (ex. Referer = page album d'origine).
            let defaults = XFetishAPI.headers()
            let provided = Set((headers ?? [:]).keys.map { $0.lowercased() })
            for (field, value) in defaults where !provided.contains(field.lowercased()) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        // Reddit : `/user/<pseudo>/submitted.json` passe avec UA + Cookie, mais
        // `/r/<sub>/<tri>.json` répond « blocked by network security » (403)
        // sans les en-têtes d'un `fetch` du site. `headers` fourni par l'appelant
        // garde la priorité (ajouté plus bas).
        let provided = Set((headers ?? [:]).keys.map { $0.lowercased() })
        for (field, value) in RedditListingHeaders.forListing(url) where !provided.contains(field.lowercased()) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let cookie = await RedditSession.shared.cookieHeader(for: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        // La session X est distincte de la Reddit : `RedditCookiePolicy` refuse
        // x.com, il faut donc demander son en-tête à `XSession`. Les deux
        // politiques sont filtrées par hôte, aucune ne peut envoyer les
        // identifiants de l'autre service ni les transmettre au CDN média.
        if let cookie = await XSession.shared.cookieHeader(for: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        // La session TikTok est elle aussi distincte : `TikTokCookiePolicy`
        // refuse reddit.com et x.com, il faut donc demander son en-tête à
        // `TikTokSession`. Aucune politique ne peut envoyer les identifiants
        // d'un autre service ni les transmettre au CDN de médias.
        if let cookie = await TikTokSession.shared.cookieHeader(for: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        try Task.checkCancellation()
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let headers {
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        // Appels POST (site Instagram `api/graphql`) : le corps est déjà
        // encodé en formulaire, l'en-tête reste surchargeable via `headers`.
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
    func data(_ url: URL, bearer: String? = nil, headers: [String: String]? = nil,
              body: Data? = nil) async throws -> Data {
        (try await fetch(url, bearer: bearer, headers: headers, body: body, includeHeaders: false)).data
    }

    /// Comme `data`, en rendant aussi les en-têtes de la réponse : Instagram ne
    /// livre son jeton `csrf` que par `Set-Cookie`, plus dans le HTML.
    func dataAndHeaders(_ url: URL, headers: [String: String]? = nil) async throws -> (data: Data, headers: [String: String]) {
        try await fetch(url, bearer: nil, headers: headers, body: nil, includeHeaders: true)
    }

    private func fetch(_ url: URL, bearer: String?, headers: [String: String]?,
                       body: Data?, includeHeaders: Bool) async throws -> (data: Data, headers: [String: String]) {
        do {
            return try await fetchOnce(url, bearer: bearer, headers: headers, body: body, includeHeaders: includeHeaders)
        } catch NetworkError.refused(let code) where code == 404 || code == 403 {
            // Deux refus Reddit sont connus ici : le 404 des flux `.rss`
            // coupés depuis le 13/11/2026, et le 403 « blocked by network
            // security » que `www.reddit.com` renvoie sur les listings JSON
            // de subreddit (`/r/<sub>/<tri>.json`) alors que les listings
            // d'utilisateur passent. Dans les deux cas, une seule nouvelle
            // tentative est faite sur `old.reddit.com` (qui ne boucle pas).
            guard let fallback = RedditFeedHosts.fallback(from: url, status: code) else {
                if let data = await redditBrowserFallback(url) { return (data, [:]) }
                throw NetworkError.refused(code)
            }
            LogCenter.info(L("Listing Reddit refusé (HTTP \(code)) sur \(LogDiagnostics.requestSummary(url)) — nouvel essai sur \(LogDiagnostics.requestSummary(fallback)).",
                             "Reddit listing refused (HTTP \(code)) on \(LogDiagnostics.requestSummary(url)) — retrying on \(LogDiagnostics.requestSummary(fallback))."))
            do {
                let result = try await fetchOnce(fallback, bearer: bearer, headers: headers, body: body, includeHeaders: includeHeaders)
                LogCenter.info(L("Repli \(fallback.host ?? "") : listing servi (\(result.data.count) octets).",
                                 "Fallback \(fallback.host ?? ""): listing served (\(result.data.count) bytes)."))
                return result
            } catch {
                LogCenter.err(L("Repli \(fallback.host ?? "") refusé : \(error.localizedDescription)",
                                "Fallback \(fallback.host ?? "") refused: \(error.localizedDescription)"))
                if let data = await redditBrowserFallback(url) { return (data, [:]) }
                throw NetworkError.refused(code)
            }
        }
    }

    /// Dernier recours des listings `/r/<sub>/<tri>.json` : ni `www`, ni
    /// `old.reddit.com` ne les servent à `URLSession`, même avec la session.
    /// Un `fetch` depuis une WKWebView connectée au store Reddit porte
    /// l'empreinte du navigateur et doit passer là où HTTP échoue.
    private func redditBrowserFallback(_ url: URL) async -> Data? {
        guard RedditListingHeaders.isSubredditListing(url) else { return nil }
        let segments = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        guard segments.count >= 2 else { return nil }
        LogCenter.info(L("Subreddit : essai depuis le navigateur intégré (session Reddit)…",
                         "Subreddit: retrying from the embedded browser (Reddit session)…"))
        let fetcher = RedditWebFetcher()
        guard await fetcher.start(subreddit: segments[1]) else {
            LogCenter.err(L("Subreddit : page du subreddit non chargée dans le navigateur intégré.",
                            "Subreddit: subreddit page did not load in the embedded browser."))
            fetcher.close()
            return nil
        }
        defer { fetcher.close() }
        guard let response = await fetcher.fetch(url) else {
            LogCenter.err(L("Subreddit : le navigateur intégré n'a pas répondu.",
                            "Subreddit: embedded browser did not answer."))
            return nil
        }
        guard response.status == 200, !response.body.isEmpty,
              let data = response.body.data(using: .utf8) else {
            LogCenter.err(L("Subreddit : navigateur intégré → HTTP \(response.status), \(response.body.count) octets.",
                            "Subreddit: embedded browser → HTTP \(response.status), \(response.body.count) bytes."))
            return nil
        }
        LogCenter.info(L("Subreddit : listing servi par le navigateur intégré (\(data.count) octets).",
                         "Subreddit: listing served by the embedded browser (\(data.count) bytes)."))
        return data
    }

    private func fetchOnce(_ url: URL, bearer: String?, headers: [String: String]?,
                           body: Data?, includeHeaders: Bool) async throws -> (data: Data, headers: [String: String]) {
        let generation = requestGeneration
        let revision = RedditSession.shared.revision
        if revision != sessionRevision { rssCache.removeAll(); sessionRevision = revision }
        // Le cache couvre les deux hôtes de flux Reddit : le repli
        // `old.reddit.com` sert le même contenu et mérite la même économie de
        // requêtes, sinon chaque page repartirait sur le repli.
        let feedHost = url.host?.lowercased()
        let isListing = (feedHost == "www.reddit.com" || feedHost == "old.reddit.com")
            && (url.path.hasSuffix(".rss") || url.path.hasSuffix(".json")) && !SavedFeed.containsCredential(url)
        if isListing, let cached = rssCache[url], Date().timeIntervalSince(cached.date) < 120 {
            LogCenter.net(L("Page déjà en mémoire (\(cached.data.count / 1024) Ko), pas de nouvel appel.", "Page already in memory (\(cached.data.count / 1024) KB), no new call."))
            return (cached.data, [:])
        }
        // Album and video pages hand out signed get_image / get_file routes.
        let isXFetishSite = url.host?.lowercased() == "x-fetish.tube"
        let isXFetishVideoPage = isXFetishSite && url.path.hasPrefix("/video/")
        let isXFetishSignedPage = isXFetishVideoPage || (isXFetishSite && url.path.hasPrefix("/albums/"))
        var effectiveHeaders = headers ?? [:]
        if isXFetishVideoPage { effectiveHeaders["Accept"] = XFetishAPI.videoAccept }
        let req = try await request(url, bearer: bearer, headers: effectiveHeaders, body: body)
        guard generation == requestGeneration else { throw CancellationError() }
        let started = Date()
        LogCenter.net("\(body == nil ? "GET" : "POST") \(LogDiagnostics.requestSummary(url))…")
        let result: (Data, URLResponse)
        do {
            if isXFetishSignedPage {
                // Fetching them over IPv4 keeps their source address consistent
                // with the signed route and the IPv4-only storage host.
                LogCenter.net("X-Fetish : page en IPv4…")
                let (body, response) = try await XFetishIPv4Pages.data(for: url,
                    headers: req.allHTTPHeaderFields ?? [:])
                result = (body, response)
            } else {
                result = try await session.data(for: req)
            }
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
        if isListing, data.count <= 2_000_000 {
            // Reuse successful pages within a run; manual restart clears them.
            if rssCache.count >= 16, let oldest = rssCache.min(by: { $0.value.date < $1.value.date })?.key { rssCache.removeValue(forKey: oldest) }
            rssCache[url] = (Date(), data)
        }
        var fields: [String: String] = [:]
        if includeHeaders {
            for (key, value) in http?.allHeaderFields ?? [:] {
                fields[String(describing: key).lowercased()] = String(describing: value)
            }
        }
        return (data, fields)
    }

    func savedFeed(username: String? = nil) async throws -> SavedFeed {
        LogCenter.net(L("Lecture du lien privé des sauvegardés…", "Reading private saved feed link…"))
        await RedditSession.shared.refresh()
        guard RedditSession.shared.hasSession else { throw FeedError.loginRequired }
        do {
            let html = try await data(URL(string: "https://old.reddit.com/prefs/feeds/")!)
            try Task.checkCancellation()
            let feed = try SavedFeed(preferencesHTML: String(decoding: html, as: UTF8.self), username: username)
            LogCenter.net(L("Compte détecté dans prefs/feeds : \(feed.username) (les flux RSS privés sont coupés depuis le 13/11/2026).", "Account detected in prefs/feeds: \(feed.username) (private RSS feeds have been off since 11/13/2026)."))
            return feed
        } catch NetworkError.refused(let code) where code == 401 || code == 403 {
            throw NetworkError.invalid(L("Reddit refuse l’accès à prefs/feeds (HTTP \(code)).", "Reddit denied access to prefs/feeds (HTTP \(code))."))
        }
    }

    /// Posts sauvegardés du compte connecté via le listing JSON
    /// `www.reddit.com/user/<pseudo>/saved.json` (les flux `.rss` privés sont
    /// coupés depuis le 13/11/2026). Nécessite la session Reddit.
    func savedPosts(_ feed: SavedFeed, after: String?) async throws -> [Post] {
        var components = URLComponents(string: "https://www.reddit.com/user/\(feed.username)/saved.json")!
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "100")]
        if let after { items.append(URLQueryItem(name: "after", value: after)) }
        components.queryItems = items
        guard let url = components.url else {
            throw NetworkError.invalid(L("Adresse des sauvegardés invalide.", "Invalid saved-posts address."))
        }
        do {
            let body = try await data(url)
            try Task.checkCancellation()
            return try RedditListing.parse(body)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if case NetworkError.limited = error { throw error }
            if case NetworkError.refused(let code) = error {
                if (300...399).contains(code) {
                    throw NetworkError.invalid(L("Redirection des sauvegardés refusée : destination incompatible (HTTP \(code)).", "Saved-posts redirect refused: incompatible destination (HTTP \(code))."))
                }
                throw NetworkError.invalid(L("Listing des sauvegardés refusé par Reddit (HTTP \(code)) : session requise depuis le 13/11/2026.", "Reddit refused the saved listing (HTTP \(code)): a session is required since 11/13/2026."))
            }
            throw NetworkError.invalid(L("Impossible de lire les sauvegardés.", "Unable to read saved posts."))
        }
    }

    func download(_ url: URL, headers: [String: String]? = nil) async throws -> URL {
        // X-Fetish `get_image` / `get_file` : forçage IPv4 (le stockage est
        // IPv4-only, le token est lié à l'IP ; en IPv6 le 403 est systématique).
        if XFetishIPv4.isSignedMediaRoute(url) {
            // Seul l'échec de l'échange contre l'URL de stockage justifie un
            // repli. Le transfert du média est volontairement hors de ce `do` :
            // une annulation ou un refus y survenant ne doit jamais être
            // rapporté comme une indisponibilité IPv4, ni renvoyer la route
            // signée en IPv6 alors que son jeton est lié à l'adresse IPv4.
            let storage: URL?
            do {
                let referer = headers?.first(where: { $0.key.lowercased() == "referer" })?.value
                    ?? "https://x-fetish.tube/"
                storage = try await XFetishIPv4.storageURL(for: url, userAgent: XFetishAPI.userAgent, referer: referer)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                LogCenter.err(L("IPv4 X-Fetish indisponible, repli URLSession : \(error.localizedDescription).", "X-Fetish IPv4 unavailable, URLSession fallback: \(error.localizedDescription)."))
                storage = nil
            }
            if let storage {
                LogCenter.net(L("IPv4 : \(LogDiagnostics.requestSummary(url)) → \(LogDiagnostics.requestSummary(storage)).", "IPv4: \(LogDiagnostics.requestSummary(url)) → \(LogDiagnostics.requestSummary(storage))."))
                return try await download(storage, headers: headers)
            }
        }
        let generation = requestGeneration
        let req = try await request(url, bearer: nil, headers: headers)
        guard generation == requestGeneration else { throw CancellationError() }
        transfers += 1
        defer { transfers -= 1 }
        let started = Date()
        LogCenter.net(L("Média GET \(LogDiagnostics.requestSummary(url))…", "Media GET \(LogDiagnostics.requestSummary(url))…"))
        let watchdog = StallWatchdog()
        watchdog.start()
        let result: (URL, URLResponse)
        do {
            result = try await session.download(for: req, delegate: watchdog)
        } catch {
            watchdog.stop()
            // Un transfert annulé par le watchdog est un égouttement réseau,
            // pas une annulation utilisateur : le convertir en erreur
            // transient pour que `RetryPolicy` le reprenne au lieu d'abandonner.
            if watchdog.stalled, (error as? URLError)?.code == .cancelled {
                throw URLError(.timedOut)
            }
            if !Task.isCancelled {
                let code = (error as? URLError).map { "URLSession \($0.code.rawValue)" } ?? String(describing: type(of: error))
                LogCenter.err(L("Média \(LogDiagnostics.requestSummary(url)) : \(code) après \(String(format: "%.1f", Date().timeIntervalSince(started))) s.", "Media \(LogDiagnostics.requestSummary(url)): \(code) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s."))
            }
            throw error
        }
        watchdog.stop()
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
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let (persistent, sizeKB) = try await Task.detached(priority: .userInitiated) { () -> (URL, Int) in
                let persistent = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                try FileManager.default.moveItem(at: temp, to: persistent)
                let sizeKB = (try? persistent.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 / 1024 } ?? 0
                return (persistent, sizeKB)
            }.value
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            LogCenter.net(L("Reçu : \(LogDiagnostics.requestSummary(response.url ?? url)) (HTTP \(code), \(mime), \(sizeKB) Ko, \(String(format: "%.1f", Date().timeIntervalSince(started))) s).", "Received: \(LogDiagnostics.requestSummary(response.url ?? url)) (HTTP \(code), \(mime), \(sizeKB) KB, \(String(format: "%.1f", Date().timeIntervalSince(started))) s)."))
            return persistent
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }

    /// Signed video pages and get_file use IPv4; their storage host is IPv4-only.
    /// Never retry the signed route through the default, potentially IPv6 session.
    func downloadXFetishVideo(_ url: URL, segments: Int, headers: [String: String],
                              progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard XFetishIPv4.isSignedMediaRoute(url), url.path.hasPrefix("/get_file/") else {
            throw XFetishVideoError.invalidPlayer
        }
        let generation = requestGeneration
        _ = try await request(url, bearer: nil, headers: headers)
        transfers += 1
        defer { transfers -= 1 }
        let storage: URL
        do {
            storage = try await XFetishIPv4.storageURL(for: url, userAgent: XFetishAPI.userAgent,
                referer: headers["Referer"] ?? "https://x-fetish.tube/")
        } catch XFetishIPv4Error.unexpectedStatus(let code) {
            if code == 429 { throw NetworkError.limited(service: "X-Fetish", until: nil) }
            throw NetworkError.refused(code)
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        guard XFetishRangeDownload.allowsStorage(storage) else {
            // Comportement historique : un hôte inattendu mais même opérateur
            // reste téléchargé en connexion unique au lieu d'être rejeté.
            LogCenter.net(L("Vidéo X-Fetish : hôte inattendu, repli connexion unique.", "X-Fetish video: unexpected host, single-connection fallback."))
            return try await download(storage, headers: headers)
        }
        let req = try await request(storage, bearer: nil, headers: headers)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        LogCenter.net(L("Vidéo X-Fetish : jusqu’à \(segments) morceaux HTTP.", "X-Fetish video: up to \(segments) HTTP ranges."))
        do {
            try await XFetishRangeDownload.download(req, to: output, segments: segments, progress: progress)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            if case XFetishRangeDownload.Failure.http(let response) = error {
                try check(response, requestedURL: storage)
            }
            throw error
        }
    }
}

/// Détecte un transfert à l'arrêt : sans octet reçu pendant `interval`, la
/// tâche URLSession est annulée pour libérer son créneau au lieu de rester
/// suspendue jusqu'au filet des 10 minutes. L'appelant convertit l'annulation
/// en `URLError(.timedOut)`, transient, que `RetryPolicy` reprend.
///
/// Le délégué par tâche ne reçoit pas `didWriteData` via l'API async : la
/// progression est donc lue par sondage de `countOfBytesReceived`, sans KVO.
private final class StallWatchdog: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Sans octet pendant ce délai, le transfert est réputé à l'arrêt.
    static let interval: TimeInterval = 20
    private static let pollInterval: TimeInterval = 5

    private let lock = NSLock()
    private weak var task: URLSessionTask?
    private var lastBytes: Int64 = 0
    private var lastActivity = Date()
    private var stopped = false
    private var pollTask: Task<Void, Never>?
    private(set) var stalled = false

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func start() {
        let worker = Task { [weak self] in
            while !Task.isCancelled, let self, !self.isStopped {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                if Task.isCancelled { break }
                self.check()
            }
        }
        lock.lock()
        pollTask = worker
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let worker = pollTask
        pollTask = nil
        lock.unlock()
        worker?.cancel()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func check() {
        lock.lock()
        guard !stopped, let task, !stalled else { lock.unlock(); return }
        let bytes = task.countOfBytesReceived
        if bytes != lastBytes {
            lastBytes = bytes
            lastActivity = Date()
        } else if Date().timeIntervalSince(lastActivity) >= Self.interval {
            stalled = true
            lock.unlock()
            task.cancel()
            return
        }
        lock.unlock()
    }
}

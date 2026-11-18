import Foundation

/// Politique d'upload kDrive (API Infomaniak), alignée sur l'app Orvian-IOS :
/// upload direct sous 95 Mio, session chunkée au-delà (recommandation
/// officielle Infomaniak : upload direct recommandé < 100 Mo, sessions
/// chunkées au-delà).
public enum KDriveUploadPolicy {
    /// Seuil direct/session : 95 Mio, marge sous les 100 Mo officiels.
    public static let directUploadLimit: Int64 = 95 * 1024 * 1024
    /// Taille de chunk des sessions (32 Mio), comme Orvian-IOS.
    public static let chunkSize: Int64 = 32 * 1024 * 1024
    /// Chunks envoyés en parallèle par fichier.
    public static let maxConcurrentChunks = 4
    /// Fichiers uploadés en parallèle.
    public static let maxConcurrentUploads = 6
    /// Connexions HTTP simultanées par hôte (borne aussi le débit côté edge).
    public static let maxConnectionsPerHost = 8
    /// L'API accepte au plus 10 000 chunks par session et 1 Gio par requête chunk.
    public static let maxChunksPerSession: Int64 = 10_000
    public static let maxChunkRequestSize: Int64 = 1_000_000_000

    /// `true` si le fichier doit passer par une session chunkée.
    public static func usesChunkedSession(fileSize: Int64) -> Bool {
        fileSize >= directUploadLimit
    }

    /// Plan de découpage : chunks de 32 Mio, augmentés si le fichier dépasse
    /// la limite de 10 000 chunks par session (taille de chunk plafonnée à
    /// 1 Gio, max par requête chunk selon l'API).
    public static func chunkPlan(fileSize: Int64) -> (chunkSize: Int64, totalChunks: Int) {
        let needed = (fileSize + maxChunksPerSession - 1) / maxChunksPerSession
        let size = min(maxChunkRequestSize, max(chunkSize, max(needed, 1)))
        let chunks = Int((fileSize + size - 1) / size)
        return (size, max(chunks, 1))
    }
}

/// Construction et validation des URL d'upload kDrive (sessions chunkées).
public enum KDriveUploadURL {
    /// Hôtes d'upload de confiance. L'URL d'upload reçoit le jeton API en
    /// en-tête : ne jamais suivre d'hôte arbitraire (comme Orvian-IOS).
    public static func isTrustedUploadHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return host == "api.infomaniak.com"
            || host == "upload.kdrive.infomaniak.com"
            || host.hasSuffix(".upload.kdrive.infomaniak.com")
    }

    public static func isTrustedUploadURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && isTrustedUploadHost(url.host)
    }

    /// URL d'un chunk : chemin canonique `/3/drive/{driveId}/upload/session/{token}/chunk`,
    /// hôte = celui de `upload_url` s'il est de confiance (sinon `api.infomaniak.com`
    /// quand `uploadURL` est nil), paramètres de `upload_url` conservés sauf
    /// `chunk_number`/`chunk_size`/`chunk_hash`. Retourne nil si `uploadURL`
    /// est fournie mais non de confiance.
    public static func chunkURL(
        uploadURL: URL?,
        driveId: String,
        sessionToken: String,
        chunkNumber: Int,
        chunkSize: Int64,
        chunkHash: String?
    ) -> URL? {
        if let uploadURL, !isTrustedUploadURL(uploadURL) { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = uploadURL?.host?.lowercased() ?? "api.infomaniak.com"
        if let port = uploadURL?.port { components.port = port }
        components.path = "/3/drive/\(driveId)/upload/session/\(sessionToken)/chunk"
        let preserved = (uploadURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? [])
            .filter { !["chunk_number", "chunk_size", "chunk_hash"].contains($0.name) }
        var query = preserved + [
            URLQueryItem(name: "chunk_number", value: String(chunkNumber)),
            URLQueryItem(name: "chunk_size", value: String(chunkSize)),
        ]
        if let chunkHash {
            query.append(URLQueryItem(name: "chunk_hash", value: "sha256:\(chunkHash)"))
        }
        components.queryItems = query
        return components.url
    }
}

/// Validation du corps de réponse d'un chunk (comme Orvian-IOS) : un 2xx ne
/// suffit pas, l'API peut répondre `result: "error"` ou `status` != "ok".
public enum KDriveChunkReply {
    public static func isAccepted(data: Data, chunkNumber: Int, chunkSize: Int64) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let result = json["result"] as? String, result != "success", result != "asynchronous" { return false }
        guard let chunk = json["data"] as? [String: Any],
              let status = chunk["status"] as? String, status == "ok"
        else { return false }
        if let number = chunk["number"] as? NSNumber, number.intValue != chunkNumber { return false }
        if let size = chunk["size"] as? NSNumber, size.int64Value != chunkSize { return false }
        return true
    }
}

/// Fenêtre glissante de pacing (ex. 50 requêtes/min sous la limite officielle
/// Infomaniak de 60 req/min, non augmentable).
public struct SlidingWindowPacer {
    public let limit: Int
    public let window: TimeInterval
    private var timestamps: [Date] = []

    public init(limit: Int, window: TimeInterval = 60) {
        self.limit = max(limit, 1)
        self.window = window
    }

    /// Enregistre une requête à `now` et renvoie l'attente (en s) avant le
    /// prochain créneau ; 0 si la requête peut partir immédiatement.
    public mutating func reserveSlot(now: Date = Date()) -> TimeInterval {
        timestamps.removeAll { $0 < now.addingTimeInterval(-window) }
        timestamps.append(now)
        if timestamps.count > limit, let oldest = timestamps.first {
            return max(0, oldest.addingTimeInterval(window).timeIntervalSince(now))
        }
        return 0
    }

    /// Nombre de requêtes dans la fenêtre glissante à `now`.
    public func count(at now: Date = Date()) -> Int {
        timestamps.filter { $0 >= now.addingTimeInterval(-window) }.count
    }

    /// Timestamp le plus ancien encore dans la fenêtre (nil si vide).
    public func oldest(at now: Date = Date()) -> Date? {
        timestamps.filter { $0 >= now.addingTimeInterval(-window) }.first
    }
}

import Foundation
import MediaCore
import Observation
import SwiftUI
import UIKit

enum KDriveError: LocalizedError {
    case invalidConfiguration
    case invalidURL
    case authenticationFailed
    case driveNotFound
    case uploadFailed(String)
    case serverError(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return L("Configure le token API et l’ID du Drive dans les Réglages.", "Configure the API token and Drive ID in Settings.")
        case .invalidURL:
            return L("URL de requête kDrive invalide.", "Invalid kDrive request URL.")
        case .authenticationFailed:
            return L("Échec d’authentification : vérifie le token API Infomaniak.", "Authentication failed: check the Infomaniak API token.")
        case .driveNotFound:
            return L("Drive introuvable : vérifie l’ID du kDrive.", "Drive not found: check the kDrive ID.")
        case .uploadFailed(let reason):
            return L("Échec de l’envoi : \(reason)", "Upload failed: \(reason)")
        case .serverError(let code, let message):
            return L("Erreur serveur (\(code)) : \(message)", "Server error (\(code)): \(message)")
        case .cancelled:
            return L("Upload annulé.", "Upload cancelled.")
        }
    }
}

extension KDriveError {
    /// Erreur d'envoi passagère (timeout 408, 429, 5xx, réseau coupé) : le
    /// fichier n'a pas été écrit côté serveur, une relance est sûre.
    static func isTransientUploadError(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case KDriveError.serverError(let code, _) = error { return code == 408 || code == 429 || code >= 500 }
        return false
    }
}

private struct KDriveDriveInfo: Codable {
    let id: Int
    let name: String
}

struct KDriveFolderItem: Identifiable, Codable, Equatable, Hashable {
    let id: Int
    let name: String
    let type: String?
    let lastModifiedAt: Int?
    let updatedAt: Int?

    init(id: Int, name: String, type: String?, lastModifiedAt: Int? = nil, updatedAt: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.lastModifiedAt = lastModifiedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, type, last_modified_at, updated_at }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        lastModifiedAt = try container.decodeIfPresent(Int.self, forKey: .last_modified_at)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updated_at)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(lastModifiedAt, forKey: .last_modified_at)
        try container.encodeIfPresent(updatedAt, forKey: .updated_at)
    }

    var isDirectory: Bool {
        type == "dir" || type == "directory" || type == nil
    }
}

private struct KDriveAPIResponse<T: Codable>: Codable {
    let result: String
    let data: T?
    let error: KDriveAPIError?
    let has_more: Bool?
    let cursor: String?
}

private struct KDriveAPIError: Codable {
    let code: String?
    let description: String?
}

private struct KDriveUploadOutcome {
    let fileURL: URL?
    let fileName: String
    let succeeded: Bool
    let errorMessage: String?
}

@MainActor
@Observable
final class KDriveRateLimitCenter {
    static let shared = KDriveRateLimitCenter()
    static let pacingEnabledDefaultsKey = "kDriveUploadPacingEnabled"
    static let pacingLimitDefaultsKey = "kDriveUploadPacingLimit"

    private(set) var limitedUntil: Date?
    private(set) var requestsLastMinute: Int = 0
    private(set) var nextSlotDelay: TimeInterval = 0

    @ObservationIgnored private var pacer: SlidingWindowPacer
    private let defaults: UserDefaults
    /// Limite officielle Infomaniak : 60 requêtes/minute, non augmentable,
    /// quel que soit l'abonnement (kDrive 6 To inclus).
    static let officialLimitPerMinute = 60
    /// Plafond par défaut (58) sous la limite officielle : toutes les requêtes
    /// kDrive (chunks compris) passent par `waitForRequestSlot`, espacées
    /// uniformément, pour ne jamais l'atteindre et éviter les 429. Le plafond
    /// est réglable de 10 à 60 req/min dans Réglages.
    static let pacingLimitPerMinute = KDriveUploadPolicy.defaultPacingLimitPerMinute

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pacer = SlidingWindowPacer(limit: Self.currentPacingLimit(defaults: defaults))
    }

    nonisolated static func isPacingEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: pacingEnabledDefaultsKey) == nil { return true }
        return defaults.bool(forKey: pacingEnabledDefaultsKey)
    }

    nonisolated static func currentPacingLimit(defaults: UserDefaults = .standard) -> Int {
        if defaults.object(forKey: pacingLimitDefaultsKey) == nil {
            return KDriveUploadPolicy.defaultPacingLimitPerMinute
        }
        return KDriveUploadPolicy.clampedPacingLimit(defaults.integer(forKey: pacingLimitDefaultsKey))
    }

    var isPacingEnabled: Bool {
        Self.isPacingEnabled(defaults: defaults)
    }

    var pacingLimit: Int {
        Self.currentPacingLimit(defaults: defaults)
    }

    var apiRateLabel: String {
        isPacingEnabled
            ? "\(requestsLastMinute)/\(pacingLimit) req/min"
            : "\(requestsLastMinute) req/min"
    }

    /// Aligne le pacer sur le plafond courant : `@AppStorage` peut modifier
    /// `UserDefaults` sans passer par `updatePacingLimit`.
    private func syncPacerLimit() {
        let limit = pacingLimit
        if pacer.limit != limit { pacer.updateLimit(limit) }
    }

    /// Applique un nouveau plafond (curseur des Réglages) et rafraîchit
    /// immédiatement l'état affiché.
    func updatePacingLimit(_ limit: Int, now: Date = Date()) {
        let clamped = KDriveUploadPolicy.clampedPacingLimit(limit)
        pacer.updateLimit(clamped)
        refreshPacingInfo(now: now)
    }

    /// À appeler après chaque réponse kDrive (listing, envoi, test…).
    /// Retient la fenêtre de rate limit (429 ou code d'erreur dédié) et
    /// lève l'état dès qu'une requête réussit après la fenêtre.
    nonisolated static func register(response: HTTPURLResponse, body: Data?) {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
        let statusCode = response.statusCode
        let isRateLimitBody = statusCode == 429 || Self.isRateLimitErrorCode(body)
        Task { @MainActor in
            shared.sync(statusCode: statusCode, retryAfter: retryAfter, isRateLimitBody: isRateLimitBody)
        }
    }

    /// À appeler avant chaque requête kDrive (listing, envoi, chunk, test…)
    /// : bloque jusqu'à ce qu'un créneau soit disponible dans la fenêtre
    /// glissante de pacing (si activée), ou que la fenêtre de rate limit
    /// imposée par le serveur (429 / `Retry-After`) soit passée.
    nonisolated static func waitForRequestSlot() async {
        while true {
            // Arrêt demandé : on sort tout de suite au lieu d'attendre le
            // créneau (le `try?` ci-dessous avale le CancellationError).
            if Task.isCancelled { return }
            let wait = await MainActor.run { shared.reserveSlot() }
            if wait <= 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.1) * 1_000_000_000))
        }
    }

    /// Enregistre le départ d'une requête et renvoie le délai (en s) avant le
    /// prochain créneau ; 0 si la requête peut partir immédiatement.
    func reserveSlot(now: Date = Date()) -> TimeInterval {
        syncPacerLimit()
        if let until = limitedUntil, until > now {
            let wait = until.timeIntervalSince(now)
            if abs(nextSlotDelay - wait) > 0.05 { nextSlotDelay = wait }
            return wait
        }
        guard isPacingEnabled else {
            pacer.record(now: now)
            let count = pacer.count(at: now)
            if requestsLastMinute != count { requestsLastMinute = count }
            if nextSlotDelay != 0 { nextSlotDelay = 0 }
            return 0
        }
        let wait = pacer.reserveSlot(now: now)
        let count = pacer.count(at: now)
        if requestsLastMinute != count { requestsLastMinute = count }
        let nextDelay = pacer.nextSlotWait(now: now)
        if abs(nextSlotDelay - nextDelay) > 0.05 { nextSlotDelay = nextDelay }
        return wait > 0 ? max(wait, 0.1) : 0
    }

    /// Rafraîchit les compteurs de cadence sans consommer de créneau, pour
    /// afficher en continu l'état de l'API pendant un envoi.
    func refreshPacingInfo(now: Date = Date()) {
        syncPacerLimit()
        let count = pacer.count(at: now)
        if requestsLastMinute != count { requestsLastMinute = count }
        let nextDelay: TimeInterval
        if let until = limitedUntil, until > now {
            nextDelay = until.timeIntervalSince(now)
        } else if isPacingEnabled {
            nextDelay = pacer.nextSlotWait(now: now)
        } else {
            nextDelay = 0
        }
        if abs(nextSlotDelay - nextDelay) > 0.05 { nextSlotDelay = nextDelay }
    }

    /// Codes d'erreur officiels (`error.code`) qui traduisent un rate limit.
    nonisolated private static func isRateLimitErrorCode(_ body: Data?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        // Chemin rapide sur 2xx : évite JSONSerialization si `"error"` absent.
        guard body.range(of: Data("\"error\"".utf8)) != nil,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = json["result"] as? String, result == "error"
        else { return false }
        let error = json["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? ""
        let description = (error?["description"] as? String) ?? ""
        return code.contains("too_many_requests")
            || code.contains("rate_limit")
            || code.contains("limit_exceeded")
            || description.lowercased().contains("too many requests")
    }

    func sync(statusCode: Int, retryAfter: Double?, isRateLimitBody: Bool, now: Date = Date()) {
        syncPacerLimit()
        // Le pacer est alimenté par `reserveSlot` (avant l'envoi) :
        // ne pas compter deux fois la même requête ici.
        let count = pacer.count(at: now)
        if requestsLastMinute != count { requestsLastMinute = count }

        // Mécanisme officiel d'erreur Infomaniak (developer.infomaniak.com) :
        // HTTP 429 ou corps JSON `result: "error"` avec un code de bridage.
        if statusCode == 429 || isRateLimitBody {
            let window = min(max(retryAfter ?? 60, 1), 3600)
            if (limitedUntil ?? .distantPast) < now {
                LogCenter.err(L("kDrive : rate limit API détecté — reprise estimée dans \(Int(window)) s.", "kDrive: API rate limit detected — estimated resume in \(Int(window)) s."))
            }
            let target = max(limitedUntil ?? .distantPast, now.addingTimeInterval(window))
            if limitedUntil != target { limitedUntil = target }
            return
        }
        if isPacingEnabled && count > Self.officialLimitPerMinute {
            if let oldest = pacer.oldest(at: now) {
                let resume = oldest.addingTimeInterval(60)
                if (limitedUntil ?? .distantPast) < now {
                    LogCenter.err(L("kDrive : \(count) requêtes API en 60 s (limite officielle : \(Self.officialLimitPerMinute)/min) — reprise estimée à \(resume.formatted(date: .omitted, time: .standard)).", "kDrive: \(count) API requests in 60 s (official limit: \(Self.officialLimitPerMinute)/min) — estimated resume at \(resume.formatted(date: .omitted, time: .standard))."))
                }
                let target = max(limitedUntil ?? .distantPast, resume)
                if limitedUntil != target { limitedUntil = target }
            }
            return
        }
        if (200..<300).contains(statusCode), now > (limitedUntil ?? .distantPast), limitedUntil != nil {
            limitedUntil = nil
        }
    }
}

@MainActor
@Observable
final class KDriveService {
    static let shared = KDriveService()
    static let concurrentUploadsDefaultsKey = "kDriveConcurrentUploads"

    nonisolated static func currentConcurrentUploadLimit(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: concurrentUploadsDefaultsKey) != nil else {
            return KDriveUploadPolicy.maxConcurrentUploads
        }
        return KDriveUploadPolicy.clampedConcurrentUploads(defaults.integer(forKey: concurrentUploadsDefaultsKey))
    }

    static var concurrentUploadLimit: Int {
        currentConcurrentUploadLimit()
    }

    var isUploading = false
    var currentProgress = 0.0
    var currentFileIndex = 0
    var totalFilesCount = 0
    var currentFileName = ""
    var lastError: String?
    private(set) var uploadedFileURLs: [URL] = []
    private(set) var wasCancelled = false
    private(set) var lastSuccessCount = 0
    private(set) var lastFailedCount = 0

    private var activeTask: Task<Void, Never>?
    private var uploadGeneration = UUID()

    private init() {}

    func testConnection(token: String, driveId: String) async throws -> String {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else { throw KDriveError.invalidConfiguration }
        guard let url = URL(string: "https://api.infomaniak.com/2/drive/\(cleanDriveId)") else {
            throw KDriveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        await KDriveRateLimitCenter.waitForRequestSlot()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }

        KDriveRateLimitCenter.register(response: httpResponse, body: data)

        if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
        if httpResponse.statusCode == 404 { throw KDriveError.driveNotFound }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let decoded = try? JSONDecoder().decode(KDriveAPIResponse<KDriveDriveInfo>.self, from: data),
               let description = decoded.error?.description {
                throw KDriveError.serverError(httpResponse.statusCode, description)
            }
            throw KDriveError.serverError(httpResponse.statusCode, "HTTP \(httpResponse.statusCode)")
        }

        let decoded = try JSONDecoder().decode(KDriveAPIResponse<KDriveDriveInfo>.self, from: data)
        return decoded.data?.name ?? "kDrive (ID: \(cleanDriveId))"
    }

    /// Liste les sous-dossiers d'un répertoire, en suivant la pagination
    /// `cursor` / `has_more` (un seul appel suffisait sous 200 dossiers).
    func fetchSubdirectories(token: String, driveId: String, directoryId: String = "1") async throws -> [KDriveFolderItem] {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectoryId = trimmedDirectory.isEmpty ? "1" : trimmedDirectory
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else { throw KDriveError.invalidConfiguration }

        var allFolders: [KDriveFolderItem] = []
        var cursor: String?
        var hasMore = true
        while hasMore {
            var components = URLComponents(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/files/\(cleanDirectoryId)/files")
            var queryItems = [
                URLQueryItem(name: "type[]", value: "dir"),
                URLQueryItem(name: "limit", value: "200")
            ]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components?.queryItems = queryItems
            if let encoded = components?.percentEncodedQuery {
                components?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
            }
            guard let url = components?.url else { throw KDriveError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            await KDriveRateLimitCenter.waitForRequestSlot()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
            }
            if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
                        KDriveRateLimitCenter.register(response: httpResponse, body: data)
guard (200..<300).contains(httpResponse.statusCode) else {
                if let decoded = try? JSONDecoder().decode(KDriveAPIResponse<[KDriveFolderItem]>.self, from: data),
                   let description = decoded.error?.description {
                    LogCenter.err(L("kDrive : listing des dossiers échoué (HTTP \(httpResponse.statusCode)) : \(description)", "kDrive: folder listing failed (HTTP \(httpResponse.statusCode)): \(description)"))
                    throw KDriveError.serverError(httpResponse.statusCode, description)
                }
                LogCenter.err(L("kDrive : listing des dossiers échoué (HTTP \(httpResponse.statusCode)).", "kDrive: folder listing failed (HTTP \(httpResponse.statusCode))."))
                throw KDriveError.serverError(httpResponse.statusCode, "HTTP \(httpResponse.statusCode)")
            }

            let decoded = try JSONDecoder().decode(KDriveAPIResponse<[KDriveFolderItem]>.self, from: data)
            allFolders.append(contentsOf: decoded.data ?? [])
            // Garde anti-blocage : si l'API renvoie `has_more` sans nouveau
            // cursor (ou le même), on s'arrête au lieu de boucler à l'infini
            // sur la même page — c'est ce qui gelait la préparation des
            // dossiers déjà remplis par un envoi partiel.
            let nextCursor = decoded.cursor
            if (decoded.has_more ?? false), let nextCursor, !nextCursor.isEmpty, nextCursor != cursor {
                cursor = nextCursor
            } else {
                hasMore = false
            }
        }
        return allFolders
            .filter(\.isDirectory)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Vérifie quels dossiers (par nom) existent déjà dans kDrive.
    /// Une seule requête : liste les sous-dossiers du parent, puis matching local.
    func folderStatus(token: String, driveId: String, parentDirectoryId: String = "1", names: [String]) async throws -> [String: KDriveFolderItem] {
        let existing = try await fetchSubdirectories(token: token, driveId: driveId, directoryId: parentDirectoryId)
        var byNormalizedName: [String: KDriveFolderItem] = [:]
        for item in existing {
            let key = FilenamePolicy.kDriveNormalizedName(item.name)
            if byNormalizedName[key] == nil { byNormalizedName[key] = item }
        }
        var result: [String: KDriveFolderItem] = [:]
        for name in names {
            let target = FilenamePolicy.kDriveNormalizedName(FilenamePolicy.kDriveFolderName(name))
            if let match = byNormalizedName[target] {
                result[name] = match
            }
        }
        return result
    }

    /// Noms des fichiers déjà présents dans un dossier, en suivant la
    /// pagination `cursor` / `has_more`. Sert à ne pas ré-uploader les
    /// médias existants (comparaison par nom, insensible casse/diacritiques).
    func fetchFileNames(token: String, driveId: String, directoryId: String) async throws -> Set<String> {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectoryId = trimmedDirectory.isEmpty ? "1" : trimmedDirectory
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else { throw KDriveError.invalidConfiguration }

        var names = Set<String>()
        var cursor: String?
        var hasMore = true
        while hasMore {
            var components = URLComponents(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/files/\(cleanDirectoryId)/files")
            var queryItems = [
                URLQueryItem(name: "type[]", value: "file"),
                URLQueryItem(name: "limit", value: "200")
            ]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components?.queryItems = queryItems
            if let encoded = components?.percentEncodedQuery {
                components?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
            }
            guard let url = components?.url else { throw KDriveError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            await KDriveRateLimitCenter.waitForRequestSlot()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
            }
            if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
                        KDriveRateLimitCenter.register(response: httpResponse, body: data)
guard (200..<300).contains(httpResponse.statusCode) else {
                if let decoded = try? JSONDecoder().decode(KDriveAPIResponse<[KDriveFolderItem]>.self, from: data),
                   let description = decoded.error?.description {
                    LogCenter.err(L("kDrive : listing des fichiers échoué (HTTP \(httpResponse.statusCode)) : \(description)", "kDrive: file listing failed (HTTP \(httpResponse.statusCode)): \(description)"))
                    throw KDriveError.serverError(httpResponse.statusCode, description)
                }
                LogCenter.err(L("kDrive : listing des fichiers échoué (HTTP \(httpResponse.statusCode)).", "kDrive: file listing failed (HTTP \(httpResponse.statusCode))."))
                throw KDriveError.serverError(httpResponse.statusCode, "HTTP \(httpResponse.statusCode)")
            }

            let decoded = try JSONDecoder().decode(KDriveAPIResponse<[KDriveFolderItem]>.self, from: data)
            for item in decoded.data ?? [] {
                // `type[]=file` ne garantit pas `type` renseigné : on n'exclut
                // que les dossiers avérés, jamais les types inconnus.
                if item.type == "dir" || item.type == "directory" { continue }
                names.insert(item.name)
            }
            // Garde anti-blocage : sans nouveau cursor, `has_more` seul ne
            // doit jamais relancer la boucle — c'est ce qui gelait la
            // déduplication sur les dossiers déjà remplis (envoi partiel
            // puis relance, même après redémarrage de l'app).
            let nextCursor = decoded.cursor
            if (decoded.has_more ?? false), let nextCursor, !nextCursor.isEmpty, nextCursor != cursor {
                cursor = nextCursor
            } else {
                hasMore = false
            }
        }
        return names
    }

    func createDirectory(token: String, driveId: String, parentDirectoryId: String = "1", folderName: String) async throws -> KDriveFolderItem {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParent = parentDirectoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanParentId = trimmedParent.isEmpty ? "1" : trimmedParent
        let cleanName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty, !cleanName.isEmpty else {
            throw KDriveError.invalidConfiguration
        }
        guard let url = URL(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/files/\(cleanParentId)/directory") else {
            throw KDriveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": cleanName])

        await KDriveRateLimitCenter.waitForRequestSlot()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
                    KDriveRateLimitCenter.register(response: httpResponse, body: data)
guard (200..<300).contains(httpResponse.statusCode) else {
            if let decoded = try? JSONDecoder().decode(KDriveAPIResponse<KDriveFolderItem>.self, from: data),
               let description = decoded.error?.description {
                LogCenter.err(L("kDrive : création du dossier « \(cleanName) » échouée (HTTP \(httpResponse.statusCode)) : \(description)", "kDrive: creating folder “\(cleanName)” failed (HTTP \(httpResponse.statusCode)): \(description)"))
                throw KDriveError.serverError(httpResponse.statusCode, description)
            }
            LogCenter.err(L("kDrive : création du dossier « \(cleanName) » échouée (HTTP \(httpResponse.statusCode)).", "kDrive: creating folder “\(cleanName)” failed (HTTP \(httpResponse.statusCode))."))
            throw KDriveError.serverError(httpResponse.statusCode, L("Création du dossier impossible", "Could not create folder"))
        }

        let decoded = try JSONDecoder().decode(KDriveAPIResponse<KDriveFolderItem>.self, from: data)
        guard let folder = decoded.data else {
            throw KDriveError.serverError(httpResponse.statusCode, L("Impossible de lire le dossier créé", "Could not read the created folder"))
        }
        return folder
    }

    func uploadFile(fileURL: URL, token: String, driveId: String, directoryId: String) async throws {
        try await Self.performUpload(fileURL: fileURL, token: token, driveId: driveId, directoryId: directoryId)
    }

    nonisolated private static func performUpload(fileURL: URL, token: String, driveId: String, directoryId: String) async throws {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectoryId = trimmedDirectory.isEmpty ? "1" : trimmedDirectory
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else { throw KDriveError.invalidConfiguration }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let originalName = fileURL.lastPathComponent
        guard fileSize > 0 else {
            throw KDriveError.uploadFailed(L("Fichier vide (0 octet) : \(originalName)", "Empty file (0 bytes): \(originalName)"))
        }
        // L'upload direct kDrive est limité à 1 Go : au-delà, il faut une
        // session chunkée, non prise en charge par cette version.
        guard fileSize <= 1_000_000_000 else {
            throw KDriveError.uploadFailed(L("Fichier trop volumineux pour l'envoi direct (> 1 Go) : \(originalName)", "File too large for direct upload (> 1 GB): \(originalName)"))
        }
        // Les titres Reddit contiennent souvent `? " * < > | \` : kDrive
        // répond 422 `validation_failed` au lieu d'accepter le nom.
        // On envoie donc un nom assaini, avec une 2e tentative ultra-sûre.
        let safeName = FilenamePolicy.kDriveFileName(originalName)
        do {
            try await Self.performSingleUpload(
                fileURL: fileURL, remoteFileName: safeName, fileSize: fileSize,
                token: cleanToken, driveId: cleanDriveId, directoryId: cleanDirectoryId
            )
        } catch let error as KDriveError {
            if case .serverError(let code, let message) = error, code == 422 {
                let fallback = FilenamePolicy.kDriveFallbackName(for: originalName)
                if fallback != safeName {
                    LogCenter.kdrive(L("kDrive : nom refusé (422) pour \(originalName), nouvelle tentative avec \(fallback).", "kDrive: name rejected (422) for \(originalName), retrying with \(fallback)."))
                    do {
                        try await Self.performSingleUpload(
                            fileURL: fileURL, remoteFileName: fallback, fileSize: fileSize,
                            token: cleanToken, driveId: cleanDriveId, directoryId: cleanDirectoryId
                        )
                        return
                    } catch {
                        throw KDriveError.serverError(code, L("\(originalName) refusé même renommé (\(fallback)) : \(message)", "\(originalName) rejected even renamed (\(fallback)): \(message)"))
                    }
                }
            }
            throw error
        }
    }

    nonisolated private static func performSingleUpload(fileURL: URL, remoteFileName: String, fileSize: Int64, token cleanToken: String, driveId cleanDriveId: String, directoryId cleanDirectoryId: String) async throws {
        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let lastModifiedAt = Int(((fileAttrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        var components = URLComponents(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/upload")
        components?.queryItems = [
            URLQueryItem(name: "directory_id", value: cleanDirectoryId),
            URLQueryItem(name: "file_name", value: remoteFileName),
            URLQueryItem(name: "total_size", value: String(fileSize)),
            URLQueryItem(name: "last_modified_at", value: String(lastModifiedAt)),
            URLQueryItem(name: "conflict", value: "rename")
        ]
        if let encodedQuery = components?.percentEncodedQuery {
            components?.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let requestURL = components?.url else { throw KDriveError.invalidURL }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        await KDriveRateLimitCenter.waitForRequestSlot()
        let (data, response) = try await KDriveUploadSession.session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }

        KDriveRateLimitCenter.register(response: httpResponse, body: data)
        if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
        if httpResponse.statusCode == 404 {
            throw KDriveError.uploadFailed(L("Dossier ou Drive introuvable", "Folder or Drive not found"))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw KDriveError.serverError(httpResponse.statusCode, Self.detailedMessage(from: data, statusCode: httpResponse.statusCode, fileName: remoteFileName))
        }
    }

    /// Extrait le détail `error.errors[]` d'Infomaniak au lieu du seul
    /// `error.description` générique (« Validation failed »), en précisant
    /// le fichier concerné pour retrouver les 422 dans un lot de 446.
    nonisolated private static func detailedMessage(from data: Data, statusCode: Int, fileName: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let description = (error["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var details: [String] = []
            if let items = error["errors"] as? [[String: Any]] {
                for item in items.prefix(3) {
                    let d = (item["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let code = (item["code"] as? String) ?? ""
                    let attribute = ((item["context"] as? [String: Any])?["attribute"] as? String) ?? ""
                    let part = [attribute, code, d].filter { !$0.isEmpty }.joined(separator: " ")
                    if !part.isEmpty { details.append(part) }
                }
            }
            var base = description?.isEmpty == false ? description! : "HTTP \(statusCode)"
            if !details.isEmpty { base += " — " + details.joined(separator: " · ") }
            return "\(fileName) : \(base)"
        }
        return "\(fileName) : HTTP \(statusCode)"
    }

    func uploadBatch(
        files: [URL],
        token: String,
        driveId: String,
        directoryId: String,
        completion: @escaping (_ successCount: Int, _ failedCount: Int, _ errorMessage: String?) -> Void
    ) {
        let configured = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard configured else {
            completion(0, files.count, KDriveError.invalidConfiguration.localizedDescription)
            return
        }

        cancelUpload()
        let generation = UUID()
        uploadGeneration = generation
        wasCancelled = false
        isUploading = true
        currentProgress = 0
        currentFileIndex = 0
        totalFilesCount = files.count
        currentFileName = ""
        lastError = nil
        uploadedFileURLs = []
        lastSuccessCount = 0
        lastFailedCount = 0

        activeTask = Task {
            var success = 0
            var failed = 0
            var completed = 0
            var failedExamples: [KDriveUploadOutcome] = []
            let limit = max(1, Self.concurrentUploadLimit)

            func uploadOne(_ fileURL: URL) async -> KDriveUploadOutcome {
                if Task.isCancelled {
                    return KDriveUploadOutcome(fileURL: fileURL, fileName: fileURL.lastPathComponent, succeeded: false, errorMessage: KDriveError.cancelled.localizedDescription)
                }
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return KDriveUploadOutcome(
                        fileURL: fileURL,
                        fileName: fileURL.lastPathComponent,
                        succeeded: false,
                        errorMessage: L("Fichier introuvable : \(fileURL.lastPathComponent)", "File not found: \(fileURL.lastPathComponent)")
                    )
                }
                do {
                    try await KDriveService.performUpload(
                        fileURL: fileURL,
                        token: token,
                        driveId: driveId,
                        directoryId: directoryId
                    )
                    return KDriveUploadOutcome(fileURL: fileURL, fileName: fileURL.lastPathComponent, succeeded: true, errorMessage: nil)
                } catch {
                    if KDriveError.isTransientUploadError(error), !Task.isCancelled {
                        LogCenter.kdrive(L("kDrive : erreur transitoire sur \(fileURL.lastPathComponent), nouvelle tentative…", "kDrive: transient error on \(fileURL.lastPathComponent), retrying…"))
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else {
                            return KDriveUploadOutcome(fileURL: fileURL, fileName: fileURL.lastPathComponent, succeeded: false, errorMessage: KDriveError.cancelled.localizedDescription)
                        }
                        do {
                            try await KDriveService.performUpload(
                                fileURL: fileURL,
                                token: token,
                                driveId: driveId,
                                directoryId: directoryId
                            )
                            return KDriveUploadOutcome(fileURL: fileURL, fileName: fileURL.lastPathComponent, succeeded: true, errorMessage: nil)
                        } catch {
                            return KDriveUploadOutcome(fileURL: fileURL, fileName: fileURL.lastPathComponent, succeeded: false, errorMessage: error.localizedDescription)
                        }
                    }
                    return KDriveUploadOutcome(fileURL: fileURL, fileName: fileURL.lastPathComponent, succeeded: false, errorMessage: error.localizedDescription)
                }
            }

            await withTaskGroup(of: KDriveUploadOutcome.self) { group in
                var nextIndex = 0
                for _ in 0..<min(limit, files.count) {
                    let url = files[nextIndex]
                    nextIndex += 1
                    group.addTask { await uploadOne(url) }
                }

                while let outcome = await group.next() {
                    if Task.isCancelled || self.uploadGeneration != generation {
                        group.cancelAll()
                        break
                    }
                    completed += 1
                    currentFileIndex = completed
                    currentFileName = outcome.fileName
                    currentProgress = Double(completed) / Double(max(1, files.count))
                    if outcome.succeeded {
                        success += 1
                        if let url = outcome.fileURL { uploadedFileURLs.append(url) }
                        LogCenter.kdrive(L("kDrive : envoyé — \(outcome.fileName)", "kDrive: uploaded — \(outcome.fileName)"))
                    } else {
                        failed += 1
                        LogCenter.err(L("kDrive : échec — \(outcome.fileName) : \(outcome.errorMessage ?? "")", "kDrive: failed — \(outcome.fileName): \(outcome.errorMessage ?? "")"))
                        if failedExamples.count < 5 { failedExamples.append(outcome) }
                    }

                    if nextIndex < files.count && !Task.isCancelled && self.uploadGeneration == generation {
                        let url = files[nextIndex]
                        nextIndex += 1
                        group.addTask { await uploadOne(url) }
                    }
                }
            }

            guard self.uploadGeneration == generation else { return }

            let summaryMessage: String? = {
                guard failed > 0 else { return nil }
                let examples = failedExamples.compactMap { o -> String? in
                    guard let msg = o.errorMessage, !msg.isEmpty else { return o.fileName }
                    return "\(o.fileName) : \(msg)"
                }.joined(separator: "\n")
                let hint = L("Astuce : les noms avec ? \" * < > | \\ / : sont désormais renommés automatiquement à l'envoi. Relance l'upload des fichiers restants après mise à jour.", "Tip: names with ? \" * < > | \\ / : are now renamed automatically on upload. Re-run the upload for the remaining files after updating.")
                return L("\(failed) échec(s) sur \(files.count). Exemples :\n\(examples)\n\(hint)", "\(failed) failure(s) out of \(files.count). Examples:\n\(examples)\n\(hint)")
            }()

            isUploading = false
            activeTask = nil
            lastError = summaryMessage
            lastSuccessCount = success
            lastFailedCount = failed
            if Task.isCancelled || wasCancelled {
                completion(success, failed, KDriveError.cancelled.localizedDescription)
            } else {
                currentProgress = files.isEmpty ? 0 : 1
                completion(success, failed, summaryMessage)
            }
        }
    }

    func cancelUpload() {
        uploadGeneration = UUID()
        wasCancelled = true
        activeTask?.cancel()
        activeTask = nil
        isUploading = false
    }
}

struct KDriveUploadButton: View {
    let files: [URL]

    @AppStorage("kDriveApiToken") private var token = ""
    @AppStorage("kDriveId") private var driveId = ""
    @State private var showUpload = false
    @State private var showNotConfigured = false

    private var configured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button {
            if configured { showUpload = true } else { showNotConfigured = true }
        } label: {
            Image(systemName: "icloud.and.arrow.up")
        }
        .disabled(files.isEmpty)
        .accessibilityLabel(L("Envoyer les médias affichés vers kDrive", "Upload displayed media to kDrive"))
        .sheet(isPresented: $showUpload) {
            KDriveUploadFlowSheet(files: files, token: token, driveId: driveId)
        }
        .alert(L("kDrive non configuré", "kDrive is not configured"), isPresented: $showNotConfigured) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(L("Renseigne le token API et l’ID du Drive dans Réglages > Infomaniak kDrive.", "Enter the API token and Drive ID in Settings > Infomaniak kDrive."))
        }
    }
}

private enum KDriveConnectionStatus {
    case success(String)
}

/// Interrupteur partagé entre Réglages et le détail Infomaniak kDrive pour
/// activer ou désactiver le plafond de cadence en upload.
struct KDrivePacingToggle: View {
    @AppStorage(KDriveRateLimitCenter.pacingEnabledDefaultsKey) private var pacingEnabled = true

    var body: some View {
        Toggle(
            L("Upload plafonné", "Capped upload"),
            isOn: $pacingEnabled
        )
        .onChange(of: pacingEnabled) { _, _ in
            KDriveRateLimitCenter.shared.refreshPacingInfo()
        }
    }
}

/// Curseur discret (10 à 60 req/min) du plafond d'upload, partagé entre
/// Réglages et le détail Infomaniak kDrive.
struct KDrivePacingLimitSlider: View {
    @AppStorage(KDriveRateLimitCenter.pacingEnabledDefaultsKey) private var pacingEnabled = true
    @AppStorage(KDriveRateLimitCenter.pacingLimitDefaultsKey) private var pacingLimit = KDriveUploadPolicy.defaultPacingLimitPerMinute

    private var clamped: Int {
        KDriveUploadPolicy.clampedPacingLimit(pacingLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space(2)) {
            HStack {
                Text(L("Limite d'upload", "Upload limit"))
                    .font(.subheadline)
                Spacer()
                Text("\(clamped) req/min")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(DS.onSurfaceMuted)
            }
            Slider(
                value: Binding(
                    get: { Double(clamped) },
                    set: { value in
                        let rounded = Int(value.rounded())
                        pacingLimit = rounded
                        KDriveRateLimitCenter.shared.updatePacingLimit(rounded)
                    }
                ),
                in: Double(KDriveUploadPolicy.minPacingLimitPerMinute)...Double(KDriveUploadPolicy.maxPacingLimitPerMinute),
                step: 1
            )
            .tint(DS.accentEmphasis)
            .disabled(!pacingEnabled)
            .accessibilityLabel(L("Limite d'upload", "Upload limit"))
            .accessibilityValue("\(clamped) req/min")
        }
        .opacity(pacingEnabled ? 1 : 0.45)
    }
}

/// Sélecteur partagé entre Réglages et le détail Infomaniak kDrive pour
/// choisir le nombre d'uploads simultanés (4, 6, 8 ou 10).
struct KDriveConcurrentUploadsPicker: View {
    @AppStorage(KDriveService.concurrentUploadsDefaultsKey) private var concurrentUploads = KDriveUploadPolicy.maxConcurrentUploads

    var body: some View {
        let clamped = KDriveUploadPolicy.clampedConcurrentUploads(concurrentUploads)
        VStack(alignment: .leading, spacing: DS.space(2)) {
            HStack {
                Text(L("Uploads simultanés", "Concurrent uploads"))
                Spacer()
                Text("\(clamped)")
                    .monospacedDigit()
                    .foregroundStyle(DS.onSurfaceMuted)
            }
            Picker(L("Uploads simultanés", "Concurrent uploads"), selection: Binding(
                get: { clamped },
                set: { concurrentUploads = KDriveUploadPolicy.clampedConcurrentUploads($0) }
            )) {
                ForEach(KDriveUploadPolicy.uploadConcurrencyOptions, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityValue("\(clamped)")
        }
    }
}

/// Détail de la connexion kDrive, poussé depuis la ligne kDrive de la zone
/// Connexions des Réglages (même habillage que les autres services).
struct KDriveSettingsDetailView: View {
    private enum Field: Hashable { case token, driveId }

    @State private var rateLimit = KDriveRateLimitCenter.shared
    @State private var now = Date()
    @AppStorage("kDriveApiToken") private var token = ""
    @AppStorage("kDriveId") private var driveId = ""
    @AppStorage("kDriveDirectoryId") private var directoryId = "1"
    @AppStorage("kDriveDirectoryName") private var directoryName = ""

    @FocusState private var focusedField: Field?
    @State private var showToken = false
    @State private var isTestingConnection = false
    @State private var connectionStatus: KDriveConnectionStatus?
    @State private var connectionError: String?
    @State private var showResetConfirm = false

    private var configured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: DS.space(2)) {
                    Group {
                        if showToken {
                            TextField(L("Token API", "API token"), text: $token)
                        } else {
                            SecureField(L("Token API", "API token"), text: $token)
                        }
                    }
                    .focused($focusedField, equals: .token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button { showToken.toggle() } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .tint(DS.accentEmphasis)
                    .accessibilityLabel(showToken ? L("Masquer le token API", "Hide API token") : L("Afficher le token API", "Show API token"))

                    Button(L("Coller", "Paste")) {
                        if let value = UIPasteboard.general.string {
                            token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .buttonStyle(.borderless)
                    .tint(DS.accentEmphasis)
                    .frame(minHeight: 44)
                }

                TextField(L("ID du Drive", "Drive ID"), text: $driveId)
                    .focused($focusedField, equals: .driveId)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                NavigationLink {
                    KDriveFolderPickerView(
                        token: token,
                        driveId: driveId,
                        directoryId: $directoryId,
                        directoryName: $directoryName,
                        embeddedInNavigationStack: true
                    )
                } label: {
                    HStack {
                        Label(directoryName.isEmpty ? L("Racine (kDrive)", "Root (kDrive)") : directoryName, systemImage: "folder.fill")
                        Spacer()
                        Text("ID: \(directoryId)")
                            .font(.caption.monospaced())
                            .foregroundStyle(DS.onSurfaceMuted)
                    }
                }
                .disabled(!configured)

                Button {
                    focusedField = nil
                    testConnection()
                } label: {
                    HStack {
                        if isTestingConnection { ProgressView().controlSize(.small) }
                        Label(L("Tester la connexion", "Test connection"), systemImage: "network")
                    }
                }
                .disabled(!configured || isTestingConnection)

                if let until = rateLimit.limitedUntil, until > now {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("kDrive limité (rate limit actif)", "kDrive rate-limited"), systemImage: "hourglass")
                            .font(.footnote)
                            .foregroundStyle(DS.accentEmphasis)
                        Text(L("Reprise estimée : \(until.formatted(date: .omitted, time: .standard))", "Estimated resume: \(until.formatted(date: .omitted, time: .standard))"))
                            .font(.caption2)
                            .foregroundStyle(DS.onSurfaceMuted)
                    }
                } else if configured {
                    Label(L("kDrive opérationnel (aucun rate limit)", "kDrive operational (no rate limit)"), systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(DS.success)
                } else {
                    Label(L("Token API ou ID du Drive manquant", "API token or Drive ID missing"), systemImage: "gearshape")
                        .font(.footnote)
                        .foregroundStyle(DS.warning)
                }

                if configured || rateLimit.requestsLastMinute > 0 {
                    Text(L("API kDrive : \(rateLimit.requestsLastMinute)/\(KDriveRateLimitCenter.officialLimitPerMinute) requêtes/min (limite officielle)", "kDrive API: \(rateLimit.requestsLastMinute)/\(KDriveRateLimitCenter.officialLimitPerMinute) requests/min (official limit)"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(rateLimit.requestsLastMinute >= 45 ? DS.accentEmphasis : DS.onSurfaceMuted)
                }

                if let status = connectionStatus {
                    switch status {
                    case .success(let name):
                        Label(L("Connecté : \(name)", "Connected: \(name)"), systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(DS.success)
                    }
                }
            } header: {
                Text("Infomaniak kDrive")
            } footer: {
                Text(L("Le token et l’ID restent enregistrés localement sur cet appareil. Le dossier choisi ici sert de destination aux envois depuis la Bibliothèque : un sous-dossier par collection y est créé automatiquement.", "The token and ID remain stored locally on this device. The folder chosen here is the destination for uploads from the Library: a subfolder per collection is created inside it automatically."))
            }

            Section {
                KDrivePacingToggle()
                KDrivePacingLimitSlider()
                KDriveConcurrentUploadsPicker()
            } header: {
                Text(L("Cadence d'upload", "Upload pacing"))
            } footer: {
                Text(L("Espace les requêtes jusqu’au plafond choisi sous la limite officielle Infomaniak (\(KDriveRateLimitCenter.officialLimitPerMinute)/min) pour éviter les erreurs 429.", "Spaces requests up to the chosen cap under Infomaniak's official limit (\(KDriveRateLimitCenter.officialLimitPerMinute)/min) to avoid 429 errors."))
            }

            if configured || directoryId != "1" || !directoryName.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(L("Effacer la configuration kDrive", "Clear kDrive configuration"), systemImage: "trash")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L("Infomaniak kDrive", "Infomaniak kDrive"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L("OK", "Done")) { focusedField = nil }
            }
        }
        .tint(DS.accentEmphasis)
        .errorAlert(connectionError)
        .confirmationDialog(
            L("Effacer la configuration kDrive ?", "Clear kDrive configuration?"),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Effacer", "Clear"), role: .destructive) {
                focusedField = nil
                token = ""
                driveId = ""
                directoryId = "1"
                directoryName = ""
                connectionStatus = nil
                connectionError = nil
            }
            Button(L("Annuler", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("Le token API, l’ID du Drive et le dossier cible seront supprimés de cet appareil.", "The API token, Drive ID, and target folder will be removed from this device."))
        }
        .task(id: rateLimit.limitedUntil) {
            now = Date()
            guard let until = rateLimit.limitedUntil else { return }
            while !Task.isCancelled && until > Date() {
                try? await Task.sleep(for: .seconds(15))
                now = Date()
            }
        }
        .onChange(of: token) { _, _ in connectionStatus = nil }
        .onChange(of: driveId) { _, _ in connectionStatus = nil }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionStatus = nil
        connectionError = nil
        Task { @MainActor in
            do {
                let name = try await KDriveService.shared.testConnection(token: token, driveId: driveId)
                connectionStatus = .success(name)
            } catch {
                connectionError = error.localizedDescription
            }
            isTestingConnection = false
        }
    }
}

private struct KDrivePathNode: Identifiable, Equatable {
    let id: String
    let name: String
}

struct KDriveFolderPickerView: View {
    let token: String
    let driveId: String
    @Binding var directoryId: String
    @Binding var directoryName: String
    let dismissOnSelection: Bool
    let onChoose: ((String, String) -> Void)?
    /// `true` quand le sélecteur est poussé via NavigationLink (Réglages) :
    /// pas de NavigationStack interne et pas de bouton Annuler (Retour suffit).
    let embeddedInNavigationStack: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var pathStack: [KDrivePathNode] = []
    @State private var folders: [KDriveFolderItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateFolder = false
    @State private var newFolderName = ""

    init(
        token: String,
        driveId: String,
        directoryId: Binding<String>,
        directoryName: Binding<String>,
        dismissOnSelection: Bool = true,
        onChoose: ((String, String) -> Void)? = nil,
        embeddedInNavigationStack: Bool = false
    ) {
        self.token = token
        self.driveId = driveId
        self._directoryId = directoryId
        self._directoryName = directoryName
        self.dismissOnSelection = dismissOnSelection
        self.onChoose = onChoose
        self.embeddedInNavigationStack = embeddedInNavigationStack
    }

    private var currentFolder: KDrivePathNode {
        pathStack.last ?? KDrivePathNode(id: "1", name: L("Racine", "Root"))
    }

    var body: some View {
        // Pas de NavigationStack interne : le sélecteur est poussé dans la
        // pile des Réglages (NavigationLink) ou enveloppé par l'appelant modal.
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(pathStack.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(DS.onSurfaceMuted)
                            }
                            Button(node.name) { navigateToBreadcrumb(at: index) }
                                .font(index == pathStack.count - 1 ? .subheadline.bold() : .subheadline)
                        }
                    }
                }
            }

            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: DS.space(2)) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(DS.onSurfaceMuted)
                    Button(L("Réessayer", "Retry")) { loadFolders() }
                        .tint(DS.accentEmphasis)
                }
            } else {
                if pathStack.count > 1 {
                    Button { goUpOneLevel() } label: {
                        Label(L("Dossier parent", "Parent folder"), systemImage: "arrow.turn.up.left")
                    }
                }

                if folders.isEmpty {
                    Text(L("Aucun sous-dossier ici.", "No subfolders here."))
                        .foregroundStyle(DS.onSurfaceMuted)
                } else {
                    ForEach(folders) { folder in
                        Button { enterFolder(folder) } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder.fill")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(DS.onSurfaceMuted)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(dismissOnSelection ? L("Dossier kDrive", "kDrive folder") : L("Choisir le dossier", "Choose folder"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embeddedInNavigationStack {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Annuler", "Cancel")) { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newFolderName = ""
                    showCreateFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .disabled(isLoading)
                .accessibilityLabel(L("Créer un dossier", "Create folder"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                let chosenId = currentFolder.id
                let chosenName = currentFolder.name
                directoryId = chosenId
                directoryName = chosenName
                onChoose?(chosenId, chosenName)
                if dismissOnSelection { dismiss() }
            } label: {
                Text(dismissOnSelection
                     ? L("Choisir « \(currentFolder.name) »", "Choose “\(currentFolder.name)”")
                     : L("Envoyer ici : « \(currentFolder.name) »", "Upload here: “\(currentFolder.name)”"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .padding()
            .background(.bar)
        }
        .errorAlert(errorMessage)
        .alert(L("Nouveau dossier", "New folder"), isPresented: $showCreateFolder) {
            TextField(L("Nom du dossier", "Folder name"), text: $newFolderName)
            Button(L("Annuler", "Cancel"), role: .cancel) { }
            Button(L("Créer", "Create")) { createNewFolder() }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L("Créer un sous-dossier dans « \(currentFolder.name) ».", "Create a subfolder in “\(currentFolder.name)”."))
        }
        .onAppear {
            if pathStack.isEmpty {
                if dismissOnSelection && directoryId != "1" && !directoryName.isEmpty {
                    pathStack = [
                        KDrivePathNode(id: "1", name: L("Racine", "Root")),
                        KDrivePathNode(id: directoryId, name: directoryName)
                    ]
                } else {
                    pathStack = [KDrivePathNode(id: "1", name: L("Racine", "Root"))]
                }
            }
            loadFolders()
        }
    }

    private func enterFolder(_ folder: KDriveFolderItem) {
        pathStack.append(KDrivePathNode(id: String(folder.id), name: folder.name))
        loadFolders()
    }

    private func goUpOneLevel() {
        guard pathStack.count > 1 else { return }
        pathStack.removeLast()
        loadFolders()
    }

    private func navigateToBreadcrumb(at index: Int) {
        guard index < pathStack.count else { return }
        pathStack = Array(pathStack.prefix(index + 1))
        loadFolders()
    }

    private func loadFolders() {
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            do {
                folders = try await KDriveService.shared.fetchSubdirectories(
                    token: token,
                    driveId: driveId,
                    directoryId: currentFolder.id
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func createNewFolder() {
        let cleanName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let folder = try await KDriveService.shared.createDirectory(
                    token: token,
                    driveId: driveId,
                    parentDirectoryId: currentFolder.id,
                    folderName: cleanName
                )
                pathStack.append(KDrivePathNode(id: String(folder.id), name: folder.name))
                folders = []
                loadFolders()
            } catch {
                errorMessage = L("Échec de création : \(error.localizedDescription)", "Creation failed: \(error.localizedDescription)")
                isLoading = false
            }
        }
    }
}

private struct KDriveUploadFlowSheet: View {
    let files: [URL]
    let token: String
    let driveId: String

    @State private var directoryId = "1"
    @State private var directoryName = L("Racine", "Root")
    @State private var destinationChosen = false

    var body: some View {
        Group {
            if destinationChosen {
                KDriveUploadSheet(
                    files: files,
                    token: token,
                    driveId: driveId,
                    directoryId: directoryId,
                    directoryName: directoryName
                )
            } else {
                NavigationStack {
                    KDriveFolderPickerView(
                        token: token,
                        driveId: driveId,
                        directoryId: $directoryId,
                        directoryName: $directoryName,
                        dismissOnSelection: false,
                        onChoose: { _, _ in destinationChosen = true }
                    )
                }
            }
        }
    }
}

struct KDriveUploadSheet: View {
    let files: [URL]
    let token: String
    let driveId: String
    let directoryId: String
    let directoryName: String

    @State private var service = KDriveService.shared
    @State private var rateLimit = KDriveRateLimitCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var finished = false
    @State private var successCount = 0
    @State private var failedCount = 0
    @State private var finalError: String?
    @State private var showDeleteConfirm = false
    @State private var deletedCount = 0
    @State private var deleteFailures = 0
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.space(3)) {
                ScrollView {
                    Group {
                        if finished {
                            UploadConsoleCard(
                                icon: service.wasCancelled ? "xmark.circle.fill" : (failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"),
                                iconColor: service.wasCancelled ? DS.accentEmphasis : (failedCount == 0 ? DS.accentEmphasis : DS.error),
                                title: service.wasCancelled ? L("Upload annulé", "Upload cancelled") : (failedCount == 0 ? L("Upload terminé", "Upload complete") : L("Upload terminé avec avertissements", "Upload completed with warnings")),
                                status: L("« \(directoryName) »", "“\(directoryName)”"),
                                counter: nil,
                                progress: nil,
                                stats: finishedStats,
                                summary: L("\(successCount) média(s) envoyé(s).", "\(successCount) media file(s) uploaded."))
                        } else {
                            UploadConsoleCard(
                                icon: "icloud.and.arrow.up.fill",
                                iconColor: DS.accentEmphasis,
                                title: L("Envoi vers kDrive…", "Uploading to kDrive…"),
                                status: L("« \(directoryName) »", "“\(directoryName)”"),
                                counter: "\(service.currentFileIndex) / \(max(1, service.totalFilesCount))",
                                progress: service.currentProgress,
                                stats: progressStats,
                                summary: nil)
                        }
                    }
                    .padding(.horizontal, DS.space(4))
                    .padding(.top, DS.space(2))
                }

                VStack(spacing: DS.space(2)) {
                    if !finished {
                        UploadActionButton(title: L("Annuler l'envoi", "Cancel upload"), systemImage: "xmark.circle", destructive: true) {
                            service.cancelUpload()
                        }
                    } else {
                        UploadActionButton(title: L("Fermer", "Close"), systemImage: "checkmark", prominent: true) { dismiss() }
                        if deletedCount == 0 && deleteFailures == 0 && !service.uploadedFileURLs.isEmpty {
                            UploadActionButton(title: L("Supprimer \(service.uploadedFileURLs.count) envoyés du téléphone", "Delete \(service.uploadedFileURLs.count) uploaded from device"), systemImage: "trash", destructive: true) {
                                showDeleteConfirm = true
                            }
                            .disabled(isDeleting)
                        }
                    }
                }
                .padding(.horizontal, DS.space(4))
                .padding(.bottom, DS.space(3))
            }
            .navigationTitle("Infomaniak kDrive")
            .navigationBarTitleDisplayMode(.inline)
        }
        .errorAlert(finalError)
        .presentationDetents([.large])
        .interactiveDismissDisabled(service.isUploading)
        .confirmationDialog(
            L("Supprimer les \(service.uploadedFileURLs.count) fichier(s) envoyé(s) du téléphone ?", "Delete the \(service.uploadedFileURLs.count) uploaded file(s) from the device?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Supprimer", "Delete"), role: .destructive) { deleteUploadedFiles() }
            Button(L("Annuler", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("Les fichiers envoyés avec succès seront supprimés définitivement du stockage de l'app (pas de corbeille). Ils restent bien sûr sur kDrive.", "Successfully uploaded files will be permanently removed from the app storage (no trash). They remain on kDrive."))
        }
        .onAppear { startUploadIfNeeded() }
        .task {
            while !finished {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                KDriveRateLimitCenter.shared.refreshPacingInfo()
                if started, !service.isUploading {
                    successCount = service.lastSuccessCount
                    failedCount = service.lastFailedCount
                    finished = true
                }
            }
        }
    }


    private var progressStats: [(label: String, value: String)] {
        var stats: [(label: String, value: String)] = [
            (L("Simultanés", "Concurrent"), "\(KDriveService.concurrentUploadLimit)")
        ]
        if !service.currentFileName.isEmpty {
            stats.append((L("Fichier en cours", "Current file"), service.currentFileName))
        }
        stats.append((L("API", "API"), rateLimit.apiRateLabel))
        if rateLimit.nextSlotDelay > 3 {
            stats.append((L("Cadence API", "API pacing"), "\(Int(rateLimit.nextSlotDelay.rounded())) s"))
        }
        return stats
    }

    private var finishedStats: [(label: String, value: String)] {
        var stats: [(label: String, value: String)] = []
        if failedCount > 0 {
            stats.append((L("Échecs", "Failures"), "\(failedCount)"))
        }
        if deletedCount > 0 || deleteFailures > 0 {
            stats.append((L("Supprimés du téléphone", "Deleted from phone"), "\(deletedCount)"))
        }
        return stats
    }

    private func startUploadIfNeeded() {
        guard !started else { return }
        started = true
        guard !files.isEmpty else {
            finished = true
            return
        }

        service.uploadBatch(files: files, token: token, driveId: driveId, directoryId: directoryId) { @MainActor success, failed, error in
            successCount = success
            failedCount = failed
            finalError = service.wasCancelled ? nil : error
            finished = true
        }
    }

    private func deleteUploadedFiles() {
        guard !isDeleting else { return }
        isDeleting = true
        let urls = service.uploadedFileURLs
        Task { @MainActor in
            let (deleted, failures) = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var deleted = 0
                var failures = 0
                for url in urls where fm.fileExists(atPath: url.path) {
                    do {
                        try fm.removeItem(at: url)
                        MediaMetadata.remove(for: url)
                        deleted += 1
                    } catch {
                        failures += 1
                        LogCenter.err(L("kDrive : suppression impossible de \(url.lastPathComponent) : \(error.localizedDescription)", "kDrive: could not delete \(url.lastPathComponent): \(error.localizedDescription)"))
                    }
                }
                return (deleted, failures)
            }.value
            deletedCount = deleted
            deleteFailures = failures
            isDeleting = false
            if deleted > 0 {
                // La galerie et les compteurs relisent la collection active.
                NotificationCenter.default.post(name: .rmpFilesDeletedLocally, object: nil)
            }
        }
    }
}

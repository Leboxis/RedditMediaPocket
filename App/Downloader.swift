import Foundation
import Combine
import AVFoundation
import CryptoKit
import MediaCore

struct UserCollection: Codable, Identifiable, Equatable {
    var name: String
    var isSubreddit = false
    var archived = false
    var lastRun: Date?
    /// Clé canonique : `u/pseudo` ou `r/sub`.
    var id: String { (isSubreddit ? "r/" : "u/") + name }
    var displayName: String { id }
    /// Dossier de stockage. Le point de `r.…` est interdit dans les pseudos :
    /// aucun profil existant ne peut entrer en collision avec un subreddit.
    var folderName: String { isSubreddit ? "r.\(name)" : name }

    enum CodingKeys: String, CodingKey { case name, isSubreddit, archived, lastRun }
    init(name: String, isSubreddit: Bool = false, archived: Bool = false, lastRun: Date? = nil) {
        self.name = name
        self.isSubreddit = isSubreddit
        self.archived = archived
        self.lastRun = lastRun
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isSubreddit = try container.decodeIfPresent(Bool.self, forKey: .isSubreddit) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
    }
}

@MainActor final class Downloader: ObservableObject {
    @Published var username = UserDefaults.standard.string(forKey: "lastUsername") ?? ""
    @Published var collections: [UserCollection] = []
    @Published var activeUser: String?
    @Published var running = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var files: [URL] = []
    @Published var count = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var discovered = 0
    var totalSize: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    @Published var concurrentLimit = max(1, min(6, UserDefaults.standard.object(forKey: "concurrentLimit") as? Int ?? 3)) {
        didSet { UserDefaults.standard.set(max(1, min(6, concurrentLimit)), forKey: "concurrentLimit") }
    }
    @Published private(set) var sessionLimit = 3
    /// Sélecteur de source : `u` profil, `r` subreddit. Ne s'applique qu'aux noms
    /// nus ; un texte contenant déjà `/` (ex. `r/pics` collé) garde la priorité.
    @Published var sourceKind: String = {
        let saved = UserDefaults.standard.string(forKey: "sourceKind") ?? "u"
        return saved == "r" ? "r" : "u"
    }() {
        didSet {
            let valid = sourceKind == "r" ? "r" : "u"
            if valid != sourceKind { sourceKind = valid; return }
            UserDefaults.standard.set(valid, forKey: "sourceKind")
        }
    }
    /// Source effective : le sélecteur complète les noms nus, le texte explicite gagne sinon.
    var resolvedSource: FeedSource? {
        let text = username.contains("/") ? username : "\(sourceKind)/\(username)"
        return try? FeedSource.parse(text)
    }
    @Published var subSort: String = {
        let saved = UserDefaults.standard.string(forKey: "subSort") ?? "new"
        return FeedSource.subredditSorts.contains(saved) ? saved : "new"
    }() {
        didSet {
            let valid = FeedSource.subredditSorts.contains(subSort) ? subSort : "new"
            if valid != subSort { subSort = valid; return }
            UserDefaults.standard.set(valid, forKey: "subSort")
        }
    }
    @Published var active = 0
    @Published private(set) var transfers = 0
    @Published var limitNotice = ""
    private var limitedServices: [String: Date] = [:]
    private var skipped = 0
    private let network = Network()
    private var task: Task<Void, Never>?
    private var tokenTask: Task<String, Error>?
    private var token: String?
    private var tokenDate = Date.distantPast
    private let fm = FileManager.default
    private var root: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var archivedCollections: [UserCollection] { collections.filter(\.archived) }
    var liveCollections: [UserCollection] { collections.filter { !$0.archived } }
    var activeCollection: UserCollection? { collections.first { $0.id == activeUser } }

    init() {
        network.$transfers.assign(to: &$transfers)
        loadCollections()
        migrateFolders()
        if activeUser == nil { activeUser = liveCollections.first?.id ?? collections.first?.id }
        if let current = collections.first(where: { $0.id == activeUser }) { display(current) }
        reload()
    }

    /// Affiche une collection dans le champ : nom nu + sélecteur positionné.
    private func display(_ collection: UserCollection) {
        sourceKind = collection.isSubreddit ? "r" : "u"
        username = collection.name
    }

    private func loadCollections() {
        if let data = UserDefaults.standard.data(forKey: "collections"),
           let saved = try? JSONDecoder().decode([UserCollection].self, from: data) {
            collections = saved
        }
        if let last = UserDefaults.standard.string(forKey: "lastUsername") {
            // Anciennes versions : pseudo nu sans préfixe ; versions récentes : `u/…` ou `r/…`.
            if let source = try? FeedSource.parse(last.contains("/") ? last : "u/\(last)") {
                switch source {
                case .user(let name): sourceKind = "u"; username = name
                case .subreddit(let name): sourceKind = "r"; username = name
                }
            } else {
                username = last
            }
            let canonical = last.contains("/") ? last : "u/\(last)"
            if collections.contains(where: { $0.id == canonical }) { activeUser = canonical }
        }
    }

    private func saveCollections() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: "collections")
        }
    }

    private func migrateFolders() {
        let known = Set(collections.map(\.folderName))
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        let fresh = folders.map(\.lastPathComponent).filter { !known.contains($0) && $0 != "Inbox" }.sorted()
        guard !fresh.isEmpty else { return }
        for folder in fresh {
            // Les dossiers `r.…` viennent des subreddits (le point est impossible dans un pseudo).
            if folder.hasPrefix("r."), let sub = try? FeedSource.subredditName(String(folder.dropFirst(2))) {
                collections.append(UserCollection(name: sub, isSubreddit: true))
            } else {
                collections.append(UserCollection(name: folder))
            }
        }
        saveCollections()
    }

    func selectUser(_ id: String) {
        guard !running else { return }
        guard let collection = collections.first(where: { $0.id == id }) else { return }
        activeUser = collection.id
        display(collection)
        UserDefaults.standard.set(collection.id, forKey: "lastUsername")
        reload()
    }

    func setArchived(_ id: String, _ archived: Bool) {
        guard !running, let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].archived = archived
        saveCollections()
        if collections[index].id == activeUser { reload() }
    }

    func download(user id: String) {
        guard !running else { return }
        if let collection = collections.first(where: { $0.id == id }) {
            display(collection)
        } else {
            username = id
        }
        start()
    }

    private func upsertCollection(_ source: FeedSource) {
        let id = source.id
        if let index = collections.firstIndex(where: { $0.id == id }) {
            collections[index].archived = false
        } else {
            switch source {
            case .user(let name): collections.append(UserCollection(name: name))
            case .subreddit(let name): collections.append(UserCollection(name: name, isSubreddit: true))
            }
        }
        saveCollections()
    }

    func deleteAllDownloads() {
        guard !running else { return }
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "Inbox" } ?? []
        folders.forEach { try? fm.removeItem(at: $0) }
        collections = []
        saveCollections()
        activeUser = nil
        username = ""
        UserDefaults.standard.removeObject(forKey: "lastUsername")
        status = ""
        reload()
    }

    func reload() {
        guard let activeUser, let collection = collections.first(where: { $0.id == activeUser }) else { files = []; totalBytes = 0; return }
        let folder = root.appendingPathComponent(collection.folderName, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            files = []; totalBytes = 0; return
        }
        let media = entries.filter {
            ["jpg", "jpeg", "png", "gif", "webp", "mp4", "mov"].contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        totalBytes = media.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        files = media.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    func stop() { task?.cancel(); tokenTask?.cancel() }
    func start() {
        guard !running else { return }
        sessionLimit = max(1, min(6, concurrentLimit))
        errorMessage = nil
        running = true; discovered = 0; count = 0; status = ""; limitNotice = ""; skipped = 0; limitedServices = [:]
        task = Task {
            defer { running = false; active = 0; task = nil }
            do { try await run() }
            catch {
                tokenTask?.cancel(); tokenTask = nil; token = nil
                status = Task.isCancelled || error is CancellationError ? "Arrêté" : error.localizedDescription
                if !Task.isCancelled && !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    private struct Download: Sendable {
        let media: Media
        let destination: URL
    }

    private func run() async throws {
        // Même résolution que l'aperçu UI ; l'erreur exacte (pseudo ou sub) remonte.
        let text = username.contains("/") ? username : "\(sourceKind)/\(username)"
        let source = try FeedSource.parse(text)
        let canonical = source.id
        UserDefaults.standard.set(canonical, forKey: "lastUsername")
        activeUser = canonical
        upsertCollection(source)
        reload()
        let folder = root.appendingPathComponent(source.folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var after: String?
        var visited = Set<String>()
        var seenMedia = Set<Media>()
        // Plafond de sécurité : 100 pages. Le RSS anonyme tronque de toute façon
        // bien avant (page répétée, curseur non reconnu, 429) ; voir README.
        for _ in 1...100 {
            try Task.checkCancellation()
            status = "Recherche…"
            let posts = try FeedParser.parse(try await network.data(source.feedURL(sort: subSort, after: after)))
            let fresh = posts.filter { visited.insert($0.id).inserted }
            if fresh.isEmpty { break }
            var downloads: [Download] = []
            for post in fresh {
                for item in MediaExtractor.extract(post.html) where seenMedia.insert(item).inserted {
                    let digest = SHA256.hash(data: Data(item.key.utf8)).map { String(format: "%02x", $0) }.joined()
                    let ext: String
                    if case .direct(let url) = item { ext = url.pathExtension.lowercased() } else { ext = "mp4" }
                    let destination = folder.appendingPathComponent(digest).appendingPathExtension(ext)
                    if !fm.fileExists(atPath: destination.path) { downloads.append(Download(media: item, destination: destination)) }
                }
            }
            discovered += downloads.count
            status = ""
            try await ConcurrentDownloads.run(downloads, limit: sessionLimit) { item in
                try await self.saveUnlessLimited(item)
            }
            guard let last = posts.last?.id, last.hasPrefix("t3_") else { break }
            after = last
        }
        if let index = collections.firstIndex(where: { $0.id == canonical }) {
            collections[index].lastRun = Date()
            saveCollections()
        }
        status = skipped > 0 ? "\(count) reçus · \(skipped) à reprendre" : (count == 0 ? "Aucun nouveau média accessible" : "\(count) téléchargés")
    }

    private func saveUnlessLimited(_ item: Download) async throws {
        do { try await save(item) }
        catch NetworkError.limited(let service, let until) {
            try Task.checkCancellation()
            skipped += 1
            limitedServices[service] = max(limitedServices[service] ?? .distantPast, until)
            limitNotice = limitedServices.sorted { $0.key < $1.key }.map {
                "\($0.key) · \($0.value.formatted(date: .numeric, time: .shortened))"
            }.joined(separator: " — ")
            // Keep processing the other services. Blocked requests fail locally without contacting them.
        }
    }

    private func save(_ item: Download) async throws {
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        let temporary = try await resolveAndDownload(item.media)
        defer { try? fm.removeItem(at: temporary) }
        try Task.checkCancellation()
        try fm.moveItem(at: temporary, to: item.destination)
        files.insert(item.destination, at: 0)
        totalBytes += Int64((try? item.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        count += 1
    }

    private func redgifsToken() async throws -> String {
        if let token, Date().timeIntervalSince(tokenDate) < 1800 { return token }
        if let tokenTask { return try await tokenTask.value }
        let request = Task { @MainActor in
            struct Auth: Decodable { let token: String }
            let data = try await network.data(URL(string: "https://api.redgifs.com/v2/auth/temporary")!)
            return try JSONDecoder().decode(Auth.self, from: data).token
        }
        tokenTask = request
        defer { tokenTask = nil }
        let result = try await request.value
        token = result; tokenDate = Date()
        return result
    }
    private func resolveAndDownload(_ media: Media) async throws -> URL {
        switch media {
        case .direct(let url): return try await network.download(url)
        case .redgifs(let id):
            let bearer = try await redgifsToken()
            struct Response: Decodable { struct Gif: Decodable { struct URLs: Decodable { let hd: URL?; let sd: URL? }; let urls: URLs }; let gif: Gif }
            let data = try await network.data(URL(string: "https://api.redgifs.com/v2/gifs/\(id)")!, bearer: bearer)
            let urls = try JSONDecoder().decode(Response.self, from: data).gif.urls
            guard let url = QualityPolicy.redgifsURL(hd: urls.hd, sd: urls.sd), let host = url.host, host == "redgifs.com" || host.hasSuffix(".redgifs.com") else { throw NetworkError.invalid("Média RedGIFs indisponible.") }
            return try await network.download(url)
        case .redditVideo(let base):
            let manifest = base.appendingPathComponent("DASHPlaylist.mpd")
            let tracks = try DASHParser.parse(try await network.data(manifest), relativeTo: manifest)
            guard tracks.video.host == base.host, tracks.audio == nil || tracks.audio?.host == base.host else { throw NetworkError.invalid("Manifest vidéo inattendu.") }
            let video = try await network.download(tracks.video)
            guard let audioURL = tracks.audio else { return video }
            defer { try? fm.removeItem(at: video) }
            let audio = try await network.download(audioURL)
            defer { try? fm.removeItem(at: audio) }
            return try await merge(video: video, audio: audio)
        }
    }
    private func merge(video: URL, audio: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let sourceV = try await v.loadTracks(withMediaType: .video).first,
              let sourceA = try await a.loadTracks(withMediaType: .audio).first,
              let targetV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let targetA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NetworkError.invalid("Pistes vidéo/audio illisibles.") }
        let durationV = try await v.load(.duration), durationA = try await a.load(.duration)
        try targetV.insertTimeRange(CMTimeRange(start: .zero, duration: durationV), of: sourceV, at: .zero)
        try targetA.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(durationV, durationA)), of: sourceA, at: .zero)
        targetV.preferredTransform = try await sourceV.load(.preferredTransform)
        let output = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw NetworkError.invalid("Assemblage vidéo indisponible.") }
        export.outputURL = output; export.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in export.exportAsynchronously { continuation.resume() } }
        guard export.status == .completed else { try? fm.removeItem(at: output); throw export.error ?? NetworkError.invalid("Échec de l’assemblage vidéo.") }
        if Task.isCancelled { try? fm.removeItem(at: output); throw CancellationError() }
        return output
    }
}

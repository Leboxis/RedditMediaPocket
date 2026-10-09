import Foundation
import Combine
import AVFoundation
import CryptoKit
import ImageIO
import MediaCore

struct UserCollection: Codable, Identifiable, Equatable {
    var name: String
    var isSubreddit = false
    var isSaved = false
    var isXFetish = false
    var isRedGifs = false
    var isTwitter = false
    var archived = false
    var lastRun: Date?
    /// Clé canonique : `u/pseudo`, `r/sub`, `saved/pseudo`, `x/profil`,
    /// `rg/pseudo` ou `tw/pseudo`.
    var id: String {
        if isTwitter { return "tw/\(name)" }
        if isRedGifs { return "rg/\(name)" }
        if isSaved { return "saved/\(name)" }
        if isXFetish { return "x/\(name)" }
        return (isSubreddit ? "r/" : "u/") + name
    }
    var displayName: String { isSaved ? "Saved" : id }
    /// Dossier de stockage. Les points de `r.…`, `saved.…`, `x.…`,
    /// `redgifs.…` et `tw.…` sont interdits dans les pseudos : aucune
    /// collection existante ne peut entrer en collision.
    var folderName: String {
        if isTwitter { return "tw.\(name)" }
        if isRedGifs { return "redgifs.\(name)" }
        if isSaved { return "saved.\(name)" }
        if isXFetish { return "x.\(name)" }
        return isSubreddit ? "r.\(name)" : name
    }

    enum CodingKeys: String, CodingKey { case name, isSubreddit, isSaved, isXFetish, isRedGifs, isTwitter, archived, lastRun }
    init(name: String, isSubreddit: Bool = false, isSaved: Bool = false, isXFetish: Bool = false, isRedGifs: Bool = false, isTwitter: Bool = false, archived: Bool = false, lastRun: Date? = nil) {
        self.name = name
        self.isSubreddit = isSubreddit
        self.isSaved = isSaved
        self.isXFetish = isXFetish
        self.isRedGifs = isRedGifs
        self.isTwitter = isTwitter
        self.archived = archived
        self.lastRun = lastRun
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isSubreddit = try container.decodeIfPresent(Bool.self, forKey: .isSubreddit) ?? false
        isSaved = try container.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
        isXFetish = try container.decodeIfPresent(Bool.self, forKey: .isXFetish) ?? false
        isRedGifs = try container.decodeIfPresent(Bool.self, forKey: .isRedGifs) ?? false
        isTwitter = try container.decodeIfPresent(Bool.self, forKey: .isTwitter) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
    }
}

struct SavedMediaCount: Codable {
    let count: Int
    let computedAt: Date
}

@MainActor final class Downloader: ObservableObject {
    @Published var username = UserDefaults.standard.string(forKey: "lastUsername") ?? ""
    @Published var collections: [UserCollection] = []
    @Published var activeUser: String?
    @Published var running = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var files: [URL] = []
    @Published private(set) var loadingFiles = false
    @Published var count = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var discovered = 0
    /// Avancé de l'unité de téléchargement en cours : un album, ou une page de
    /// vidéos. X-Fetish n'annonce aucun total global et le parcours en découvre
    /// en continu, donc la barre ne porte pas sur le profil mais sur une unité
    /// dont le nombre de médias est connu : elle est exacte, pas estimée, et le
    /// compteur « repérés » garde son sens propre.
    struct TransferUnit: Equatable {
        var done = 0
        var total = 0
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }
    @Published private(set) var transferUnit: TransferUnit?
    var totalSize: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    private static func savedMediaCountKey(_ canonical: String) -> String { "savedMediaCount.\(canonical)" }

    static func savedMediaCount(for canonical: String) -> SavedMediaCount? {
        guard let data = UserDefaults.standard.data(forKey: savedMediaCountKey(canonical)) else { return nil }
        return try? JSONDecoder().decode(SavedMediaCount.self, from: data)
    }

    static func clearSavedMediaCount(for canonical: String) {
        UserDefaults.standard.removeObject(forKey: savedMediaCountKey(canonical))
    }
    @Published var concurrentLimit = max(1, min(6, UserDefaults.standard.object(forKey: "concurrentLimit") as? Int ?? 3)) {
        didSet { UserDefaults.standard.set(max(1, min(6, concurrentLimit)), forKey: "concurrentLimit") }
    }
    @Published private(set) var sessionLimit = 3
    /// Sélecteur de source : `u` profil, `r` subreddit, `rg` compte RedGifs,
    /// `saved` éléments sauvegardés du compte connecté,
    /// `x` albums publics d'un profil X-Fetish,
    /// `tw` médias publics d'un compte X.
    /// Le cœur ignore la saisie ; pour u/, r/ et rg/, un texte contenant
    /// déjà `/` ou une URL RedGifs garde la priorité.
    @Published var sourceKind: String = {
        let saved = UserDefaults.standard.string(forKey: "sourceKind") ?? "u"
        return SourceKind(rawValue: saved) == nil ? "u" : saved
    }() {
        didSet {
            let valid = SourceKind(rawValue: sourceKind) == nil ? "u" : sourceKind
            if valid != sourceKind { sourceKind = valid; return }
            UserDefaults.standard.set(valid, forKey: "sourceKind")
        }
    }
    /// Source effective : le sélecteur complète les noms nus, le texte explicite gagne sinon.
    var resolvedSource: FeedSource? {
        if sourceKind == "saved" { return nil }
        // `tw` accepte `@pseudo` et une adresse `x.com/pseudo` collée telle
        // quelle ; le préfixe ne doit pas être ajouté dans ces cas.
        if sourceKind == "tw" {
            let text = username.contains("/") || username.hasPrefix("@") ? username : "tw/\(username)"
            return try? FeedSource.parse(text)
        }
        if sourceKind == "rg" {
            let text = username.contains("/") || username.lowercased().contains("redgifs.com") ? username : "rg/\(username)"
            return try? FeedSource.parse(text)
        }
        let text = username.contains("/") ? username : "\(sourceKind)/\(username)"
        return try? FeedSource.parse(text)
    }

    /// Vrai quand la source effective exige une session du service concerné.
    var needsSession: Bool {
        if sourceKind == "saved" { return true }
        if let source = resolvedSource {
            switch source {
            case .saved, .twitterUser: return true
            default: return false
            }
        }
        // Champ vide/invalide : le sélecteur X conserve son aide de connexion.
        return sourceKind == "tw"
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
    /// Médias X-Fetish retenus : images d'album seules (défaut historique),
    /// vidéos seules, ou les deux. `x/nom` reste une seule collection : le
    /// dossier et le dossier kDrive ne changent pas.
    @Published var xFetishMediaKind: XFetishMediaKind = {
        guard let raw = UserDefaults.standard.string(forKey: XFetishMediaKind.defaultsKey),
              let kind = XFetishMediaKind(rawValue: raw) else { return .images }
        return kind
    }() {
        didSet {
            let valid = XFetishMediaKind(rawValue: xFetishMediaKind.rawValue) ?? .images
            if valid != xFetishMediaKind { xFetishMediaKind = valid; return }
            UserDefaults.standard.set(valid.rawValue, forKey: XFetishMediaKind.defaultsKey)
        }
    }
    @Published var active = 0
    @Published private(set) var transfers = 0
    private var failed = 0
    private let network = Network()
    private let previewCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()
    private var previewSessionRevision = -1
    private var task: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var reloadRevision = 0
    private var displayedCollectionID: String?
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
        Self.cleanupStalePreviewTemps()
        if activeUser == nil { activeUser = liveCollections.first?.id ?? collections.first?.id }
        if let current = collections.first(where: { $0.id == activeUser }) { display(current) }
        reload()
    }

    /// Décision Jev A bug 12 : carnet + ménage. Les aperçus oubliés (quitte au
    /// mauvais moment) sont nettoyés au démarrage : fichiers temporaires de
    /// plus de 24h dans le dossier temporaire.
    nonisolated static func cleanupStalePreviewTemps() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let limit = Date().addingTimeInterval(-24 * 3600)
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "gif", "webp"].contains(ext) else { continue }
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date < limit {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Affiche une collection dans le champ : nom nu + sélecteur positionné.
    private func display(_ collection: UserCollection) {
        if collection.isSaved { sourceKind = "saved" }
        else if collection.isTwitter { sourceKind = "tw" }
        else if collection.isXFetish { sourceKind = "x" }
        else if collection.isRedGifs { sourceKind = "rg" }
        else if collection.isSubreddit { sourceKind = "r" }
        else { sourceKind = "u" }
        username = collection.name
    }

    private func loadCollections() {
        if let data = UserDefaults.standard.data(forKey: "collections"),
           let saved = try? JSONDecoder().decode([UserCollection].self, from: data) {
            collections = saved.map {
                var collection = $0
                collection.archived = false
                return collection
            }
            if saved.contains(where: \.archived) { saveCollections() }
        }
        if let last = UserDefaults.standard.string(forKey: "lastUsername") {
            // Anciennes versions : pseudo nu sans préfixe ; versions récentes :
            // `u/…`, `r/…`, `rg/…`, `x/…`, `tw/…` ou URL d'hébergeur.
            if let source = try? FeedSource.parse(last.contains("/") || last.lowercased().contains("redgifs.com") ? last : "u/\(last)") {
                switch source {
                case .user(let name): sourceKind = "u"; username = name
                case .subreddit(let name): sourceKind = "r"; username = name
                case .saved(let name): sourceKind = "saved"; username = name
                case .xFetish(let name): sourceKind = "x"; username = name
                case .redgifsUser(let name): sourceKind = "rg"; username = name
                case .twitterUser(let name): sourceKind = "tw"; username = name
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
            // Les dossiers `r.…`, `saved.…`, `x.…`, `redgifs.…` et `tw.…` viennent
            // des subreddits, sauvegardés, profils X-Fetish, comptes RedGifs et
            // comptes X (le point est impossible dans un pseudo).
            if folder.hasPrefix("r."), let sub = try? FeedSource.subredditName(String(folder.dropFirst(2))) {
                collections.append(UserCollection(name: sub, isSubreddit: true))
            } else if folder.hasPrefix("redgifs."), let owner = try? RedgifsAPI.username(String(folder.dropFirst(8))) {
                collections.append(UserCollection(name: owner, isRedGifs: true))
            } else if folder.hasPrefix("saved."), let owner = try? MediaExtractor.username(String(folder.dropFirst(6))) {
                collections.append(UserCollection(name: owner, isSaved: true))
            } else if folder.hasPrefix("x."), let model = try? XFetishAlbums.modelName(String(folder.dropFirst(2))) {
                collections.append(UserCollection(name: model, isXFetish: true))
            } else if folder.hasPrefix("tw."), let handle = try? XTwitterAPI.username(String(folder.dropFirst(3))) {
                collections.append(UserCollection(name: handle, isTwitter: true))
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

    func download(user id: String) {
        guard !running else { return }
        if let collection = collections.first(where: { $0.id == id }) {
            display(collection)
        } else if let source = try? FeedSource.parse(id) {
            switch source {
            case .user(let name): sourceKind = "u"; username = name
            case .subreddit(let name): sourceKind = "r"; username = name
            case .saved(let name): sourceKind = "saved"; username = name
            case .xFetish(let name): sourceKind = "x"; username = name
            case .redgifsUser(let name): sourceKind = "rg"; username = name
            case .twitterUser(let name): sourceKind = "tw"; username = name
            }
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
            case .saved(let name): collections.append(UserCollection(name: name, isSaved: true))
            case .xFetish(let name): collections.append(UserCollection(name: name, isXFetish: true))
            case .redgifsUser(let name): collections.append(UserCollection(name: name, isRedGifs: true))
            case .twitterUser(let name): collections.append(UserCollection(name: name, isTwitter: true))
            }
        }
        saveCollections()
    }

    func deleteDownloads(for id: String) {
        guard !running, let collection = collections.first(where: { $0.id == id }) else { return }

        let folder = root.appendingPathComponent(collection.folderName, isDirectory: true)
        try? fm.removeItem(at: folder)
        // Purge l'historique : sans ça, ré-ajouter la source après suppression
        // ne re-téléchargerait rien (posts déjà marqués vus).
        UserDefaults.standard.removeObject(forKey: Self.visitedKey(id))
        UserDefaults.standard.removeObject(forKey: Self.cursorKey(id))
        UserDefaults.standard.removeObject(forKey: Self.frontierKey(id))
        collections.removeAll { $0.id == id }
        saveCollections()

        guard activeUser == id else { return }
        if let next = liveCollections.first ?? collections.first {
            activeUser = next.id
            display(next)
            UserDefaults.standard.set(next.id, forKey: "lastUsername")
        } else {
            activeUser = nil
            username = ""
            UserDefaults.standard.removeObject(forKey: "lastUsername")
        }
        status = ""
        reload()
    }

    func deleteMedia(_ url: URL) {
        guard !running, let collection = activeCollection, files.contains(url) else { return }
        let folder = root.appendingPathComponent(collection.folderName, isDirectory: true).standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == folder,
              (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({
                  $0.isRegularFile == true && $0.isSymbolicLink != true
              }) == true else { return }
        do {
            try fm.removeItem(at: url)
            MediaMetadata.remove(for: url)
            reload()
        } catch {
            errorMessage = L("Impossible de supprimer ce média : \(error.localizedDescription)", "Unable to delete this media: \(error.localizedDescription)")
        }
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
        reloadTask?.cancel()
        reloadRevision += 1
        let revision = reloadRevision
        if displayedCollectionID != activeUser {
            files = []
            totalBytes = 0
            displayedCollectionID = activeUser
        }
        guard let collection = activeCollection else {
            files = []; totalBytes = 0; reloadTask = nil
            loadingFiles = false
            return
        }
        loadingFiles = true
        let folder = root.appendingPathComponent(collection.folderName, isDirectory: true)
        reloadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try CollectionFiles.scan(folder)
            }
            do {
                let snapshot = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.reloadRevision == revision else { return }
                self.reloadTask = nil
                self.loadingFiles = false
                self.files = snapshot.files
                self.totalBytes = snapshot.totalBytes
            } catch is CancellationError {
                return
            } catch {
                LogCenter.err(L("Galerie illisible : \(error.localizedDescription)", "Gallery unreadable: \(error.localizedDescription)"))
                guard let self, self.reloadRevision == revision else { return }
                self.reloadTask = nil
                self.loadingFiles = false
                return
            }
        }
    }

    func stop() {
        LogCenter.info(L("Arrêt demandé.", "Stop requested."))
        task?.cancel()
        tokenTask?.cancel()
        tokenTask = nil
    }
    func start() {
        guard !running else { return }
        sessionLimit = max(1, min(6, concurrentLimit))
        errorMessage = nil
        let target = sourceKind == "saved" ? "saved/" : "\(sourceKind)/\(username)"
        let started = Date()
        LogCenter.info(L("Démarrage : \(target), \(sessionLimit) transferts simultanés.", "Starting: \(target), \(sessionLimit) simultaneous transfers."))
        // Relance manuelle : on oublie les pauses enregistrées et on retente
        // vraiment le serveur au lieu de bloquer en local.
        network.resetRateLimits()
        running = true; discovered = 0; count = 0; status = ""; failed = 0
        transferUnit = nil
        task = Task {
            defer { running = false; active = 0; task = nil }
            do {
                try await run()
                LogCenter.info(L("Parcours terminé : \(count) téléchargés, \(failed) ignorés en \(Int(Date().timeIntervalSince(started))) s.", "Run finished: \(count) downloaded, \(failed) skipped in \(Int(Date().timeIntervalSince(started))) s."))
            }
            catch {
                tokenTask?.cancel(); tokenTask = nil; token = nil
                if Task.isCancelled || DownloadFailurePolicy.isCancellation(error) {
                    status = L("Arrêté", "Stopped")
                    LogCenter.info(L("Parcours arrêté après \(Int(Date().timeIntervalSince(started))) s : \(count) fichiers conservés pendant cette session.", "Run stopped after \(Int(Date().timeIntervalSince(started))) s: \(count) files kept during this run."))
                } else {
                    status = ""
                    LogCenter.err(L("Parcours interrompu après \(Int(Date().timeIntervalSince(started))) s (\(count) conservés, \(failed) ignorés) : \(error.localizedDescription)", "Run failed after \(Int(Date().timeIntervalSince(started))) s (\(count) kept, \(failed) skipped): \(error.localizedDescription)"))
                    // Count the collection on disk, including earlier runs,
                    // rather than the counter reset at every manual restart.
                    let kept = activeCollection.flatMap {
                        try? CollectionFiles.scan(root.appendingPathComponent($0.folderName, isDirectory: true)).files.count
                    } ?? files.count
                    errorMessage = error.localizedDescription + "\n" + L("\(kept) médias conservés.", "\(kept) media files kept.")
                }
            }
        }
    }

    /// Comptes suivis du compte connecté, extraits de la page privée
    /// `prefs/friends`. Le compte connecté lui-même (détecté via `prefs/feeds`)
    /// est exclu ; si cette détection échoue, la liste brute est conservée.
    func followedUsers() async throws -> [String] {
        LogCenter.net(L("Lecture des comptes suivis…", "Reading followed accounts…"))
        await RedditSession.shared.refresh()
        guard RedditSession.shared.hasSession else { throw FeedError.loginRequired }
        do {
            async let friendsData = network.data(URL(string: "https://old.reddit.com/prefs/friends/")!)
            async let feedsData = network.data(URL(string: "https://old.reddit.com/prefs/feeds/")!)
            let friendsHTML = String(decoding: try await friendsData, as: UTF8.self)
            let own = (try? SavedFeed(preferencesHTML: String(decoding: try await feedsData, as: UTF8.self)))?.username
            try Task.checkCancellation()
            let names = FriendsFeed.parse(friendsHTML)
            LogCenter.info(L("Comptes suivis : \(names.count) trouvés.", "Followed accounts: \(names.count) found."))
            guard let own else { return names }
            return names.filter { $0.caseInsensitiveCompare(own) != .orderedSame }
        } catch NetworkError.refused(let code) where code == 401 || code == 403 {
            throw NetworkError.invalid(L("Reddit refuse l’accès aux comptes suivis (HTTP \(code)). Vérifie la session dans les Réglages, puis relance.", "Reddit denied access to followed accounts (HTTP \(code)). Check your session in Settings, then try again."))
        }
    }

    /// Aperçu en lecture seule des posts publics d'un profil (RSS), sans
    /// aucun téléchargement.
    func previewPosts(username: String) async throws -> [Post] {
        let source = FeedSource.user(try MediaExtractor.username(username))
        let body = try await network.data(source.feedURL())
        try Task.checkCancellation()
        return try FeedParser.parse(body)
    }

    func previewSavedPosts() async throws -> [Post] {
        LogCenter.info(L("Aperçu des sauvegardés…", "Previewing saved posts…"))
        let feed = try await network.savedFeed()
        try Task.checkCancellation()
        let posts = try await network.savedPosts(feed, after: nil)
        LogCenter.info(L("Aperçu sauvegardés : \(posts.count) posts.", "Saved preview: \(posts.count) posts."))
        return posts
    }

    func previewImageData(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let revision = RedditSession.shared.revision
        if previewSessionRevision != revision {
            previewCache.removeAllObjects()
            previewSessionRevision = revision
        }
        if let cached = previewCache.object(forKey: url as NSURL) { return cached as Data }
        let data = try await network.data(url)
        try Task.checkCancellation()
        // Do not let a response from an earlier session populate the current cache.
        if RedditSession.shared.revision == revision, data.count <= 4 * 1024 * 1024 {
            previewCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        }
        return data
    }

    private var galleryCache: [String: [Media]] = [:]
    private var galleryCacheRevision = -1

    /// Médias d'un carrousel : le RSS n'expose que la couverture, la liste
    /// ordonnée vient du JSON du post (mise en cache par session).
    func previewGalleryMedia(feedID: String, galleryID: String? = nil) async throws -> [Media] {
        let revision = RedditSession.shared.revision
        if revision != galleryCacheRevision { galleryCache.removeAll(); galleryCacheRevision = revision }
        if let cached = galleryCache[feedID] { return cached }
        var media = try await galleryMedia(feedID: feedID)
        // Galerie crosspostée ou lien galerie distinct du post : second essai
        // sur l'identifiant de page galerie exposé par le RSS.
        let postID = feedID.hasPrefix("t3_") ? String(feedID.dropFirst(3)) : feedID
        if media.isEmpty, let galleryID, galleryID != postID {
            media = try await galleryMedia(feedID: galleryID)
        }
        // Do not let a response from an earlier session populate the current cache.
        guard RedditSession.shared.revision == revision else { return media }
        if galleryCache.count >= 50 { galleryCache.removeAll() }
        galleryCache[feedID] = media
        return media
    }

    private func galleryMedia(feedID: String) async throws -> [Media] {
        guard let url = GalleryFeed.commentsJSONURL(feedID: feedID) else { return [] }
        return try GalleryFeed.parse(try await network.data(url))
    }

    /// Résout chaque média en original temporaire, dans l'ordre, avec une
    /// concurrence bornée ; l'échec d'un média ne bloque pas les autres et la
    /// position de chaque résultat reste alignée sur la liste demandée.
    func previewMediaList(_ media: [Media]) async throws -> [URL?] {
        guard !media.isEmpty else { return [] }
        LogCenter.net(L("Aperçu : résolution de \(media.count) médias…", "Preview: resolving \(media.count) media…"))
        var slots = [URL?](repeating: nil, count: media.count)
        var failure: String?
        var next = 0
        try await withThrowingTaskGroup(of: (Int, URL?, String?).self) { group in
            func enqueue(until limit: Int) {
                while next < min(limit, media.count) {
                    let index = next
                    next += 1
                    group.addTask {
                        do { return (index, try await self.resolveAndDownload(media[index]), nil) }
                        catch is CancellationError { return (index, nil, nil) }
                        catch { return (index, nil, error.localizedDescription) }
                    }
                }
            }
            enqueue(until: 3)
            for try await (index, url, error) in group {
                if let url { slots[index] = url }
                else if let error { failure = failure ?? error }
                enqueue(until: next + 1)
            }
        }
        if Task.isCancelled {
            for url in slots.compactMap({ $0 }) { try? fm.removeItem(at: url) }
            throw CancellationError()
        }
        // Un échec partiel est toléré : le lecteur ouvre avec les médias obtenus.
        let got = slots.compactMap({ $0 }).count
        LogCenter.net(L("Aperçu résolu : \(got)/\(media.count) prêts.", "Preview resolved: \(got)/\(media.count) ready."))
        if let failure, got == 0 { LogCenter.err(failure) }
        guard got > 0 else {
            throw NetworkError.invalid(failure ?? L("Média indisponible.", "Media unavailable."))
        }
        return slots
    }

    private struct Download: Sendable {
        let media: Media
        let destination: URL
        let postDate: Date?
        let author: String
        let postLink: String?
        let headers: [String: String]?
    }

    private func run() async throws {
        let source: FeedSource
        let privateFeed: SavedFeed?
        if sourceKind == "saved" {
            status = L("Recherche des sauvegardés du compte connecté…", "Finding saved posts for the signed-in account…")
            let feed = try await network.savedFeed()
            try Task.checkCancellation()
            source = .saved(feed.username)
            privateFeed = feed
        } else {
            // `@pseudo` et `x.com/pseudo` collés tels quels sont acceptés : le préfixe
            // ne doit pas être ajouté devant, sans quoi le pseudo serait
            // invalide.
            let needsPrefix = !username.contains("/") && !username.hasPrefix("@")
                && !username.lowercased().contains("redgifs.com")
            let text = needsPrefix ? "\(sourceKind)/\(username)" : username
            source = try FeedSource.parse(text)
            if case .saved(let name) = source {
                status = L("Vérification du compte et du flux privé…", "Checking account and private feed…")
                privateFeed = try await network.savedFeed(username: name)
            } else { privateFeed = nil }
        }
        let canonical = source.id
        UserDefaults.standard.set(canonical, forKey: "lastUsername")
        activeUser = canonical
        upsertCollection(source)
        reload()
        let folder = root.appendingPathComponent(source.folderName, isDirectory: true)
        // Durcissement : dossier absent ou vide (suppression hors app) → l'historique
        // des posts vus est obsolète, on le purge pour que le run re-télécharge tout.
        if (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.isEmpty ?? true {
            LogCenter.info(L("Dossier absent ou vide : reprise précédente effacée.", "Folder missing or empty: previous checkpoint cleared."))
            UserDefaults.standard.removeObject(forKey: Self.visitedKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.cursorKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.frontierKey(canonical))
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if case .xFetish(let model) = source {
            try await runXFetish(model: model, canonical: canonical, folder: folder)
            return
        }
        // Comptes X : fil `/media` authentifié, sans RSS et sans curseur — le
        // dédoublonnage vient des noms de fichiers. Le chemin est branched avant
        // la reprise RSS, dont la migration v2 est sans objet ici.
        if case .twitterUser(let handle) = source {
            var seenMedia = Set<Media>()
            var usedFilenames = Set<String>()
            var preparedCount = 0
            let completed = try await runTwitter(username: handle, canonical: canonical,
                                                 folder: folder, seenMedia: &seenMedia,
                                                 usedFilenames: &usedFilenames,
                                                 preparedCount: &preparedCount)
            // Le plafond de pages n'est pas repris au curseur : relancer relit le
            // fil depuis le début, ce qui ne coûte que des appels API puisque
            // les médias déjà sur disque sont écartés.
            if !completed {
                status = L("Parcours incomplet : profil plus long que 100 pages de médias. Relance pour couvrir la suite.", "Scan incomplete: profile is longer than 100 media pages. Relaunch to cover the rest.")
            }
            return
        }
        // Older versions swallowed media 429s and marked incomplete pages as
        // visited. Re-scan once; existing files are skipped by prepareDownloads.
        let migrationKey = "resumePolicyVersion.\(canonical)"
        if UserDefaults.standard.integer(forKey: migrationKey) < 2 {
            LogCenter.info(L("Migration de reprise : ancien historique effacé pour revérifier les médias.", "Checkpoint migration: old history cleared to recheck media."))
            UserDefaults.standard.removeObject(forKey: Self.visitedKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.cursorKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.frontierKey(canonical))
            UserDefaults.standard.set(2, forKey: migrationKey)
        }
        var seenMedia = Set<Media>()
        var usedFilenames = Set<String>()
        var preparedCount = 0
        // Comptes RedGifs : pagination numérique de l'API search, pas de RSS.
        // La meilleure qualité (HD puis SD) passe par le chemin existant
        // `downloadRedgifs(id:)` ; le listing ne sert qu'à recenser les IDs.
        if case .redgifsUser(let rgName) = source {
            let visited = UserDefaults.standard.stringArray(forKey: Self.visitedKey(canonical)) ?? []
            LogCenter.info(L("Dossier : \(source.folderName), \(visited.count) déjà vus.", "Folder: \(source.folderName), \(visited.count) seen."))
            let completed = try await runRedgifsUser(
                username: rgName, canonical: canonical, folder: folder,
                seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                preparedCount: &preparedCount)
            if let index = collections.firstIndex(where: { $0.id == canonical }) {
                collections[index].lastRun = Date()
                saveCollections()
            }
            if !completed {
                status = L("Parcours incomplet — relance pour continuer", "Scan incomplete — relaunch to continue")
            } else if failed == 0 {
                status = count == 0 ? L("Aucun nouveau média accessible", "No new accessible media") : L("\(count) téléchargés", "\(count) downloaded")
            }
            if failed > 0 {
                let kept = (try? CollectionFiles.scan(folder).files.count) ?? files.count
                errorMessage = L("\(failed) médias inaccessibles ou non enregistrés (le plus souvent supprimés par leur hébergeur).\n\(kept) médias conservés.",
                                 "\(failed) media files unavailable or unsaved (most often deleted by their host).\n\(kept) media files kept.")
            }
            return
        }
        let checkpoint = FeedCheckpoint(
            cursor: UserDefaults.standard.string(forKey: Self.cursorKey(canonical)),
            frontier: UserDefaults.standard.string(forKey: Self.frontierKey(canonical)),
            visited: UserDefaults.standard.stringArray(forKey: Self.visitedKey(canonical)) ?? []
        )
        LogCenter.info(L("Dossier : \(source.folderName), \(checkpoint.visited.count) déjà vus, curseur \(checkpoint.cursor ?? "début"), frontière \(checkpoint.frontier ?? "aucune").", "Folder: \(source.folderName), \(checkpoint.visited.count) seen, cursor \(checkpoint.cursor ?? "start"), frontier \(checkpoint.frontier ?? "none")."))
        var pageNumber = 0
        let completed = try await FeedTraversal.run(checkpoint: checkpoint,
            validCursor: { Self.validPageCursor($0, privateFeed: privateFeed) },
            fetch: { after in
                self.status = L("Recherche…", "Searching…")
                pageNumber += 1
                let shownAfter = after.map { String($0.suffix(8)) } ?? "début"
                LogCenter.net(L("Page \(pageNumber) demandée après \(shownAfter)…", "Page \(pageNumber) requested after \(shownAfter)…"))
                let posts: [Post]
                do {
                    posts = try await self.fetchPosts(source: source, privateFeed: privateFeed, after: after)
                } catch {
                    if !(error is CancellationError) {
                        LogCenter.err(L("Page \(pageNumber) interrompue après \(shownAfter) : \(error.localizedDescription). Reprise conservée au dernier point validé.", "Page \(pageNumber) failed after \(shownAfter): \(error.localizedDescription). Checkpoint kept at the last completed page."))
                    }
                    throw error
                }
                LogCenter.net(L("Page \(pageNumber) reçue : \(posts.count) posts.", "Page \(pageNumber) received: \(posts.count) posts."))
                return posts
            }, process: { posts in
                LogCenter.info(L("Page \(pageNumber) : préparation de \(posts.count) posts…", "Page \(pageNumber): preparing \(posts.count) posts…"))
                let downloads = try await self.prepareDownloads(posts, folder: folder,
                    seenMedia: &seenMedia, usedFilenames: &usedFilenames, author: canonical)
                LogCenter.info(L("Page \(pageNumber) : \(downloads.count) nouveaux médias à prendre.", "Page \(pageNumber): \(downloads.count) new media to fetch."))
                try await self.executeDownloads(downloads, &preparedCount)
                LogCenter.info(L("Page \(pageNumber) terminée : total préparé \(preparedCount).", "Page \(pageNumber) done: total prepared \(preparedCount)."))
            }, persist: { state in
                Self.persistResumeState(canonical: canonical, cursor: state.cursor, visited: state.visited)
                Self.persistFrontier(canonical, state.frontier)
                LogCenter.info(L("Point de reprise : curseur \(state.cursor.map { String($0.suffix(8)) } ?? "fin"), frontière \(state.frontier.map { String($0.suffix(8)) } ?? "aucune"), \(state.visited.count) vus.", "Checkpoint: cursor \(state.cursor.map { String($0.suffix(8)) } ?? "end"), frontier \(state.frontier.map { String($0.suffix(8)) } ?? "none"), \(state.visited.count) seen."))
            }, trace: { LogCenter.info($0) })
        LogCenter.info(L("Parcours des pages : \(pageNumber) lues, \(completed ? "complet" : "limite atteinte"), \(preparedCount) médias préparés.", "Page scan: \(pageNumber) read, \(completed ? "complete" : "limit reached"), \(preparedCount) media prepared."))
        if completed, sourceKind == "saved", let index = collections.firstIndex(where: { $0.id == canonical }), collections[index].isSaved {
            let snapshot = SavedMediaCount(count: preparedCount, computedAt: Date())
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.savedMediaCountKey(canonical))
            }
        }
        if let index = collections.firstIndex(where: { $0.id == canonical }) {
            collections[index].lastRun = Date()
            saveCollections()
        }
        if !completed {
            status = L("Parcours incomplet — relance pour continuer", "Scan incomplete — relaunch to continue")
        } else if failed == 0 {
            status = count == 0 ? L("Aucun nouveau média accessible", "No new accessible media") : L("\(count) téléchargés", "\(count) downloaded")
        }
        if failed > 0 {
            status = ""
            let kept = (try? CollectionFiles.scan(folder).files.count) ?? files.count
            errorMessage = L("\(failed) médias inaccessibles ou non enregistrés (le plus souvent supprimés par leur hébergeur).\n\(kept) médias conservés.",
                             "\(failed) media files unavailable or unsaved (most often deleted by their host).\n\(kept) media files kept.")
        }
    }

    /// X-Fetish has no RSS cursor. Rescan every public page on each run so new
    /// media in an older album or a new video is found; stable `xf-…` / `xfv-…`
    /// keys skip the files already on disk.
    private func runXFetish(model: String, canonical: String, folder: URL) async throws {
        var seenMedia = Set<Media>()
        var usedFilenames = Set<String>()
        var preparedCount = 0
        // A single scan feeds both keys: switching the selector must not make
        // already-saved files look new, and vice versa.
        let savedIDs = Set(try CollectionFiles.scan(folder).files.compactMap {
            FilenamePolicy.xFetishMediaID(inFileName: $0.lastPathComponent)
        })

        if xFetishMediaKind.includesImages {
            try await runXFetishAlbums(model: model, canonical: canonical, folder: folder,
                                       savedImageIDs: Set(savedIDs.filter { $0.hasPrefix("xf-") }),
                                       seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                                       preparedCount: &preparedCount)
        }
        if xFetishMediaKind.includesVideos {
            try await runXFetishVideos(model: model, canonical: canonical, folder: folder,
                                       savedVideoIDs: Set(savedIDs.filter { $0.hasPrefix("xfv-") }),
                                       seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                                       preparedCount: &preparedCount)
        }

        if let index = collections.firstIndex(where: { $0.id == canonical }) {
            collections[index].lastRun = Date()
            saveCollections()
        }
        LogCenter.info(L("X-Fetish : \(preparedCount) médias préparés.", "X-Fetish: \(preparedCount) media prepared."))
        if failed > 0 {
            status = ""
            let kept = (try? CollectionFiles.scan(folder).files.count) ?? files.count
            switch xFetishMediaKind {
            case .images:
                errorMessage = L("\(failed) images inaccessibles ou non enregistrées.\n\(kept) médias conservés.",
                                 "\(failed) images unavailable or unsaved.\n\(kept) media files kept.")
            case .videos:
                errorMessage = L("\(failed) vidéos inaccessibles ou non enregistrées.\n\(kept) médias conservés.",
                                 "\(failed) videos unavailable or unsaved.\n\(kept) media files kept.")
            case .both:
                errorMessage = L("\(failed) médias inaccessibles ou non enregistrés.\n\(kept) médias conservés.",
                                 "\(failed) media unavailable or unsaved.\n\(kept) media files kept.")
            }
            return
        }
        switch xFetishMediaKind {
        case .images:
            status = count == 0 ? L("Aucune nouvelle image accessible", "No new accessible images")
                                : L("\(count) images téléchargées", "\(count) images downloaded")
        case .videos:
            status = count == 0 ? L("Aucune nouvelle vidéo accessible", "No new accessible videos")
                                : L("\(count) vidéos téléchargées", "\(count) videos downloaded")
        case .both:
            status = count == 0 ? L("Aucun nouveau média accessible", "No new accessible media")
                                : L("\(count) médias téléchargés", "\(count) media downloaded")
        }
    }

    private func runXFetishAlbums(model: String, canonical: String, folder: URL,
                                  savedImageIDs: Set<String>,
                                  seenMedia: inout Set<Media>, usedFilenames: inout Set<String>,
                                  preparedCount: inout Int) async throws {
        var page = 1
        var scannedPages = Set<Int>()
        var scannedAlbums = Set<String>()

        while true {
            try Task.checkCancellation()
            guard scannedPages.insert(page).inserted, scannedPages.count <= 500 else {
                throw XFetishError.tooManyPages
            }
            status = L("Recherche des albums X-Fetish…", "Finding X-Fetish albums…")
            let listingData = try await network.data(XFetishAlbums.listingURL(model: model, page: page))
            let listing = try XFetishAlbums.parseListing(listingData, model: model, page: page)
            LogCenter.info(L("X-Fetish : page \(page), \(listing.albums.count) albums.", "X-Fetish: page \(page), \(listing.albums.count) albums."))

            for album in listing.albums {
                try Task.checkCancellation()
                guard scannedAlbums.insert(album.id).inserted else { continue }
                status = L("Album \(scannedAlbums.count) : \(album.title)", "Album \(scannedAlbums.count): \(album.title)")
                let galleryData = try await network.data(album.url)
                let gallery = try XFetishAlbums.parseGallery(galleryData, album: album)
                var images = gallery.images
                var imageIDs = Set(images.map(\.id))

                if gallery.extraPages > 0 {
                    for extraPage in 1...gallery.extraPages {
                        try Task.checkCancellation()
                        let fragment = try await network.data(XFetishAlbums.extraImagesURL(album: album, page: extraPage))
                        guard let extraImages = try XFetishAlbums.parseExtraImages(fragment, albumID: album.id,
                                                                                   hasEarlierImages: !images.isEmpty) else {
                            LogCenter.info(L("X-Fetish : album \(album.id), page supplémentaire vide, fin de la galerie.",
                                             "X-Fetish: album \(album.id), empty extra page, end of gallery."))
                            break
                        }
                        for image in extraImages where imageIDs.insert(image.id).inserted {
                            images.append(image)
                        }
                    }
                }
                LogCenter.info(L("X-Fetish : album \(album.id), \(images.count) images.", "X-Fetish: album \(album.id), \(images.count) images."))

                var mediaOverrides: [String: [Media]] = [:]
                var mediaHeaders: [String: [String: String]] = [:]
                let newImages = images.filter { !savedImageIDs.contains("xf-\(album.id)-\($0.id)") }
                let posts = newImages.map { image -> Post in
                    let id = "xf-\(album.id)-\(image.id)"
                    let media = Media.direct(image.url)
                    mediaOverrides[id] = [media]
                    // Anti-hotlink : le stockage exige le Referer de l'album.
                    mediaHeaders[media.key] = XFetishAPI.headers(referer: album.url)
                    return Post(id: id, title: album.title, html: "", link: album.url.absoluteString)
                }
                let downloads = try await prepareDownloads(posts, folder: folder,
                    seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                    author: canonical, mediaOverrides: mediaOverrides, mediaHeaders: mediaHeaders)
                beginTransferUnit(total: downloads.count)
                try await executeDownloads(downloads, &preparedCount)
            }

            guard let next = listing.nextPage else { break }
            guard next > page else { throw XFetishError.invalidListing }
            page = next
        }

        LogCenter.info(L("X-Fetish albums : \(scannedPages.count) pages, \(scannedAlbums.count) albums, \(preparedCount) images préparées.", "X-Fetish albums: \(scannedPages.count) pages, \(scannedAlbums.count) albums, \(preparedCount) images prepared."))
    }

    /// The signed `get_file` route only lives inside the player script of the
    /// video page and expires quickly, so each not-yet-saved video page is read
    /// again on every run. Saved `xfv-…` keys skip both the page and the file.
    private func runXFetishVideos(model: String, canonical: String, folder: URL,
                                  savedVideoIDs: Set<String>,
                                  seenMedia: inout Set<Media>, usedFilenames: inout Set<String>,
                                  preparedCount: inout Int) async throws {
        var page = 1
        var scannedPages = Set<Int>()
        var scannedVideos = Set<String>()

        while true {
            try Task.checkCancellation()
            guard scannedPages.insert(page).inserted, scannedPages.count <= 500 else {
                throw XFetishError.tooManyPages
            }
            status = L("Recherche des vidéos X-Fetish…", "Finding X-Fetish videos…")
            let listingData = try await network.data(XFetishVideos.listingURL(model: model, page: page))
            let listing = try XFetishVideos.parseListing(listingData, model: model, page: page)
            LogCenter.info(L("X-Fetish vidéos : page \(page), \(listing.videos.count) vidéos.", "X-Fetish videos: page \(page), \(listing.videos.count) videos."))
            var fresh: [XFetishVideos.Video] = []
            for video in listing.videos {
                try Task.checkCancellation()
                guard scannedVideos.insert(video.id).inserted else { continue }
                guard !savedVideoIDs.contains("xfv-\(video.id)") else { continue }
                fresh.append(video)
            }
            beginTransferUnit(total: fresh.count)
            // Vidéos préparées par lots de `sessionLimit` : au-delà, une URL
            // signée attendrait derrière tous les transferts de la page et le
            // `v-acctoken` pourrait expirer. La barre suit la page entière, pas
            // le lot, donc elle reste lisse malgré la découpe.
            for start in stride(from: 0, to: fresh.count, by: max(1, sessionLimit)) {
                try Task.checkCancellation()
                let chunk = Array(fresh[start..<min(start + max(1, sessionLimit), fresh.count)])
                var mediaOverrides: [String: [Media]] = [:]
                var mediaHeaders: [String: [String: String]] = [:]
                var posts: [Post] = []
                for video in chunk {
                    try Task.checkCancellation()
                    let id = "xfv-\(video.id)"
                    status = L("Vidéo \(scannedVideos.count) : \(video.title)", "Video \(scannedVideos.count): \(video.title)")
                    let pageData = try await network.data(video.url)
                    let fileURL = try XFetishVideos.parseFileURL(pageData, video: video)
                    let media = Media.direct(fileURL)
                    mediaOverrides[id] = [media]
                    // Anti-hotlink : le stockage exige le Referer de la page vidéo.
                    mediaHeaders[media.key] = XFetishAPI.headers(referer: video.url, accept: XFetishAPI.videoAccept)
                    posts.append(Post(id: id, title: video.title, html: "", link: video.url.absoluteString))
                }
                let downloads = try await prepareDownloads(posts, folder: folder,
                    seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                    author: canonical, mediaOverrides: mediaOverrides, mediaHeaders: mediaHeaders)
                try await executeDownloads(downloads, &preparedCount)
            }

            guard let next = listing.nextPage else { break }
            guard next > page else { throw XFetishVideoError.invalidListing }
            page = next
        }

        LogCenter.info(L("X-Fetish vidéos : \(scannedPages.count) pages, \(scannedVideos.count) vidéos, \(preparedCount) médias préparés.", "X-Fetish videos: \(scannedPages.count) pages, \(scannedVideos.count) videos, \(preparedCount) media prepared."))
    }

    /// Parcours du fil `/media` d'un compte X.
    ///
    /// Le fil se lit du plus récent au plus ancien et repart donc de la
    /// première page à chaque exécution : c'est le coût assumé du choix « tous
    /// les médias ». Aucun curseur n'est persisté, car reprendre au milieu
    /// sauterait les posts publiés depuis la dernière exécution.
    ///
    /// Le dédoublonnage repose uniquement sur les clés `xm-…` / `xmv-…` lues
    /// dans les noms de fichiers : une relance relit les pages mais ne
    /// retélécharge rien.
    ///
    /// Retourne `false` si le plafond de pages est atteint sans fin de fil.
    private func runTwitter(username: String, canonical: String, folder: URL,
                            seenMedia: inout Set<Media>, usedFilenames: inout Set<String>,
                            preparedCount: inout Int) async throws -> Bool {
        guard await XSession.shared.hasSession else { throw XTwitterError.loginRequired }
        status = L("Résolution du compte X…", "Resolving X account…")
        let userID = try await fetchXUserID(username: username)
        LogCenter.info(L("X : compte \(username) résolu.", "X: account \(username) resolved."))

        // Clés déjà sur disque : une clé média suffit, sans dépendre du titre
        // ni du post qui l'a publié.
        let savedIDs = Set(try CollectionFiles.scan(folder).files.compactMap {
            FilenamePolicy.xMediaID(inFileName: $0.lastPathComponent)
        })
        var scanned = Set<String>()
        var scannedPages = 0
        var requestedCursors = Set<String>()
        var cursor: String?

        while true {
            try Task.checkCancellation()
            scannedPages += 1
            guard scannedPages <= 100 else {
                LogCenter.info(L("X : plafond de 100 pages atteint, parcours incomplet. Le profil dépasse cette limite : les médias les plus anciens n'ont pas été parcourus.", "X: 100-page limit reached, scan incomplete. The profile exceeds this limit: its oldest media was not scanned."))
                return false
            }
            status = L("Recherche des médias X… page \(scannedPages)", "Searching X media… page \(scannedPages)")
            let data = try await fetchXMediaPage(userID: userID, cursor: cursor)
            let page = try XTwitterMedia.parseMediaPage(data)
            LogCenter.info(L("X : page \(scannedPages), \(page.posts.count) posts avec média.", "X: page \(scannedPages), \(page.posts.count) posts with media."))

            var fresh: [XPost] = []
            for post in page.posts where scanned.insert(post.id).inserted {
                // Un média déjà enregistré ne vaut pas une seconde page à relire
                // pour lui : le post entier est écarté si tous ses médias sont là.
                let missing = post.media.filter { !savedIDs.contains(Self.xMediaKey($0)) }
                guard !missing.isEmpty else { continue }
                fresh.append(XPost(id: post.id, text: post.text, publishedAt: post.publishedAt, media: missing))
            }

            if !fresh.isEmpty {
                var mediaOverrides: [String: [Media]] = [:]
                var posts: [Post] = []
                for post in fresh {
                    for media in post.media {
                        // L'identifiant du média entre dans le nom de fichier :
                        // c'est lui que `FilenamePolicy.xMediaID` relit au
                        // lancement suivant pour ne pas retélécharger. Un
                        // identifiant de post ne conviendrait pas, un même média
                        // pouvant apparaître dans plusieurs posts.
                        let id = Self.xMediaKey(media)
                        mediaOverrides[id] = [.direct(media.url)]
                        posts.append(Post(id: id, title: post.text, html: "",
                                          publishedAt: post.publishedAt,
                                          link: "https://x.com/i/status/\(post.id)"))
                    }
                }
                let downloads = try await prepareDownloads(posts, folder: folder,
                    seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                    author: canonical, mediaOverrides: mediaOverrides, mediaHeaders: [:])
                // La barre suit la page : X n'annonce aucun total global et le
                // parcours en découvre en continu, donc une unité de nombre
                // connu est la seule progression exacte possible. `downloads`
                // et non le nombre de médias vus : ceux déjà sur disque en sont
                // exclus, et la barre ne doit pas annoncer plus que le lot.
                beginTransferUnit(total: downloads.count)
                try await executeDownloads(downloads, &preparedCount)
            }

            guard let next = page.nextCursor, !next.isEmpty else { break }
            guard next != cursor, requestedCursors.insert(next).inserted else { throw XTwitterError.invalidTimeline }
            cursor = next
        }

        if let index = collections.firstIndex(where: { $0.id == canonical }) {
            collections[index].lastRun = Date()
            saveCollections()
        }
        LogCenter.info(L("X : \(scannedPages) pages, \(preparedCount) médias préparés.", "X: \(scannedPages) pages, \(preparedCount) media prepared."))
        if failed > 0 {
            status = ""
            let kept = (try? CollectionFiles.scan(folder).files.count) ?? files.count
            errorMessage = L("\(failed) médias X inaccessibles ou non enregistrés.\n\(kept) médias conservés.",
                             "\(failed) X media unavailable or unsaved.\n\(kept) media files kept.")
            return true
        }
        status = count == 0 ? L("Aucun nouveau média X accessible", "No new accessible X media")
                            : L("\(count) médias X téléchargés", "\(count) X media downloaded")
        return true
    }

    /// Clé de dédoublonnage d'un média X, alignée sur `FilenamePolicy.xMediaID`.
    private static func xMediaKey(_ media: XMedia) -> String {
        switch media.kind {
        case .image: return "xm-\(media.id)"
        case .video, .gif: return "xmv-\(media.id)"
        }
    }

    private func fetchXUserID(username: String) async throws -> String {
        let data = try await fetchX(XTwitterAPI.userByScreenName(username: username))
        let userID = try XTwitterMedia.parseUser(data)
        await XSession.shared.recordAPIAcceptance(true)
        return userID
    }

    private func fetchXMediaPage(userID: String, cursor: String?) async throws -> Data {
        try await fetchX(XTwitterAPI.userMedia(userID: userID, cursor: cursor))
    }

    /// Un appel GraphQL authentifié.
    private func fetchX(_ url: URL) async throws -> Data {
        // `csrfToken` lit les cookies à chaque appel : X renouvelle `ct0` en
        // cours de session et un jeton périmé se manifeste par un HTTP 403.
        // `refresh()` n'est pas appelé ici, l'observateur du cookie store tient
        // déjà `hasSession` à jour et le rappeler ici déclencherait une mise à
        // jour d'interface par requête.
        guard let csrf = await XSession.shared.csrfToken() else { throw XTwitterError.loginRequired }
        do {
            return try await network.data(url, bearer: XTwitterAPI.bearer,
                                         headers: XTwitterAPI.headers(csrf: csrf))
        } catch NetworkError.refused(let code) where code == 401 || code == 403 {
            // Une session expirée se voit ici. L'utilisateur est invité à se
            // reconnecter plutôt que de boucler sur un refus identique.
            await XSession.shared.refresh()
            if code == 401 { await XSession.shared.recordAPIAcceptance(false) }
            guard await XSession.shared.hasSession else { throw XTwitterError.loginRequired }
            throw XTwitterError.deniedAccess
        } catch NetworkError.refused(let code) where code == 404 {
            throw XTwitterError.unavailableAPI
        }
    }

    private static func cursorKey(_ canonical: String) -> String { "resumeCursor.\(canonical)" }
    private static func visitedKey(_ canonical: String) -> String { "visitedPosts.\(canonical)" }
    /// Curseur de la phase nouveautés : position jusqu'à laquelle les pages ont
    /// été parcourues, pour reprendre là où une session interrompue s'est arrêtée.
    private static func frontierKey(_ canonical: String) -> String { "newPostsFrontier.\(canonical)" }

    /// Marque-page persisté par collection : curseur de la dernière page
    /// traitée + posts déjà vus (borné). `cursor: nil` efface la reprise
    /// tout en gardant l'historique pour la détection des nouveautés.
    private static func persistResumeState(canonical: String, cursor: String?, visited: [String]) {
        let defaults = UserDefaults.standard
        if let cursor { defaults.set(cursor, forKey: cursorKey(canonical)) }
        else { defaults.removeObject(forKey: cursorKey(canonical)) }
        defaults.set(Array(visited.suffix(10_000)), forKey: visitedKey(canonical))
    }

    /// Distinct de la reprise : la phase 2 n'y touche pas, seule la phase
    /// nouveautés avance ce curseur, et `nil` signifie « plus rien à sauter ».
    private static func persistFrontier(_ canonical: String, _ frontier: String?) {
        let key = frontierKey(canonical)
        if let frontier { UserDefaults.standard.set(frontier, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func fetchPosts(source: FeedSource, privateFeed: SavedFeed?, after: String?) async throws -> [Post] {
        if let privateFeed {
            return try await network.savedPosts(privateFeed, after: after)
        } else {
            return try FeedParser.parse(try await network.data(source.feedURL(sort: subSort, after: after)))
        }
    }

    private static func validPageCursor(_ id: String, privateFeed: SavedFeed?) -> Bool {
        id.hasPrefix("t3_") || (privateFeed != nil && id.hasPrefix("t1_"))
    }

    /// Parcours d'un compte RedGifs (`order=new`, 80 par page, max 100 pages
    /// côté API). Les IDs déjà vus sont sautés, les nouveaux passent par le
    /// chemin HD-d'abord existant. Retourne `false` si les 100 pages sont
    /// consommées sans atteindre la fin (relance pour continuer).
    private func runRedgifsUser(username: String, canonical: String, folder: URL,
                                seenMedia: inout Set<Media>, usedFilenames: inout Set<String>,
                                preparedCount: inout Int) async throws -> Bool {
        var visited = Set(UserDefaults.standard.stringArray(forKey: Self.visitedKey(canonical)) ?? [])
        var orderedVisited = UserDefaults.standard.stringArray(forKey: Self.visitedKey(canonical)) ?? []
        var seenPages = Set<[String]>()
        for page in 1...100 {
            try Task.checkCancellation()
            status = L("Recherche RedGifs… page \(page)", "Searching RedGifs… page \(page)")
            LogCenter.net(L("RedGifs \(username) : page \(page) demandée…", "RedGifs \(username): page \(page) requested…"))
            let response = try await fetchRedgifsUserPage(username: username, page: page)
            let ids = response.gifs.map(\.id)
            LogCenter.net(L("RedGifs \(username) : page \(page) reçue, \(ids.count) médias.", "RedGifs \(username): page \(page) received, \(ids.count) media."))
            if ids.isEmpty { break }
            guard seenPages.insert(ids).inserted else { break }
            let fresh = ids.filter { !visited.contains($0) }
            if !fresh.isEmpty {
                let downloads = prepareRedgifsDownloads(fresh, folder: folder,
                    seenMedia: &seenMedia, usedFilenames: &usedFilenames, author: canonical)
                LogCenter.info(L("RedGifs page \(page) : \(downloads.count) nouveaux médias à prendre.", "RedGifs page \(page): \(downloads.count) new media to fetch."))
                try await executeDownloads(downloads, &preparedCount)
            }
            for id in ids where visited.insert(id).inserted { orderedVisited.append(id) }
            Self.persistResumeState(canonical: canonical, cursor: nil, visited: orderedVisited)
            if page >= max(1, response.pages) { return true }
        }
        return false
    }

    private func fetchRedgifsUserPage(username: String, page: Int) async throws -> RedgifsUserSearchResponse {
        let bearer = try await redgifsToken()
        do {
            let data = try await network.data(
                RedgifsAPI.userSearchURL(username: username, page: page),
                bearer: bearer, headers: RedgifsAPI.headers(id: username))
            return try JSONDecoder().decode(RedgifsUserSearchResponse.self, from: data)
        } catch NetworkError.refused(let code) where code == 401 {
            token = nil
            let bearer = try await redgifsToken()
            let data = try await network.data(
                RedgifsAPI.userSearchURL(username: username, page: page),
                bearer: bearer, headers: RedgifsAPI.headers(id: username))
            return try JSONDecoder().decode(RedgifsUserSearchResponse.self, from: data)
        } catch NetworkError.refused(let code) where code == 404 {
            throw NetworkError.invalid(L("Compte RedGifs introuvable : \(username).", "RedGifs account not found: \(username)."))
        }
    }

    /// Nommage `IDcourt` stable (titres API non exploités), dédoublonnage par
    /// `Media` et migration des anciens fichiers nommés par empreinte,
    /// comme `prepareDownloads`.
    private func prepareRedgifsDownloads(_ ids: [String], folder: URL,
                                         seenMedia: inout Set<Media>,
                                         usedFilenames: inout Set<String>,
                                         author: String) -> [Download] {
        var downloads: [Download] = []
        var renamedExisting = false
        var skippedExisting = 0
        var skippedSeen = 0
        for id in ids {
            let item = Media.redgifs(id.lowercased())
            guard seenMedia.insert(item).inserted else { skippedSeen += 1; continue }
            let stem = FilenamePolicy.downloadStem(title: "", postID: id)
            var filename = "\(stem).mp4"
            if !usedFilenames.insert(filename.lowercased()).inserted {
                var duplicate = 2
                filename = "\(stem)-\(duplicate).mp4"
                while !usedFilenames.insert(filename.lowercased()).inserted {
                    duplicate += 1
                    filename = "\(stem)-\(duplicate).mp4"
                }
            }
            let destination = folder.appendingPathComponent(filename)
            let digest = SHA256.hash(data: Data(item.key.utf8)).map { String(format: "%02x", $0) }.joined()
            let legacyDestination = folder.appendingPathComponent(digest).appendingPathExtension("mp4")
            if fm.fileExists(atPath: destination.path) {
                skippedExisting += 1
                if fm.fileExists(atPath: legacyDestination.path) {
                    try? fm.removeItem(at: legacyDestination)
                    renamedExisting = true
                }
            } else if fm.fileExists(atPath: legacyDestination.path) {
                try? fm.moveItem(at: legacyDestination, to: destination)
                MediaMetadata.move(from: legacyDestination, to: destination)
                renamedExisting = true
            } else {
                downloads.append(Download(media: item, destination: destination,
                    postDate: nil, author: author,
                    postLink: "https://www.redgifs.com/users/\(author.split(separator: "/").last.map(String.init) ?? "")", headers: nil))
            }
        }
        if skippedExisting > 0 || skippedSeen > 0 {
            LogCenter.info(L("Déjà là : \(skippedExisting) fichiers, \(skippedSeen) médias déjà vus.", "Already here: \(skippedExisting) files, \(skippedSeen) media seen."))
        }
        if renamedExisting { reload() }
        return downloads
    }

    private func executeDownloads(_ downloads: [Download], _ preparedCount: inout Int) async throws {
        preparedCount += downloads.count
        status = ""
        if downloads.isEmpty { return }
        // `discovered` compte ce que le parcours a repéré, pas ce qu'il a
        // enregistré : sans cela le dénominateur resterait égal au numérateur
        // et aucune barre n'aurait de sens. Les fichiers déjà présents sont
        // exclus car `downloads` ne contient que les médias à transférer.
        discovered += downloads.count
        LogCenter.net(L("Transfert de \(downloads.count) médias (max \(sessionLimit) à la fois)…", "Transferring \(downloads.count) media (max \(sessionLimit) at once)…"))
        try await ConcurrentDownloads.run(downloads, limit: sessionLimit) { item in
            // Un média terminé, réussi ou non, fait avancer la barre. L'appel
            // est attendu avant toute autre étape : aucun reliquat ne peut
            // ainsi arriver après le début de l'unité suivante.
            do {
                try await self.saveIgnoringInaccessible(item)
            } catch {
                await self.recordTransferredItem()
                throw error
            }
            await self.recordTransferredItem()
        }
        LogCenter.net(L("Transfert du lot terminé.", "Batch transfer done."))
    }

    private func beginTransferUnit(total: Int) {
        transferUnit = total > 0 ? TransferUnit(done: 0, total: total) : nil
    }

    private func recordTransferredItem() {
        guard var unit = transferUnit else { return }
        unit.done = min(unit.done + 1, unit.total)
        transferUnit = unit
    }

    /// Keeps naming, deduplication and legacy migration identical across feed pages.
    /// Les posts galerie (lien `/gallery/` sans média direct) sont résolus via
    /// le JSON du post, comme la prévisualisation : images `i.redd.it` et
    /// vidéos `v.redd.it` (DASH). Un échec galerie ignore juste ce post, sauf
    /// un refus HTTP 429 qui arrête la session comme n'importe quel autre.
    private func prepareDownloads(_ posts: [Post], folder: URL,
                                   seenMedia: inout Set<Media>,
                                   usedFilenames: inout Set<String>,
                                   author: String = "",
                                   mediaOverrides: [String: [Media]] = [:],
                                   mediaHeaders: [String: [String: String]] = [:]) async throws -> [Download] {
        var galleryLists: [String: [Media]] = [:]
        let candidates = posts.filter { mediaOverrides[$0.id] == nil && MediaExtractor.extract($0.html).isEmpty && GalleryFeed.linked($0.html) }
        if !candidates.isEmpty {
            try await withThrowingTaskGroup(of: (String, [Media]).self) { group in
                for post in candidates {
                    group.addTask {
                        do {
                            let list = try await self.previewGalleryMedia(feedID: post.id, galleryID: GalleryFeed.linkedID(post.html))
                            return (post.id, list)
                        } catch NetworkError.limited(let service, let until) {
                            throw NetworkError.limited(service: service, until: until)
                        } catch {
                            return (post.id, [])
                        }
                    }
                }
                for try await (id, list) in group {
                    galleryLists[id] = list
                }
            }
            try Task.checkCancellation()
        }
        var downloads: [Download] = []
        var renamedExisting = false
        var skippedExisting = 0
        var skippedSeen = 0
        if !candidates.isEmpty {
            let resolved = galleryLists.values.reduce(0) { $0 + $1.count }
            LogCenter.info(L("Galeries : \(candidates.count) à résoudre, \(resolved) médias trouvés.", "Galleries: \(candidates.count) to resolve, \(resolved) media found."))
        }
        for post in posts {
            var media = mediaOverrides[post.id] ?? MediaExtractor.extract(post.html)
            if media.isEmpty {
                media = galleryLists[post.id] ?? []
            }
            for (index, item) in media.enumerated() {
                guard seenMedia.insert(item).inserted else { skippedSeen += 1; continue }
                let ext: String
                // Une URL de média X porte son format dans le chemin pour les vidéos, mais
                // `pbs.twimg.com/media/<id>.jpg` peut être servie en `png` ou
                // `webp` : le chemin reste donc la seule source fiable ici, et
                // une extension vide se replie sur `jpg`.
                if case .direct(let url) = item {
                    let path = url.pathExtension.lowercased()
                    ext = path.isEmpty ? "jpg" : path
                } else { ext = "mp4" }

                let position: Int? = media.count > 1 ? index + 1 : nil
                let stem = FilenamePolicy.downloadStem(title: post.title, postID: post.id, position: position)
                var filename = "\(stem).\(ext)"
                if !usedFilenames.insert(filename.lowercased()).inserted {
                    var duplicate = 2
                    filename = "\(stem)-\(duplicate).\(ext)"
                    while !usedFilenames.insert(filename.lowercased()).inserted {
                        duplicate += 1
                        filename = "\(stem)-\(duplicate).\(ext)"
                    }
                }

                let destination = folder.appendingPathComponent(filename)
                let digest = SHA256.hash(data: Data(item.key.utf8)).map { String(format: "%02x", $0) }.joined()
                let legacyDestination = folder.appendingPathComponent(digest).appendingPathExtension(ext)

                if fm.fileExists(atPath: destination.path) {
                    skippedExisting += 1
                    if fm.fileExists(atPath: legacyDestination.path) {
                        try? fm.removeItem(at: legacyDestination)
                        renamedExisting = true
                    }
                } else if fm.fileExists(atPath: legacyDestination.path) {
                    try? fm.moveItem(at: legacyDestination, to: destination)
                    MediaMetadata.move(from: legacyDestination, to: destination)
                    renamedExisting = true
                } else {
                    let postLink = BinaryMetadata.postLink(postID: post.id, link: post.link)
                    downloads.append(Download(media: item, destination: destination, postDate: post.publishedAt, author: author, postLink: postLink, headers: mediaHeaders[item.key]))
                }
            }
        }
        if skippedExisting > 0 || skippedSeen > 0 {
            LogCenter.info(L("Déjà là : \(skippedExisting) fichiers, \(skippedSeen) médias déjà vus.", "Already here: \(skippedExisting) files, \(skippedSeen) media seen."))
        }
        if renamedExisting { reload() }
        return downloads
    }

    /// Relance bornée sur erreur transitoire (réseau mobile instable) :
    /// 3 essais max, backoff 2s/4s. Le 429 est exclu : il est déjà converti en
    /// `NetworkError.limited` par `Network.check` et n'est jamais réessayé.
    private func saveWithRetry(_ item: Download) async throws {
        var attempt = 0
        while true {
            do {
                return try await save(item)
            } catch {
                if error is CancellationError { throw error }
                guard Self.isTransient(error), attempt < 2 else { throw error }
                attempt += 1
                LogCenter.net(L("Réseau instable, nouvel essai \(attempt)/2 pour \(item.destination.lastPathComponent)…", "Unstable network, retry \(attempt)/2 for \(item.destination.lastPathComponent)…"))
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                    .secureConnectionFailed].contains(urlError.code)
        }
        if case NetworkError.refused(let code) = error {
            return code == 408 || (500...599).contains(code)
        }
        return false
    }

    /// Un média supprimé ou inaccessible (ex. HTTP 404) ne doit pas annuler
    /// tout le parcours : on le comptabilise et on continue avec les autres.
    /// Seules l'annulation, les erreurs de flux RSS et un HTTP 429 restent
    /// fatales : un refus du serveur arrête la session entière, même au milieu
    /// d'un lot, et l'utilisateur choisit quand relancer.
    private func saveIgnoringInaccessible(_ item: Download) async throws {
        do {
            let saved = try await DownloadFailurePolicy.attempt {
                do { try await self.saveWithRetry(item) }
                catch {
                    if !Task.isCancelled && !DownloadFailurePolicy.isCancellation(error) && !DownloadFailurePolicy.isTransient(error) {
                        LogCenter.net("\(item.destination.lastPathComponent) : \(error.localizedDescription)")
                    }
                    throw error
                }
            }
            if !saved {
                failed += 1
                LogCenter.info(L("Média inaccessible, ignoré : \(item.destination.lastPathComponent).", "Inaccessible media, skipped: \(item.destination.lastPathComponent)."))
            }
        } catch {
            if !Task.isCancelled && !DownloadFailurePolicy.isCancellation(error) {
                LogCenter.err("\(item.destination.lastPathComponent) : \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func save(_ item: Download) async throws {
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        let temporary = try await resolveAndDownload(item.media, headers: item.headers)
        defer { try? fm.removeItem(at: temporary) }
        try Task.checkCancellation()
        try fm.moveItem(at: temporary, to: item.destination)
        // Étiquette binaire visible Windows (Auteurs/Commentaires) : fail-safe,
        // jamais de token privé, GIF/WebP ignorés. Ne fait jamais échouer le save.
        await Self.embedBinaryMetadata(at: item.destination, author: item.author, postLink: item.postLink)
        // Tri par date du post dans Fichiers/Photos : le fichier porte la
        // date du post (la date de téléchargement reste dans le sidecar).
        // Reposée après l'injection car la réécriture peut la réinitialiser.
        if let postDate = item.postDate {
            try? fm.setAttributes([.creationDate: postDate, .modificationDate: postDate], ofItemAtPath: item.destination.path)
        }
        MediaMetadata(downloadedAt: Date(), postDate: item.postDate, author: item.author.isEmpty ? nil : item.author, postLink: item.postLink).save(for: item.destination)
        files.insert(item.destination, at: 0)
        totalBytes += Int64((try? item.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        count += 1
        LogCenter.info(L("Gardé : \(item.destination.lastPathComponent) (\(count)/\(discovered)).", "Kept: \(item.destination.lastPathComponent) (\(count)/\(discovered))."))
        // A scan started before this save must not overwrite the newly inserted file.
        if reloadTask != nil { reload() }
    }

    /// Injection binaire fail-safe : JPG/PNG via EXIF sans recompression,
    /// MP4/MOV via Passthrough. Retourne toujours, ne throw jamais.
    /// nonisolated : gros travail fichier hors Main pour ne pas geler l'écran (décision Jev A).
    nonisolated private static func embedBinaryMetadata(at url: URL, author: String, postLink: String?) async {
        guard BinaryMetadata.supportsExtension(url.pathExtension) else { return }
        if Task.isCancelled { return }
        let payload = BinaryMetadata.payload(author: author, postLink: postLink)
        guard !payload.author.isEmpty || payload.comment != nil else { return }
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png"].contains(ext) {
            tagImage(at: url, author: payload.author, comment: payload.comment)
        } else if ["mp4", "mov", "m4v"].contains(ext) {
            await tagMovie(at: url, author: payload.author, comment: payload.comment)
        }
    }

    nonisolated private static func tagImage(at url: URL, author: String, comment: String?) {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return }
        let metadata = CGImageMetadataCreateMutable()
        if !author.isEmpty,
           let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, kCGImagePropertyTIFFArtist, .string, author as CFString) {
            CGImageMetadataSetTagWithPath(metadata, nil, "tiff:Artist" as CFString, tag)
        }
        if let comment, !comment.isEmpty,
           let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceExif, kCGImageMetadataPrefixExif, kCGImagePropertyExifUserComment, .string, comment as CFString) {
            CGImageMetadataSetTagWithPath(metadata, nil, "exif:UserComment" as CFString, tag)
        }
        let options: [String: Any] = [
            kCGImageDestinationMetadata as String: metadata,
            kCGImageDestinationMergeMetadata as String: true
        ]
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return }
        var error: Unmanaged<CFError>?
        let ok = withUnsafeMutablePointer(to: &error) { ptr in
            CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, ptr)
        }
        guard ok, output.length > 0 else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try output.write(to: temp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    nonisolated private static func movieMetadataItems(author: String, comment: String?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if !author.isEmpty {
            let artist = AVMutableMetadataItem()
            artist.identifier = .commonIdentifierArtist
            artist.value = String(author.prefix(256)) as NSString
            items.append(artist.copy() as! AVMetadataItem)
        }
        if let comment, !comment.isEmpty {
            let value = String(comment.prefix(2048)) as NSString
            let description = AVMutableMetadataItem()
            description.identifier = .commonIdentifierDescription
            description.value = value
            items.append(description.copy() as! AVMetadataItem)
            let userComment = AVMutableMetadataItem()
            userComment.identifier = .iTunesMetadataUserComment
            userComment.value = value
            items.append(userComment.copy() as! AVMetadataItem)
        }
        return items
    }

    nonisolated private static func tagMovie(at url: URL, author: String, comment: String?) async {
        let items = movieMetadataItems(author: author, comment: comment)
        guard !items.isEmpty else { return }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        let ext = url.pathExtension.lowercased()
        export.outputFileType = ext == "mov" ? .mov : .mp4
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mp4" : ext)
        export.outputURL = temp
        export.metadata = items
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            export.cancelExport()
        }
        guard export.status == .completed else { try? FileManager.default.removeItem(at: temp); return }
        if Task.isCancelled { try? FileManager.default.removeItem(at: temp); return }
        do {
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func redgifsToken() async throws -> String {
        if let token, Date().timeIntervalSince(tokenDate) < 1800 { return token }
        // Décision Jev A bug 11 : si la tâche précédente a été annulée (Stop),
        // on l'oublie et on recrée proprement au lieu de rejouer l'annulation.
        if let existing = tokenTask {
            do {
                return try await existing.value
            } catch is CancellationError {
                tokenTask = nil
            } catch {
                throw error
            }
        }
        let request = Task { @MainActor in
            struct Auth: Decodable { let token: String }
            let data = try await network.data(URL(string: "https://api.redgifs.com/v2/auth/temporary")!)
            return try JSONDecoder().decode(Auth.self, from: data).token
        }
        tokenTask = request
        do {
            let result = try await request.value
            token = result; tokenDate = Date()
            tokenTask = nil
            return result
        } catch {
            if request.isCancelled { tokenTask = nil }
            else { tokenTask = nil }
            throw error
        }
    }
    private func downloadRedgifs(id: String) async throws -> URL {
        let shortID = String(id.prefix(12))
        LogCenter.net(L("RedGIFs : fiche \(shortID)…", "RedGIFs: entry \(shortID)…"))
        let bearer = try await redgifsToken()
        struct Response: Decodable { struct Gif: Decodable { struct URLs: Decodable { let hd: URL?; let sd: URL? }; let urls: URLs }; let gif: Gif }
        let data = try await network.data(RedgifsAPI.gifURL(id: id), bearer: bearer, headers: RedgifsAPI.headers(id: id))
        let urls = try JSONDecoder().decode(Response.self, from: data).gif.urls
        LogCenter.net(L("RedGIFs \(shortID) : HD \(urls.hd != nil ? "oui" : "non"), SD \(urls.sd != nil ? "oui" : "non").", "RedGIFs \(shortID): HD \(urls.hd != nil ? "yes" : "no"), SD \(urls.sd != nil ? "yes" : "no")."))
        let candidates = QualityPolicy.redgifsCandidates(hd: urls.hd, sd: urls.sd)
            .filter { url in
                guard let host = url.host else { return false }
                return host == "redgifs.com" || host.hasSuffix(".redgifs.com")
            }
            .map { url in (label: url.path.lowercased().contains("-mobile") ? "SD" : "HD", url: url) }
        guard !candidates.isEmpty else {
            throw NetworkError.invalid(L("Média RedGIFs indisponible.", "RedGIFs media unavailable."))
        }
        return try await OrderedFallback.first(candidates) { candidate in
            LogCenter.net(L("RedGIFs \(shortID) : essai \(candidate.label)…", "RedGIFs \(shortID): trying \(candidate.label)…"))
            return try await self.network.download(candidate.url, headers: RedgifsAPI.headers(id: id))
        }
    }
    private func resolveAndDownload(_ media: Media, headers: [String: String]? = nil) async throws -> URL {
        switch media {
        case .direct(let url):
            LogCenter.net(L("Direct : \(url.host ?? "serveur")…", "Direct: \(url.host ?? "server")…"))
            return try await network.download(url, headers: headers)
        case .redgifs(let id):
            do {
                return try await downloadRedgifs(id: id)
            } catch NetworkError.refused(let code) where code == 401 {
                // Token expiré entre le cache et l'appel : un seul refresh + nouvel essai.
                LogCenter.net(L("RedGIFs : session expirée, nouvel essai…", "RedGIFs: session expired, retrying…"))
                token = nil
                return try await downloadRedgifs(id: id)
            }
        case .redditVideo(let base):
            LogCenter.net(L("Vidéo Reddit : manifeste \(base.host ?? "serveur")…", "Reddit video: manifest \(base.host ?? "server")…"))
            let manifest = base.appendingPathComponent("DASHPlaylist.mpd")
            let tracks = try DASHParser.parse(try await network.data(manifest), relativeTo: manifest)
            guard tracks.video.host == base.host, tracks.audio == nil || tracks.audio?.host == base.host else { throw NetworkError.invalid(L("Manifest vidéo inattendu.", "Unexpected video manifest.")) }
            let video = try await network.download(tracks.video)
            guard let audioURL = tracks.audio else {
                LogCenter.info(L("Vidéo sans piste son, gardée telle quelle.", "Video without audio track, kept as is."))
                return video
            }
            defer { try? fm.removeItem(at: video) }
            LogCenter.net(L("Vidéo + son : assemblage…", "Video + audio: merging…"))
            let audio = try await network.download(audioURL)
            defer { try? fm.removeItem(at: audio) }
            return try await merge(video: video, audio: audio)
        }
    }
    nonisolated private func merge(video: URL, audio: URL) async throws -> URL {
        let fm = FileManager.default
        let composition = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let sourceV = try await v.loadTracks(withMediaType: .video).first,
              let sourceA = try await a.loadTracks(withMediaType: .audio).first,
              let targetV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let targetA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NetworkError.invalid(L("Pistes vidéo/audio illisibles.", "Unable to read video/audio tracks.")) }
        let durationV = try await v.load(.duration), durationA = try await a.load(.duration)
        try targetV.insertTimeRange(CMTimeRange(start: .zero, duration: durationV), of: sourceV, at: .zero)
        try targetA.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(durationV, durationA)), of: sourceA, at: .zero)
        targetV.preferredTransform = try await sourceV.load(.preferredTransform)
        let output = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw NetworkError.invalid(L("Assemblage vidéo indisponible.", "Video merging unavailable.")) }
        export.outputURL = output; export.outputFileType = .mp4
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in export.exportAsynchronously { continuation.resume() } }
        } onCancel: {
            export.cancelExport()
        }
        guard export.status == .completed else { try? fm.removeItem(at: output); throw export.error ?? NetworkError.invalid(L("Échec de l’assemblage vidéo.", "Video merging failed.")) }
        if Task.isCancelled { try? fm.removeItem(at: output); throw CancellationError() }
        return output
    }
}

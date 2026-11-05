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
    /// Tag RedGifs (`rg/#tag`) : même parcours paginé qu'un compte, mais la
    /// liste vient de `/v2/gifs/search` au lieu de `/v2/users/…/search`.
    var isRedGifsTag = false
    /// GIF RedGifs unique (`rg/gif/<id>`) : aucun parcours, un seul média.
    var isRedGifsGif = false
    /// Posts Reddit isolés (`r/posts`) : seuls les posts collés sont lus.
    var isRedditPosts = false
    var archived = false
    var lastRun: Date?
    /// Clé canonique : `u/pseudo`, `r/sub`, `saved/pseudo`, `x/profil`,
    /// `rg/pseudo`, `rg/#tag`, `rg/gif/<id>`, `tw/pseudo` ou `r/posts`.
    var id: String {
        if isTwitter { return "tw/\(name)" }
        if isRedGifsTag { return "rg/#\(name)" }
        if isRedGifsGif { return "rg/gif/\(name)" }
        if isRedGifs { return "rg/\(name)" }
        if isSaved { return "saved/\(name)" }
        if isXFetish { return "x/\(name)" }
        if isRedditPosts { return "reddit/posts" }
        return (isSubreddit ? "r/" : "u/") + name
    }
    var displayName: String { isSaved ? "Saved" : id }
    /// Dossier de stockage. Les points de `r.…`, `saved.…`, `x.…`,
    /// `redgifs.…` et `tw.…` sont interdits dans les pseudos : aucune
    /// collection existante ne peut entrer en collision.
    var folderName: String {
        if isTwitter { return "tw.\(name)" }
        if isRedGifsTag { return "redgifs.tag.\(name)" }
        if isRedGifsGif { return "redgifs.gif.\(name)" }
        if isRedGifs { return "redgifs.\(name)" }
        if isSaved { return "saved.\(name)" }
        if isXFetish { return "x.\(name)" }
        if isRedditPosts { return "reddit.posts" }
        return isSubreddit ? "r.\(name)" : name
    }

    enum CodingKeys: String, CodingKey {
        case name, isSubreddit, isSaved, isXFetish, isRedGifs, isTwitter, isRedGifsTag, isRedGifsGif, isRedditPosts, archived, lastRun
    }
    init(name: String, isSubreddit: Bool = false, isSaved: Bool = false, isXFetish: Bool = false, isRedGifs: Bool = false, isTwitter: Bool = false, isRedGifsTag: Bool = false, isRedGifsGif: Bool = false, isRedditPosts: Bool = false, archived: Bool = false, lastRun: Date? = nil) {
        self.name = name
        self.isSubreddit = isSubreddit
        self.isSaved = isSaved
        self.isXFetish = isXFetish
        self.isRedGifs = isRedGifs
        self.isTwitter = isTwitter
        self.isRedGifsTag = isRedGifsTag
        self.isRedGifsGif = isRedGifsGif
        self.isRedditPosts = isRedditPosts
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
        isRedGifsTag = try container.decodeIfPresent(Bool.self, forKey: .isRedGifsTag) ?? false
        isRedGifsGif = try container.decodeIfPresent(Bool.self, forKey: .isRedGifsGif) ?? false
        isRedditPosts = try container.decodeIfPresent(Bool.self, forKey: .isRedditPosts) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
    }

    /// Collection correspondant à une source. Point unique de vérité pour la
    /// correspondance source → collection : les six commutateurs qui la
    /// répétaient pouvaient diverger, ce qui suffisait à créer deux entrées
    /// pour la même source.
    init(source: FeedSource) {
        switch source {
        case .user(let name): self.init(name: name)
        case .subreddit(let name): self.init(name: name, isSubreddit: true)
        case .saved(let name): self.init(name: name, isSaved: true)
        case .xFetish(let target): self.init(name: target.collectionName, isXFetish: true)
        case .redgifsUser(let name): self.init(name: name, isRedGifs: true)
        case .redgifsTag(let tag): self.init(name: tag, isRedGifsTag: true)
        case .redgifsGif(let id): self.init(name: id, isRedGifsGif: true)
        case .twitterUser(let name): self.init(name: name, isTwitter: true)
        case .redditPosts: self.init(name: "posts", isRedditPosts: true)
        }
    }
}

@MainActor final class Downloader: ObservableObject {
    @Published var username = UserDefaults.standard.string(forKey: "lastUsername") ?? ""
    @Published var collections: [UserCollection] = []
    @Published var activeUser: String?
    @Published var running = false
    @Published var status = ""
    @Published var errorMessage: String?
    /// Vrai quand le dernier parcours s'est arrêté avant la fin du contenu
    /// disponible : le budget de pages a été atteint et il reste des pages à
    /// voir. Relancer reprend exactement où le parcours s'était arrêté, donc
    /// aucun média n'est perdu — mais l'archive n'est pas complète. Le bandeau
    /// d'information le signale sans bloquer, et disparaît au lancement suivant.
    @Published private(set) var scanIncomplete = false
    @Published var files: [URL] = []
    @Published private(set) var loadingFiles = false
    @Published var count = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var discovered = 0
    /// Avancé de l'unité de téléchargement en cours : un album, ou la liste
    /// des vidéos collectées (100 pages maximum). La barre porte sur cette
    /// unité connue, pas sur un historique exhaustif du profil. Les octets des
    /// vidéos en cours complètent les fichiers terminés, et le compteur
    /// « repérés » garde son sens propre.
    struct TransferUnit: Equatable {
        var done = 0
        var total = 0
        var inFlight: [String: Double] = [:]
        var fraction: Double { total > 0 ? min(1, (Double(done) + inFlight.values.reduce(0, +)) / Double(total)) : 0 }
    }
    @Published private(set) var transferUnit: TransferUnit?
    var totalSize: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    /// Médias reçus lors du dernier parcours terminé, par collection. Sert au
    /// compteur « nouveautés » des pastilles : `lastRun` existait déjà mais
    /// n'était affiché nulle part, ce qui rendait invisible ce qui avait été
    /// réellement ajouté au passage précédent.
    @Published private(set) var lastRunCounts: [String: Int] = [:]

    /// Filtres de téléchargement, par collection. Rechargé au changement de
    /// collection active, jamais partagé entre deux sources.
    @Published var downloadFilter = DownloadFilter()

    /// Plafond d'espace disque, global. Zéro signifie « sans limite ».
    @Published var storageQuota = StorageQuota.load() {
        didSet { StorageQuota.save(storageQuota) }
    }

    /// Dernier écart lié au plafond d'espace : affiché en information, pas en
    /// erreur — rien n'est cassé, la session s'est arrêtée proprement.
    @Published private(set) var storageLimitReached = false

    /// Recherche et tri de la galerie. Purement locaux : ils ne changent que
    /// l'ordre d'affichage des fichiers déjà sur l'écran, jamais ce qui est
    /// téléchargé.
    @Published var gallerySearch = "" {
        didSet { applyGalleryOrdering() }
    }
    @Published var gallerySort: GallerySort = {
        GallerySort(rawValue: UserDefaults.standard.string(forKey: "gallerySort") ?? "") ?? .newest
    }() {
        didSet {
            UserDefaults.standard.set(gallerySort.rawValue, forKey: "gallerySort")
            applyGalleryOrdering()
        }
    }
    @Published var galleryKindFilter: GalleryKindFilter = .all {
        didSet { applyGalleryOrdering() }
    }

    /// Fichiers affichés par la galerie : `files` filtré et trié.
    ///
    /// C'est une valeur **stockée**, recalculée par `applyGalleryOrdering()`
    /// chaque fois qu'une entrée change. La calculer à la volée dans le corps
    /// de la vue ne suffisait pas : SwiftUI ne relit une propriété dérivée que
    /// s'il a une raison de réévaluer le corps, et le tri semblait alors sans
    /// effet. Une valeur publiée rend le changement explicite.
    @Published private(set) var displayedFiles: [URL] = []

    /// Recalcule `displayedFiles` à partir de l'état courant. Appelée au
    /// rechargement et à chaque changement de recherche, de tri ou de filtre.
    private func applyGalleryOrdering() {
        let query = gallerySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = files.filter { url in
            guard galleryKindFilter.allows(url) else { return false }
            guard !query.isEmpty else { return true }
            // `localizedStandardContains` gère casse et diacritiques, comme la
            // recherche d'un `UISearchBar` : « cafe » trouve « Café ».
            if url.lastPathComponent.localizedStandardContains(query) { return true }
            return searchIndex[url]?.localizedStandardContains(query) == true
        }
        result = gallerySort.sorted(result, dates: fileDates, sizes: fileSizes)
        if result != displayedFiles { displayedFiles = result }
    }

    /// Date de création et taille par fichier, relevées au rechargement avec la
    /// liste. Les trier à la volée aurait relu les attributs de chaque fichier
    /// à chaque rendu, sur une collection qui peut compter des milliers
    /// d'entrées.
    @Published private var fileDates: [URL: Date] = [:]
    @Published private var fileSizes: [URL: Int64] = [:]

    /// Relève date et taille d'un lot de fichiers, hors du fil principal.
    /// Seuls les attributs déjà en cache du système sont demandés : la liste
    /// vient d'être scannée, une lecture disque supplémentaire serait inutile.
    nonisolated static func buildFileFacts(_ files: [URL]) -> (dates: [URL: Date], sizes: [URL: Int64]) {
        var dates: [URL: Date] = [:]
        var sizes: [URL: Int64] = [:]
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey]
        for url in files {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if let date = values.creationDate { dates[url] = date }
            if let size = values.fileSize { sizes[url] = Int64(size) }
        }
        return (dates, sizes)
    }

    /// Texte cherchable par fichier : auteur et lien du post, lus une fois au
    /// rechargement. Les noms de fichiers ne sont pas dupliqués ici.
    @Published private var searchIndex: [URL: String] = [:]

    /// Reconstruit l'index de recherche depuis les sidecars. Appelé par
    /// `reload()`, hors du chemin de rendu.
    nonisolated static func buildSearchIndex(_ files: [URL]) -> [URL: String] {
        var index: [URL: String] = [:]
        for url in files {
            guard let metadata = MediaMetadata.read(for: url) else { continue }
            let parts = [metadata.author, metadata.postLink].compactMap { $0 }
            guard !parts.isEmpty else { continue }
            index[url] = parts.joined(separator: " ").lowercased()
        }
        return index
    }

    /// Ordres proposés par la galerie.
    enum GallerySort: String, CaseIterable, Sendable {
        case newest, oldest, largest, smallest, name

        var label: String {
            switch self {
            case .newest: return L("Plus récent", "Newest")
            case .oldest: return L("Plus ancien", "Oldest")
            case .largest: return L("Plus lourd", "Largest")
            case .smallest: return L("Plus léger", "Smallest")
            case .name: return L("Nom", "Name")
            }
        }

        /// Un fichier sans date connue passe toujours en dernier : il ne doit
        /// pas se retrouver artificiellement en tête d'un tri par récence.
        /// `dates` et `sizes` sont les tables relevées au rechargement : aucun
        /// accès disque n'est fait ici.
        func sorted(_ files: [URL], dates: [URL: Date], sizes: [URL: Int64]) -> [URL] {
            switch self {
            case .newest, .oldest:
                let ascending = self == .oldest
                return files.sorted { lhs, rhs in
                    let left = dates[lhs], right = dates[rhs]
                    switch (left, right) {
                    case let (l?, r?):
                        if l == r { return lhs.lastPathComponent < rhs.lastPathComponent }
                        return ascending ? l < r : l > r
                    case (nil, nil): return lhs.lastPathComponent < rhs.lastPathComponent
                    case (nil, _): return false
                    case (_, nil): return true
                    }
                }
            case .largest, .smallest:
                let ascending = self == .smallest
                return files.sorted { lhs, rhs in
                    let left = sizes[lhs] ?? 0, right = sizes[rhs] ?? 0
                    if left == right { return lhs.lastPathComponent < rhs.lastPathComponent }
                    return ascending ? left < right : left > right
                }
            case .name:
                return files.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            }
        }
    }

    /// Filtre rapide par type, indépendant du filtre de téléchargement.
    enum GalleryKindFilter: String, CaseIterable, Sendable {
        case all, images, videos

        var label: String {
            switch self {
            case .all: return L("Tout", "All")
            case .images: return L("Images", "Images")
            case .videos: return L("Vidéos", "Videos")
            }
        }

        func allows(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            switch self {
            case .all: return true
            case .images: return ["jpg", "jpeg", "png", "gif", "webp"].contains(ext)
            case .videos: return ["mp4", "mov", "m4v"].contains(ext)
            }
        }
    }

    private static func savedMediaCountKey(_ canonical: String) -> String { "savedMediaCount.\(canonical)" }
    private static func lastRunCountKey(_ canonical: String) -> String { "lastRunCount.\(canonical)" }

    private static func loadLastRunCount(_ canonical: String) -> Int? {
        let value = UserDefaults.standard.object(forKey: lastRunCountKey(canonical)) as? NSNumber
        return value?.intValue
    }

    private func recordLastRunCount(_ canonical: String) {
        lastRunCounts[canonical] = count
        UserDefaults.standard.set(count, forKey: Self.lastRunCountKey(canonical))
    }

    static func savedMediaCount(for canonical: String) -> SavedMediaCount? {
        guard let data = UserDefaults.standard.data(forKey: savedMediaCountKey(canonical)) else { return nil }
        return try? JSONDecoder().decode(SavedMediaCount.self, from: data)
    }

    static func clearSavedMediaCount(for canonical: String) {
        UserDefaults.standard.removeObject(forKey: savedMediaCountKey(canonical))
    }
    @Published private var storedConcurrentLimit = UserDefaults.standard.object(forKey: "concurrentLimit") as? Int
    var concurrentLimit: Int {
        get {
            let isXFetish: Bool
            if let source = resolvedSource {
                if case .xFetish = source { isXFetish = true }
                else { isXFetish = false }
            } else { isXFetish = sourceKind == "x" }
            return ConcurrentDownloads.configuredLimit(storedConcurrentLimit, isXFetish: isXFetish)
        }
        set {
            let valid = ConcurrentDownloads.configuredLimit(newValue)
            storedConcurrentLimit = valid
            UserDefaults.standard.set(valid, forKey: "concurrentLimit")
        }
    }
    @Published private(set) var sessionLimit = 3
    @Published var xFetishSegments = XFetishRangeDownload.segmentCount(
        UserDefaults.standard.object(forKey: XFetishRangeDownload.defaultsKey) as? Int) {
        didSet {
            let valid = XFetishRangeDownload.segmentCount(xFetishSegments)
            if valid != xFetishSegments { xFetishSegments = valid }
            UserDefaults.standard.set(valid, forKey: XFetishRangeDownload.defaultsKey)
        }
    }
    @Published private(set) var sessionSegments = XFetishRangeDownload.segmentCount(nil)
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
            let text = username.contains("/") || username.lowercased().contains("redgifs.com")
                || username.hasPrefix("#")
                ? username : "rg/\(username)"
            return try? FeedSource.parse(text)
        }
        // En mode `r`, une adresse de post collée est une sélection, pas un
        // subreddit nommé `pics` : le texte explicite garde la priorité.
        if sourceKind == "r", username.lowercased().contains("reddit.com/") || username.lowercased().contains("redd.it/") {
            return try? FeedSource.parse(username)
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
        // Compteurs « nouveautés » du passage précédent : relus une fois pour
        // que les pastilles les affichent dès l'ouverture, sans attendre un
        // premier parcours.
        for collection in collections {
            if let value = Self.loadLastRunCount(collection.id) { lastRunCounts[collection.id] = value }
        }
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
    /// Clé mémorisant les adresses collées d'une sélection X-Fetish (`x.videos`
    /// ou `x.albums`) : sans modèle, le champ ne peut pas être reconstruit
    /// depuis le seul nom de la collection.
    private static func xFetishSelectionKey(_ canonical: String) -> String {
        "xFetishSelection.\(canonical)"
    }

    /// Même besoin pour une sélection de posts Reddit (`r/posts`) : le champ ne
    /// peut pas être reconstruit depuis le seul nom de collection.
    private static func redditSelectionKey(_ canonical: String) -> String {
        "redditSelection.\(canonical)"
    }

    private func display(_ collection: UserCollection) {
        if collection.isSaved { sourceKind = "saved" }
        else if collection.isTwitter { sourceKind = "tw" }
        else if collection.isXFetish { sourceKind = "x" }
        else if collection.isRedGifs || collection.isRedGifsTag || collection.isRedGifsGif { sourceKind = "rg" }
        else if collection.isSubreddit || collection.isRedditPosts { sourceKind = "r" }
        else { sourceKind = "u" }
        if collection.isXFetish, (collection.name == "videos" || collection.name == "albums") {
            username = UserDefaults.standard.string(forKey: Self.xFetishSelectionKey(collection.id)) ?? ""
        } else if collection.isRedditPosts {
            username = UserDefaults.standard.string(forKey: Self.redditSelectionKey(collection.id)) ?? ""
        } else if collection.isRedGifsTag {
            username = "#\(collection.name)"
        } else if collection.isRedGifsGif {
            username = "redgifs.com/watch/\(collection.name)"
        } else {
            username = collection.name
        }
        // Les filtres sont propres à chaque collection : les recharger ici
        // évite qu'un filtre posé sur une source s'applique silencieusement à
        // la suivante.
        downloadFilter = DownloadFilterStore.load(collection.id)
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
                case .xFetish(let target): sourceKind = "x"; username = target.model ?? UserDefaults.standard.string(forKey: Self.xFetishSelectionKey(source.id)) ?? ""
                case .redgifsUser(let name): sourceKind = "rg"; username = name
                case .redgifsTag(let tag): sourceKind = "rg"; username = "#\(tag)"
                case .redgifsGif(let id): sourceKind = "rg"; username = "redgifs.com/watch/\(id)"
                case .twitterUser(let name): sourceKind = "tw"; username = name
                case .redditPosts: sourceKind = "r"; username = UserDefaults.standard.string(forKey: Self.redditSelectionKey(source.id)) ?? ""
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
            // Les dossiers `r.…`, `saved.…`, `x.…`, `redgifs.…`, `tw.…` et
            // `reddit.…` viennent des subreddits, sauvegardés, profils X-Fetish,
            // comptes RedGifs, comptes X et sélections de posts (le point est
            // impossible dans un pseudo). Les variantes `redgifs.tag.` et
            // `redgifs.gif.` sont testées avant le préfixe `redgifs.` nu.
            if folder.hasPrefix("r."), let sub = try? FeedSource.subredditName(String(folder.dropFirst(2))) {
                collections.append(UserCollection(name: sub, isSubreddit: true))
            } else if folder == "reddit.posts" {
                collections.append(UserCollection(name: "posts", isRedditPosts: true))
            } else if folder.hasPrefix("redgifs.tag."), let tag = try? RedgifsAPI.tag(String(folder.dropFirst(12))) {
                collections.append(UserCollection(name: tag, isRedGifsTag: true))
            } else if folder.hasPrefix("redgifs.gif."), let id = RedgifsAPI.gifID(String(folder.dropFirst(12))) {
                collections.append(UserCollection(name: id, isRedGifsGif: true))
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

    /// Mémorise les filtres de la collection active. Appelé par le panneau de
    /// filtres : sans cet enregistrement, un réglage saisi serait perdu à la
    /// fermeture de la feuille.
    func saveActiveFilter() {
        guard let id = activeUser else { return }
        DownloadFilterStore.save(downloadFilter, for: id)
    }

    /// Compteurs « nouveautés » du passage précédent, pour l'affichage.
    func lastRunCount(for id: String) -> Int? { lastRunCounts[id] }

    func download(user id: String) {
        guard !running else { return }
        if let collection = collections.first(where: { $0.id == id }) {
            display(collection)
        } else if let source = try? FeedSource.parse(id) {
            switch source {
            case .user(let name): sourceKind = "u"; username = name
            case .subreddit(let name): sourceKind = "r"; username = name
            case .saved(let name): sourceKind = "saved"; username = name
            case .xFetish(let target): sourceKind = "x"; username = target.model ?? UserDefaults.standard.string(forKey: Self.xFetishSelectionKey(source.id)) ?? ""
            case .redgifsUser(let name): sourceKind = "rg"; username = name
            case .redgifsTag(let tag): sourceKind = "rg"; username = "#\(tag)"
            case .redgifsGif(let id): sourceKind = "rg"; username = "redgifs.com/watch/\(id)"
            case .twitterUser(let name): sourceKind = "tw"; username = name
            case .redditPosts: sourceKind = "r"; username = UserDefaults.standard.string(forKey: Self.redditSelectionKey(source.id)) ?? ""
            }
        } else {
            username = id
        }
        // Sélection X-Fetish sans adresses mémorisées : afficher la collection
        // sans lancer un parcours du modèle neutre (`videos`/`albums`).
        if sourceKind == "x", username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeUser = id
            UserDefaults.standard.set(id, forKey: "lastUsername")
            reload()
            return
        }
        start()
    }

    private func upsertCollection(_ source: FeedSource) {
        let id = source.id
        if let index = collections.firstIndex(where: { $0.id == id }) {
            collections[index].archived = false
        } else {
            collections.append(UserCollection(source: source))
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
        Self.clearSavedMediaCount(for: id)
        UserDefaults.standard.removeObject(forKey: "xMediaResume.\(id)")
        UserDefaults.standard.removeObject(forKey: Self.xFetishVideoResumeKey(id))
        UserDefaults.standard.removeObject(forKey: Self.xFetishSelectionKey(id))
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
        for collection in collections {
            Self.clearSavedMediaCount(for: collection.id)
            UserDefaults.standard.removeObject(forKey: "xMediaResume.\(collection.id)")
            UserDefaults.standard.removeObject(forKey: Self.xFetishVideoResumeKey(collection.id))
        }
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
            // Les tables de tri décrivent l'ancienne collection : les vider
            // évite d'afficher les fichiers de la nouvelle avec les dates de
            // l'ancienne pendant le scan.
            searchIndex = [:]
            fileDates = [:]
            fileSizes = [:]
            applyGalleryOrdering()
        }
        guard let collection = activeCollection else {
            files = []; totalBytes = 0; reloadTask = nil
            loadingFiles = false
            applyGalleryOrdering()
            return
        }
        loadingFiles = true
        let folder = root.appendingPathComponent(collection.folderName, isDirectory: true)
        reloadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                // L'index de recherche et les attributs de tri sont bâtis avec
                // la liste, hors du fil principal : le rendu ne doit jamais
                // toucher au disque.
                let snapshot = try CollectionFiles.scan(folder)
                let index = Downloader.buildSearchIndex(snapshot.files)
                let facts = Downloader.buildFileFacts(snapshot.files)
                return (snapshot, index, facts)
            }
            do {
                let (snapshot, index, facts) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.reloadRevision == revision else { return }
                self.reloadTask = nil
                self.loadingFiles = false
                // L'ordre est recalculé après l'affectation des tables : sinon
                // le tri par date ou par taille s'appuierait sur des tables
                // encore vides et retomberait sur l'ordre alphabétique.
                self.searchIndex = index
                self.fileDates = facts.dates
                self.fileSizes = facts.sizes
                self.files = snapshot.files
                self.totalBytes = snapshot.totalBytes
                self.applyGalleryOrdering()
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
        sessionSegments = XFetishRangeDownload.segmentCount(xFetishSegments)
        errorMessage = nil
        let target = sourceKind == "saved" ? "saved/" : "\(sourceKind)/\(username)"
        let started = Date()
        LogCenter.info(L("Démarrage : \(target), \(sessionLimit) transferts simultanés.", "Starting: \(target), \(sessionLimit) simultaneous transfers."))
        // Relance manuelle : on oublie les pauses enregistrées et on retente
        // vraiment le serveur au lieu de bloquer en local.
        network.resetRateLimits()
        running = true; discovered = 0; count = 0; status = ""; failed = 0
        scanIncomplete = false
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
                } else if case XFetishError.tooManyPages = error {
                    // X-Fetish compte ses pages à part et signale le plafond en
                    // levant. Ce n'est pas une panne : rien n'est perdu et une
                    // relance reprend après la dernière page parcourue. Le
                    // traiter comme une erreur envoyait une alerte rouge pour
                    // un simple « il reste des pages ».
                    scanIncomplete = true
                    status = L("Parcours incomplet — relance pour continuer", "Scan incomplete — relaunch to continue")
                    LogCenter.info(L("Parcours X-Fetish incomplet après \(Int(Date().timeIntervalSince(started))) s : \(count) conservés. Relance pour continuer.", "Incomplete X-Fetish scan after \(Int(Date().timeIntervalSince(started))) s: \(count) kept. Relaunch to continue."))
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
        var xFetishVideo: XFetishVideos.Video? = nil
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
        if !fm.fileExists(atPath: folder.path) {
            UserDefaults.standard.removeObject(forKey: "xMediaResume.\(canonical)")
            UserDefaults.standard.removeObject(forKey: Self.xFetishVideoResumeKey(canonical))
        }
        // Durcissement : dossier absent ou vide (suppression hors app) → l'historique
        // des posts vus est obsolète, on le purge pour que le run re-télécharge tout.
        if (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.isEmpty ?? true {
            LogCenter.info(L("Dossier absent ou vide : reprise précédente effacée.", "Folder missing or empty: previous checkpoint cleared."))
            UserDefaults.standard.removeObject(forKey: Self.visitedKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.cursorKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.frontierKey(canonical))
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Plafond d'espace : vérifié avant tout parcours, puis à chaque page par
        // `checkStorageQuota`. Un plafond atteint arrête proprement la session
        // au lieu de remplir l'appareil ; les fichiers terminés sont conservés.
        storageLimitReached = false
        try checkStorageQuota(folder: folder, canonical: canonical)
        if case .xFetish(let target) = source {
            // Les adresses collées sont mémorisées : sans modèle, le champ ne
            // pourrait pas être reconstruit au prochain lancement.
            if !target.videos.isEmpty || !target.albums.isEmpty {
                UserDefaults.standard.set(username, forKey: Self.xFetishSelectionKey(canonical))
            }
            try await runXFetish(target: target, canonical: canonical, folder: folder)
            return
        }
        // Comptes X : fil `/media` authentifié, reprise au dernier lot terminé,
        // dédoublonnage par noms de fichiers. Le chemin est séparé avant
        // la reprise RSS, dont la migration v2 est sans objet ici.
        if case .twitterUser(let handle) = source {
            var seenMedia = Set<Media>()
            var usedFilenames = Set<String>()
            var preparedCount = 0
            let completed = try await runTwitter(username: handle, canonical: canonical,
                                                 folder: folder, seenMedia: &seenMedia,
                                                 usedFilenames: &usedFilenames,
                                                 preparedCount: &preparedCount)
            if !completed {
                scanIncomplete = true
                status = L("Parcours X incomplet : relance pour reprendre après la dernière page terminée.", "X scan incomplete: relaunch to resume after the last completed page.")
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
        // Posts Reddit collés : seuls ces posts sont lus, aucun flux parcouru.
        if case .redditPosts(let target) = source {
            UserDefaults.standard.set(username, forKey: Self.redditSelectionKey(canonical))
            try await runRedditSelection(target, canonical: canonical, folder: folder,
                                         seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                                         preparedCount: &preparedCount)
            return
        }
        // Un GIF RedGifs unique ne demande aucun parcours : la route `gif` du
        // chemin existant suffit, et la clé de collection le rend relançable.
        if case .redgifsGif(let gifID) = source {
            let downloads = prepareRedgifsDownloads([gifID], folder: folder,
                seenMedia: &seenMedia, usedFilenames: &usedFilenames, author: canonical)
            if downloads.isEmpty {
                status = L("GIF déjà présent", "GIF already saved")
            } else {
                beginTransferUnit(total: downloads.count)
                try await executeDownloads(downloads, &preparedCount)
                status = count == 0 ? L("GIF déjà présent", "GIF already saved")
                                    : L("\(count) GIF téléchargé", "\(count) GIF downloaded")
            }
            if let index = collections.firstIndex(where: { $0.id == canonical }) {
                collections[index].lastRun = Date()
                saveCollections()
            }
            recordLastRunCount(canonical)
            if failed > 0 {
                let kept = (try? CollectionFiles.scan(folder).files.count) ?? files.count
                errorMessage = L("Média RedGifs inaccessible.\n\(kept) médias conservés.",
                                 "RedGifs media unavailable.\n\(kept) media files kept.")
            }
            return
        }
        // Tags RedGifs : même pagination et même préparation qu'un compte, seule
        // la route de listing change (`/v2/gifs/search`).
        if case .redgifsTag(let tag) = source {
            let completed = try await runRedgifsTag(
                tag: tag, canonical: canonical, folder: folder,
                seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                preparedCount: &preparedCount)
            if let index = collections.firstIndex(where: { $0.id == canonical }) {
                collections[index].lastRun = Date()
                saveCollections()
            }
            recordLastRunCount(canonical)
            if !completed {
                scanIncomplete = true
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
            recordLastRunCount(canonical)
            if !completed {
                scanIncomplete = true
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
        // Older gallery failures were committed as empty posts. Revisit those
        // pages once; the existing filenames still prevent duplicate downloads.
        let galleryMigrationKey = "galleryResolutionVersion.\(canonical)"
        if UserDefaults.standard.integer(forKey: galleryMigrationKey) < 1 {
            UserDefaults.standard.removeObject(forKey: Self.visitedKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.cursorKey(canonical))
            UserDefaults.standard.removeObject(forKey: Self.frontierKey(canonical))
            UserDefaults.standard.set(1, forKey: galleryMigrationKey)
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
                // Plafond d'espace vérifié à chaque page : `prepareDownloads`
                // n'écrit rien, mais la page suivante ne doit pas démarrer si
                // la précédente a rempli le quota.
                try self.checkStorageQuota(folder: folder, canonical: canonical)
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
            let snapshot = try SavedMediaCount(folder: folder)
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.savedMediaCountKey(canonical))
            }
        }
        if let index = collections.firstIndex(where: { $0.id == canonical }) {
            collections[index].lastRun = Date()
            saveCollections()
        }
        recordLastRunCount(canonical)
        if !completed {
            scanIncomplete = true
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
    /// An unfinished video scan resumes its next batch before returning to the head.
    private func runXFetish(target: XFetishAlbums.Target, canonical: String, folder: URL) async throws {
        // Adresses collées : seuls ces albums et vidéos sont téléchargés, sans
        // parcourir le catalogue. Ce sont les adresses qui décident, pas le
        // sélecteur Images / Vidéos.
        if !target.videos.isEmpty || !target.albums.isEmpty {
            try await runXFetishSelected(target: target, canonical: canonical, folder: folder)
            if let index = collections.firstIndex(where: { $0.id == canonical }) {
                collections[index].lastRun = Date()
                saveCollections()
            }
            return
        }
        guard let model = target.model else { throw FeedError.invalidXFetishProfile }
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

        recordLastRunCount(canonical)
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

    /// Téléchargement d'un album déjà connu (catalogue ou adresse collée) :
    /// galerie + fragments Show More, puis mise en file des originaux.
    private func downloadXFetishAlbum(_ album: XFetishAlbums.Album, canonical: String, folder: URL,
                                      savedImageIDs: Set<String>,
                                      seenMedia: inout Set<Media>, usedFilenames: inout Set<String>,
                                      preparedCount: inout Int) async throws {
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

    /// Adresses uniques collées dans le champ : seuls ces albums et vidéos sont
    /// téléchargés, sans lire le catalogue du modèle. Les clés stables
    /// (`xf-…` / `xfv-…`) évitent tout retéléchargement à la relance.
    private func runXFetishSelected(target: XFetishAlbums.Target, canonical: String, folder: URL) async throws {
        var seenMedia = Set<Media>()
        var usedFilenames = Set<String>()
        var preparedCount = 0
        let savedIDs = Set(try CollectionFiles.scan(folder).files.compactMap {
            FilenamePolicy.xFetishMediaID(inFileName: $0.lastPathComponent)
        })
        let savedImageIDs = Set(savedIDs.filter { $0.hasPrefix("xf-") })
        let savedVideoIDs = Set(savedIDs.filter { $0.hasPrefix("xfv-") })
        var seenAlbums = Set<String>()
        var seenVideos = Set<String>()

        for album in target.albums {
            try Task.checkCancellation()
            guard seenAlbums.insert(album.id).inserted else { continue }
            status = L("Album : \(album.title)", "Album: \(album.title)")
            try await downloadXFetishAlbum(album, canonical: canonical, folder: folder,
                                           savedImageIDs: savedImageIDs,
                                           seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                                           preparedCount: &preparedCount)
        }

        // La route signée `get_file` n'est résolue qu'au moment du transfert
        // (voir `save`), jamais mise en file : aucun `v-acctoken` ne vieillit.
        var mediaOverrides: [String: [Media]] = [:]
        var videos: [String: XFetishVideos.Video] = [:]
        var posts: [Post] = []
        for video in target.videos {
            try Task.checkCancellation()
            guard seenVideos.insert(video.id).inserted else { continue }
            guard !savedVideoIDs.contains("xfv-\(video.id)") else { continue }
            let id = "xfv-\(video.id)"
            videos[id] = video
            mediaOverrides[id] = [.direct(video.url)]
            posts.append(Post(id: id, title: video.title, html: "", link: video.url.absoluteString))
        }
        let downloads = try await prepareDownloads(posts, folder: folder,
            seenMedia: &seenMedia, usedFilenames: &usedFilenames,
            author: canonical, mediaOverrides: mediaOverrides, xFetishVideos: videos)
        beginTransferUnit(total: downloads.count)
        try await executeDownloads(downloads, &preparedCount)
        LogCenter.info(L("X-Fetish sélection : \(preparedCount) médias préparés.", "X-Fetish selection: \(preparedCount) media prepared."))
        if failed > 0 {
            status = ""
            let kept = (try? CollectionFiles.scan(folder).files.count) ?? files.count
            errorMessage = L("\(failed) médias inaccessibles ou non enregistrés.\n\(kept) médias conservés.",
                             "\(failed) media unavailable or unsaved.\n\(kept) media files kept.")
            return
        }
        status = count == 0 ? L("Aucun nouveau média accessible", "No new accessible media")
                            : L("\(count) médias téléchargés", "\(count) media downloaded")
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
                try await downloadXFetishAlbum(album, canonical: canonical, folder: folder,
                                               savedImageIDs: savedImageIDs,
                                               seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                                               preparedCount: &preparedCount)
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
        let resumeKey = Self.xFetishVideoResumeKey(canonical)
        let firstPage = max(1, UserDefaults.standard.integer(forKey: resumeKey))
        var scannedPages = 0
        var scannedVideos = 0
        let completed = try await XFetishVideos.run(page: firstPage, fetch: { page in
            scannedPages += 1
            status = L("Recherche des vidéos X-Fetish… page \(page)", "Finding X-Fetish videos… page \(page)")
            let listingData = try await network.data(XFetishVideos.listingURL(model: model, page: page))
            let listing = try XFetishVideos.parseListing(listingData, model: model, page: page)
            LogCenter.info(L("X-Fetish vidéos : page \(page), \(listing.videos.count) vidéos.", "X-Fetish videos: page \(page), \(listing.videos.count) videos."))
            return listing
        }, process: { listed in
            scannedVideos = listed.count
            let pending = listed.filter { !savedVideoIDs.contains("xfv-\($0.id)") }
            // La liste ne garde que les pages publiques, jamais les URL signées.
            // Chaque worker résout sa vidéo dès qu'un transfert se libère : aucun
            // `v-acctoken` ne vieillit dans une file ou derrière un lot lent.
            var mediaOverrides: [String: [Media]] = [:]
            var videos: [String: XFetishVideos.Video] = [:]
            let posts = pending.map { video -> Post in
                let id = "xfv-\(video.id)"
                videos[id] = video
                mediaOverrides[id] = [.direct(video.url)]
                return Post(id: id, title: video.title, html: "", link: video.url.absoluteString)
            }
            let downloads = try await prepareDownloads(posts, folder: folder,
                seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                author: canonical, mediaOverrides: mediaOverrides, xFetishVideos: videos)
            beginTransferUnit(total: downloads.count)
            try await executeDownloads(downloads, &preparedCount)
        }, persist: { next in
            if let next { UserDefaults.standard.set(next, forKey: resumeKey) }
            else { UserDefaults.standard.removeObject(forKey: resumeKey) }
        })
        LogCenter.info(L("X-Fetish vidéos : \(scannedPages) pages, \(scannedVideos) vidéos, \(preparedCount) médias préparés.", "X-Fetish videos: \(scannedPages) pages, \(scannedVideos) videos, \(preparedCount) media prepared."))
        if !completed { throw XFetishError.tooManyPages }
    }

    /// Parcours du fil `/media` d'un compte X.
    ///
    /// Le curseur est conservé uniquement pendant un parcours incomplet.
    /// Après la fin, le parcours suivant revient aux publications récentes.
    /// Les clés `xm-…` / `xmv-…` évitent de retélécharger les fichiers présents.
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
        let resumeKey = "xMediaResume.\(canonical)"
        let stored = UserDefaults.standard.dictionary(forKey: resumeKey) as? [String: String]
        let resumeCursor = stored?["userID"] == userID ? stored?["cursor"] : nil
        var scanned = Set<String>()
        var scannedPages = 0
        let completed = try await XMediaTraversal.run(cursor: resumeCursor, fetch: { cursor in
            scannedPages += 1
            self.status = L("Recherche des médias X… page \(scannedPages)", "Searching X media… page \(scannedPages)")
            let data = try await self.fetchXMediaPage(userID: userID, cursor: cursor)
            let page = try XTwitterMedia.parseMediaPage(data)
            LogCenter.info(L("X : page \(scannedPages), \(page.posts.count) posts avec média.", "X: page \(scannedPages), \(page.posts.count) posts with media."))
            return page
        }, process: { pagePosts -> Bool in
            var fresh: [XPost] = []
            for post in pagePosts where scanned.insert(post.id).inserted {
                // Un média déjà enregistré ne vaut pas une seconde page à relire
                // pour lui : le post entier est écarté si tous ses médias sont là.
                let missing = post.media.filter { !savedIDs.contains($0.storageKey) }
                guard !missing.isEmpty else { continue }
                fresh.append(XPost(id: post.id, text: post.text, publishedAt: post.publishedAt, media: missing))
            }
            // Rien de nouveau sur cette page : le parcours la comptera comme
            // « rattrapé ». Un média en échec reste `missing`, donc sa page est
            // toujours considérée comme nouvelle et se voit retenter.
            guard !fresh.isEmpty else { return false }

            var mediaOverrides: [String: [Media]] = [:]
            var posts: [Post] = []
            for post in fresh {
                for media in post.media {
                    // L'identifiant du média entre dans le nom de fichier :
                    // c'est lui que `FilenamePolicy.xMediaID` relit au
                    // lancement suivant pour ne pas retélécharger. Un
                    // identifiant de post ne conviendrait pas, un même média
                    // pouvant apparaître dans plusieurs posts. `storageKey`
                    // est la forme canonique, écrite à côté de sa lecture.
                    let id = media.storageKey
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
            return true
        }, persist: { cursor in
            if let cursor {
                UserDefaults.standard.set(["userID": userID, "cursor": cursor], forKey: resumeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: resumeKey)
            }
        })
        guard completed else { return false }

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

    /// Résout `@pseudo` en identifiant numérique, la seule forme acceptée par
    /// la route `/media`. Le succès vaut aussi preuve que l'API accepte la
    /// session, d'où l'enregistrement ci-dessous.
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
    private static func xFetishVideoResumeKey(_ canonical: String) -> String { "xFetishVideoResume.\(canonical)" }
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
        try await runRedgifsList(label: username, canonical: canonical, folder: folder,
                                 seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                                 preparedCount: &preparedCount) { page in
            try await self.fetchRedgifsUserPage(username: username, page: page)
        }
    }

    /// Tag ou mot-clé : même pagination que la recherche de compte, seule la
    /// route diffère. Le parcours est partagé pour que les deux ne puissent pas
    /// diverger sur la reprise ou le dédoublonnage.
    private func runRedgifsTag(tag: String, canonical: String, folder: URL,
                               seenMedia: inout Set<Media>, usedFilenames: inout Set<String>,
                               preparedCount: inout Int) async throws -> Bool {
        try await runRedgifsList(label: "#\(tag)", canonical: canonical, folder: folder,
                                 seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                                 preparedCount: &preparedCount) { page in
            try await self.fetchRedgifsSearchPage(tag: tag, page: page)
        }
    }

    /// Parcours commun aux listes RedGifs (compte ou tag).
    private func runRedgifsList(label: String, canonical: String, folder: URL,
                                seenMedia: inout Set<Media>, usedFilenames: inout Set<String>,
                                preparedCount: inout Int,
                                fetch: (Int) async throws -> RedgifsUserSearchResponse) async throws -> Bool {
        var visited = Set(UserDefaults.standard.stringArray(forKey: Self.visitedKey(canonical)) ?? [])
        var orderedVisited = UserDefaults.standard.stringArray(forKey: Self.visitedKey(canonical)) ?? []
        var seenPages = Set<[String]>()
        for page in 1...100 {
            try Task.checkCancellation()
            status = L("Recherche RedGifs… page \(page)", "Searching RedGifs… page \(page)")
            LogCenter.net(L("RedGifs \(label) : page \(page) demandée…", "RedGifs \(label): page \(page) requested…"))
            let response = try await fetch(page)
            let ids = response.gifs.map(\.id)
            LogCenter.net(L("RedGifs \(label) : page \(page) reçue, \(ids.count) médias.", "RedGifs \(label): page \(page) received, \(ids.count) media."))
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

    /// Page de recherche par tag. Même décodage que la recherche de compte :
    /// seule l'adresse diffère, la forme de la réponse est identique.
    private func fetchRedgifsSearchPage(tag: String, page: Int) async throws -> RedgifsUserSearchResponse {
        let bearer = try await redgifsToken()
        do {
            let data = try await network.data(
                RedgifsAPI.searchURL(text: tag, page: page),
                bearer: bearer, headers: RedgifsAPI.headers(id: tag))
            return try JSONDecoder().decode(RedgifsUserSearchResponse.self, from: data)
        } catch NetworkError.refused(let code) where code == 401 {
            token = nil
            let bearer = try await redgifsToken()
            let data = try await network.data(
                RedgifsAPI.searchURL(text: tag, page: page),
                bearer: bearer, headers: RedgifsAPI.headers(id: tag))
            return try JSONDecoder().decode(RedgifsUserSearchResponse.self, from: data)
        } catch NetworkError.refused(let code) where code == 404 {
            throw NetworkError.invalid(L("Aucun contenu RedGifs pour « \(tag) ».", "No RedGifs content for “\(tag)”."))
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

    /// Plafond d'espace disque, vérifié avant un parcours. Lève une erreur qui
    /// n'est pas une panne : la session s'arrête proprement et les fichiers
    /// terminés restent en place.
    private func checkStorageQuota(folder: URL, canonical: String) throws {
        guard storageQuota.isActive else { return }
        let used = (try? CollectionFiles.scan(folder).totalBytes) ?? totalBytes
        guard storageQuota.isReached(currentBytes: used) else { return }
        storageLimitReached = true
        LogCenter.info(L("Plafond d’espace atteint (\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) sur \(ByteCountFormatter.string(fromByteCount: storageQuota.bytes, countStyle: .file))) : parcours arrêté.",
                         "Storage limit reached (\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: storageQuota.bytes, countStyle: .file))): scan stopped."))
        throw NetworkError.invalid(L("Plafond d’espace atteint : \(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) utilisés. Augmente la limite dans les Réglages ou supprime des médias.",
                                     "Storage limit reached: \(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) used. Raise the limit in Settings or delete media."))
    }

    private func recordTransferredItem() {
        guard var unit = transferUnit else { return }
        unit.done = min(unit.done + 1, unit.total)
        transferUnit = unit
    }

    private func recordVideoProgress(_ id: String, received: Int64, total: Int64) {
        // Late callbacks from a cancelled or completed attempt must not update a new unit.
        guard total > 0, var unit = transferUnit, unit.inFlight[id] != nil else { return }
        unit.inFlight[id] = min(1, Double(received) / Double(total))
        transferUnit = unit
    }

    /// Posts Reddit collés dans le champ : seuls ces posts sont lus, sans
    /// parcourir de flux. Le JSON du post fournit son titre, sa date et ses
    /// médias — la même route que la résolution des galeries, qui expose aussi
    /// les crossposts et les vidéos `v.redd.it`.
    private func runRedditSelection(_ target: RedditPostRef.Target, canonical: String,
                                    folder: URL, seenMedia: inout Set<Media>,
                                    usedFilenames: inout Set<String>,
                                    preparedCount: inout Int) async throws {
        var prepared = 0
        for post in target.posts {
            try Task.checkCancellation()
            status = L("Post \(post.id.dropFirst(3))…", "Post \(post.id.dropFirst(3))…")
            guard let url = RedditPostRef.jsonURL(for: post) else { continue }
            let data: Data
            do {
                data = try await network.data(url)
            } catch {
                // Un post supprimé ne doit pas annuler la sélection entière.
                if case NetworkError.refused(let code) = error, code == 404 || code == 410 {
                    LogCenter.info(L("Post introuvable, ignoré : \(post.id).", "Post not found, skipped: \(post.id)"))
                    failed += 1
                    continue
                }
                throw error
            }
            let resolved = try RedditPostRef.parsePost(data, fallback: post)
            guard !resolved.media.isEmpty else {
                LogCenter.info(L("Post sans média pris en charge, ignoré : \(post.id).", "Post without supported media, skipped: \(post.id)"))
                continue
            }
            let downloads = try await prepareDownloads(
                [Post(id: resolved.id, title: resolved.title, html: "",
                      publishedAt: resolved.publishedAt, link: resolved.url.absoluteString)],
                folder: folder, seenMedia: &seenMedia, usedFilenames: &usedFilenames,
                author: canonical, mediaOverrides: [resolved.id: resolved.media])
            prepared += downloads.count
            beginTransferUnit(total: downloads.count)
            try await executeDownloads(downloads, &preparedCount)
        }
        LogCenter.info(L("Posts collés : \(target.posts.count) lus, \(prepared) médias à prendre.", "Pasted posts: \(target.posts.count) read, \(prepared) media to fetch."))
        if let index = collections.firstIndex(where: { $0.id == canonical }) {
            collections[index].lastRun = Date()
            saveCollections()
        }
        recordLastRunCount(canonical)
        if failed > 0 {
            let kept = (try? CollectionFiles.scan(folder).files.count) ?? files.count
            errorMessage = L("\(failed) posts introuvables ou sans média.\n\(kept) médias conservés.",
                             "\(failed) posts missing or without media.\n\(kept) media files kept.")
            return
        }
        status = count == 0 ? L("Aucun nouveau média accessible", "No new accessible media")
                            : L("\(count) médias téléchargés", "\(count) media downloaded")
    }

    /// Keeps naming, deduplication and legacy migration identical across feed pages.
    /// Les posts galerie (lien `/gallery/` sans média direct) sont résolus via    /// le JSON du post, comme la prévisualisation : images `i.redd.it` et
    /// vidéos `v.redd.it` (DASH). Un échec galerie ignore juste ce post, sauf
    /// un refus HTTP 429 qui arrête la session comme n'importe quel autre.
    private func prepareDownloads(_ posts: [Post], folder: URL,
                                   seenMedia: inout Set<Media>,
                                   usedFilenames: inout Set<String>,
                                   author: String = "",
                                   mediaOverrides: [String: [Media]] = [:],
                                   mediaHeaders: [String: [String: String]] = [:],
                                   xFetishVideos: [String: XFetishVideos.Video] = [:]) async throws -> [Download] {
        var galleryLists: [String: [Media]] = [:]
        let candidates = posts.filter { mediaOverrides[$0.id] == nil && MediaExtractor.extract($0.html).isEmpty && GalleryFeed.linked($0.html) }
        if !candidates.isEmpty {
            // Borné au même plafond que les transferts : une page de 100 posts
            // galerie lançait auparavant 100 requêtes simultanées vers
            // reddit.com, très au-delà du réglage affiché et du budget serveur.
            let limit = max(1, sessionLimit)
            try await withThrowingTaskGroup(of: (String, [Media]).self) { group in
                var next = 0
                func enqueue(until target: Int) {
                    while next < min(target, candidates.count) {
                        let post = candidates[next]
                        next += 1
                        group.addTask {
                            let list = try await GalleryFeed.resolve {
                                try await self.previewGalleryMedia(feedID: post.id, galleryID: GalleryFeed.linkedID(post.html))
                            }
                            return (post.id, list)
                        }
                    }
                }
                enqueue(until: limit)
                for try await (id, list) in group {
                    galleryLists[id] = list
                    enqueue(until: next + 1)
                }
            }
            try Task.checkCancellation()
        }
        var downloads: [Download] = []
        var renamedExisting = false
        var skippedExisting = 0
        var skippedSeen = 0
        var skippedFilter = 0
        let filter = downloadFilter
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
                // Filtres appliqués avant toute mise en file : un média écarté
                // n'est jamais demandé au réseau. Le post reste « vu », sinon un
                // filtre exigeant ferait relire tout le flux à chaque lancement.
                if filter.isActive {
                    let kind = Self.mediaKind(for: item, xFetishVideo: xFetishVideos[post.id] != nil)
                    guard filter.allows(kind: kind, title: post.title, publishedAt: post.publishedAt) else {
                        skippedFilter += 1
                        continue
                    }
                }
                let ext: String
                // Une URL de média X porte son format dans le chemin pour les vidéos, mais
                // `pbs.twimg.com/media/<id>.jpg` peut être servie en `png` ou
                // `webp` : le chemin reste donc la seule source fiable ici, et
                // une extension vide se replie sur `jpg`.
                if xFetishVideos[post.id] != nil { ext = "mp4" }
                else if case .direct(let url) = item {
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
                    downloads.append(Download(media: item, destination: destination, postDate: post.publishedAt, author: author, postLink: postLink, headers: mediaHeaders[item.key], xFetishVideo: xFetishVideos[post.id]))
                }
            }
        }
        if skippedExisting > 0 || skippedSeen > 0 || skippedFilter > 0 {
            LogCenter.info(L("Déjà là : \(skippedExisting) fichiers, \(skippedSeen) médias déjà vus, \(skippedFilter) écartés par les filtres.", "Already here: \(skippedExisting) files, \(skippedSeen) media seen, \(skippedFilter) filtered out."))
        }
        if renamedExisting { reload() }
        return downloads
    }

    /// Nature d'un média candidat, pour les filtres. Une vidéo Reddit ou
    /// X-Fetish est une vidéo ; un GIF animé X arrive en `.mp4` et compte comme
    /// vidéo, faute d'information contraire dans le flux.
    private static func mediaKind(for media: Media, xFetishVideo: Bool) -> DownloadFilter.MediaKind {
        if xFetishVideo { return .video }
        switch media {
        case .redditVideo: return .video
        case .redgifs: return .gif
        case .direct(let url):
            let ext = url.pathExtension.lowercased()
            if ["mp4", "mov", "m4v"].contains(ext) { return .video }
            if ext == "gif" { return .gif }
            return .image
        }
    }

    /// Relance bornée sur erreur transitoire (réseau mobile instable) :
    /// 3 essais max, backoff 2s/4s. Le 429 est exclu : il est déjà converti en
    /// `NetworkError.limited` par `Network.check` et n'est jamais réessayé.
    /// La règle elle-même est testée dans `RetryPolicy`.
    private func saveWithRetry(_ item: Download) async throws {
        var attempt = 0
        while true {
            do {
                return try await save(item)
            } catch {
                guard RetryPolicy.shouldRetry(error, attempt: attempt) else { throw error }
                attempt += 1
                LogCenter.net(L("Réseau instable, nouvel essai \(attempt)/2 pour \(item.destination.lastPathComponent)…", "Unstable network, retry \(attempt)/2 for \(item.destination.lastPathComponent)…"))
                try await Task.sleep(for: RetryPolicy.delay(forAttempt: attempt))
            }
        }
    }

    /// Un média supprimé ou inaccessible (ex. HTTP 404 ou 403 vidéo après
    /// renouvellement) ne doit pas annuler tout le parcours : on le
    /// comptabilise et on continue avec les autres. Seules l'annulation, les
    /// erreurs de flux RSS et un HTTP 429 restent fatales.
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
        let progressID = UUID().uuidString
        defer { transferUnit?.inFlight.removeValue(forKey: progressID) }
        let temporary: URL
        if let video = item.xFetishVideo {
            transferUnit?.inFlight[progressID] = 0
            // Anti-hotlink : le stockage exige le Referer de la page vidéo.
            let headers = XFetishAPI.headers(referer: video.url, accept: XFetishAPI.videoAccept)
            temporary = try await XFetishVideos.download(video, page: { url in
                try await self.network.data(url, headers: headers)
            }, transfer: { url, attempt in
                // Premier essai avec les morceaux choisis, second essai propre
                // en connexion unique avec une URL fraîche.
                let segments = attempt == 0 ? self.sessionSegments : 1
                return try await self.network.downloadXFetishVideo(url, segments: segments, headers: headers,
                    progress: { received, total in
                        Task { @MainActor in self.recordVideoProgress(progressID, received: received, total: total) }
                    })
            })
        } else {
            temporary = try await resolveAndDownload(item.media, headers: item.headers)
        }
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
        // Une seule lecture des attributs, réutilisée pour le total et pour la
        // table de tri : `files.insert` seul laisserait le tri par date ou par
        // taille sans entrée pour ce fichier.
        let attributes = try? item.destination.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let size = Int64(attributes?.fileSize ?? 0)
        files.insert(item.destination, at: 0)
        totalBytes += size
        fileSizes[item.destination] = size
        if let date = item.postDate ?? attributes?.creationDate { fileDates[item.destination] = date }
        applyGalleryOrdering()
        count += 1
        LogCenter.info(L("Gardé : \(item.destination.lastPathComponent) (\(count)/\(discovered)).", "Kept: \(item.destination.lastPathComponent) (\(count)/\(discovered))."))
        // A scan started before this save must not overwrite the newly inserted file.
        if reloadTask != nil { invalidateReload() }
    }

    /// Écarte un scan en cours sans en lancer un nouveau. `save()` vient
    /// d'insérer le fichier dans `files` et d'ajuster `totalBytes` : rescanner le
    /// dossier entier après chaque téléchargement coûterait O(n²) en `stat` sur
    /// une grosse collection, pour un résultat identique. Le seul risque réel
    /// est qu'un scan démarré avant l'insertion n'écrase la liste affichée —
    /// invalider sa révision suffit à l'en empêcher.
    private func invalidateReload() {
        reloadTask?.cancel()
        reloadRevision += 1
        reloadTask = nil
        loadingFiles = false
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
        // Atomic write retains the original if staging or publication fails.
        try? output.write(to: url, options: .atomic)
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
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mp4" : ext)
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
            try MediaFileReplacement.replace(url, with: temp)
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

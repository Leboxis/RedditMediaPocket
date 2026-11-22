import Foundation

/// Élément repéré en tête du site source lors d'une vérification de fraîcheur
/// par rapport à kDrive.
public enum KDriveSourceItem: Hashable, Sendable {
    case redditPost(id: String, title: String)
    case redgifs(id: String)
    case xMedia(storageKey: String, title: String)
    case tikTokMedia(storageKey: String, title: String)
    case instagramMedia(storageKey: String, title: String)
    case xFetishAlbum(albumID: String)
    case xFetishImage(albumID: String, imageID: String, title: String)
    case xFetishVideo(videoID: String, title: String)

    /// Convertit une première page de posts Reddit en éléments vérifiables.
    /// Seuls les posts porteurs d'au moins un média téléchargeable (image,
    /// vidéo, RedGifs ou galerie) sont retenus : les posts purement textuels
    /// épinglés en tête d'un profil ou d'un subreddit ne faussent pas l'état.
    public static func fromRedditPosts(_ posts: [Post]) -> [KDriveSourceItem] {
        var seen = Set<String>()
        var items: [KDriveSourceItem] = []
        for post in posts {
            let hasGalleryMedia = !(post.galleryMedia ?? []).isEmpty
            let hasInlineMedia = !MediaExtractor.extract(post.html).isEmpty
            let hasLinkedGallery = GalleryFeed.linked(post.html)
            guard hasGalleryMedia || hasInlineMedia || hasLinkedGallery else { continue }
            let short = Self.cleanRedditPostID(post.id)
            guard !short.isEmpty, seen.insert(short).inserted else { continue }
            items.append(.redditPost(id: short, title: post.title))
        }
        return items
    }

    public static func fromRedgifsIDs(_ ids: [String]) -> [KDriveSourceItem] {
        var seen = Set<String>()
        var items: [KDriveSourceItem] = []
        for raw in ids {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            items.append(.redgifs(id: clean))
        }
        return items
    }

    public static func fromXPosts(_ posts: [XPost]) -> [KDriveSourceItem] {
        var seen = Set<String>()
        var items: [KDriveSourceItem] = []
        for post in posts {
            for media in post.media {
                let key = media.storageKey
                guard seen.insert(key).inserted else { continue }
                items.append(.xMedia(storageKey: key, title: post.text))
            }
        }
        return items
    }

    public static func fromTikTokPosts(_ posts: [TikTokPost]) -> [KDriveSourceItem] {
        var seen = Set<String>()
        var items: [KDriveSourceItem] = []
        for post in posts {
            for media in post.media {
                let key = media.storageKey
                guard seen.insert(key).inserted else { continue }
                items.append(.tikTokMedia(storageKey: key, title: post.text))
            }
        }
        return items
    }

    public static func fromInstagramPosts(_ posts: [InstagramPost]) -> [KDriveSourceItem] {
        var seen = Set<String>()
        var items: [KDriveSourceItem] = []
        for post in posts {
            for media in post.media {
                let key = media.storageKey
                guard seen.insert(key).inserted else { continue }
                items.append(.instagramMedia(storageKey: key, title: post.text))
            }
        }
        return items
    }

    public static func fromXFetish(
        albums: [XFetishAlbums.Album] = [],
        videos: [XFetishVideos.Video] = []
    ) -> [KDriveSourceItem] {
        var items: [KDriveSourceItem] = []
        var seenAlbums = Set<String>()
        for album in albums where !album.id.isEmpty && seenAlbums.insert(album.id).inserted {
            items.append(.xFetishAlbum(albumID: album.id))
        }
        var seenVideos = Set<String>()
        for video in videos where !video.id.isEmpty && seenVideos.insert(video.id).inserted {
            items.append(.xFetishVideo(videoID: video.id, title: video.title))
        }
        return items
    }

    static func cleanRedditPostID(_ raw: String) -> String {
        var short = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if short.lowercased().hasPrefix("t3_") {
            short = String(short.dropFirst(3))
        }
        short = short.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return short.lowercased()
    }
}

/// Index en mémoire des fichiers présents dans un dossier kDrive (ou local),
/// permettant de vérifier en O(1) si les médias récents d'une source y figurent.
public struct KDriveRemoteIndex: Sendable, Equatable {
    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "mp4", "mov", "m4v"
    ]

    public let totalFiles: Int
    public let normalizedFileNames: Set<String>
    public let normalizedStems: Set<String>
    public let xMediaIDs: Set<String>
    public let tikTokMediaIDs: Set<String>
    public let instagramMediaIDs: Set<String>
    public let xFetishMediaIDs: Set<String>
    public let xFetishAlbumIDs: Set<String>
    public let trailingPostIDs: Set<String>

    public init<S: Sequence>(fileNames: S) where S.Element == String {
        var count = 0
        var normNames = Set<String>()
        var normStems = Set<String>()
        var xIDs = Set<String>()
        var ttIDs = Set<String>()
        var igIDs = Set<String>()
        var xfIDs = Set<String>()
        var xfAlbums = Set<String>()
        var postIDs = Set<String>()

        for name in fileNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            count += 1
            normNames.insert(FilenamePolicy.kDriveNormalizedName(trimmed))

            let url = URL(fileURLWithPath: trimmed)
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent
            let cleanStem = Self.stripCollisionSuffix(from: stem)
            normStems.insert(FilenamePolicy.kDriveNormalizedName(stem))
            normStems.insert(FilenamePolicy.kDriveNormalizedName(cleanStem))

            if let xID = FilenamePolicy.xMediaID(inFileName: trimmed) {
                xIDs.insert(xID)
            }
            if let ttID = FilenamePolicy.tikTokMediaID(inFileName: trimmed) {
                ttIDs.insert(ttID)
            }
            if let igID = FilenamePolicy.instagramMediaID(inFileName: trimmed) {
                igIDs.insert(igID)
            }
            if let xfID = FilenamePolicy.xFetishMediaID(inFileName: trimmed) {
                xfIDs.insert(xfID)
                if xfID.hasPrefix("xf-") {
                    let parts = xfID.dropFirst(3).split(separator: "-")
                    if let albumID = parts.first, !albumID.isEmpty {
                        xfAlbums.insert(String(albumID))
                    }
                }
            }
            if Self.mediaExtensions.contains(ext) || ext.isEmpty {
                if let trailing = Self.extractTrailingPostID(fromStem: stem) {
                    postIDs.insert(trailing)
                }
            }
        }

        self.totalFiles = count
        self.normalizedFileNames = normNames
        self.normalizedStems = normStems
        self.xMediaIDs = xIDs
        self.tikTokMediaIDs = ttIDs
        self.instagramMediaIDs = igIDs
        self.xFetishMediaIDs = xfIDs
        self.xFetishAlbumIDs = xfAlbums
        self.trailingPostIDs = postIDs
    }

    /// Vérifie si un fichier local (par son `lastPathComponent`) est déjà
    /// présent dans ce dossier kDrive (nom assaini ou repli 422).
    public func containsLocalFile(_ fileName: String) -> Bool {
        let candidates = FilenamePolicy.kDriveRemoteCandidateNames(for: fileName)
        return candidates.contains {
            normalizedFileNames.contains(FilenamePolicy.kDriveNormalizedName($0))
        }
    }

    /// Vérifie si un élément issu de la première page du site source est
    /// déjà présent dans ce dossier kDrive.
    public func contains(_ item: KDriveSourceItem) -> Bool {
        switch item {
        case .redditPost(let id, let title):
            let short = KDriveSourceItem.cleanRedditPostID(id)
            guard !short.isEmpty else { return false }
            if trailingPostIDs.contains(short) || normalizedStems.contains(short) {
                return true
            }
            let stems = [
                FilenamePolicy.downloadStem(title: title, postID: short, position: nil),
                FilenamePolicy.downloadStem(title: title, postID: short, position: 1)
            ]
            return matchesCandidateStems(stems, extensions: ["jpg", "jpeg", "png", "webp", "gif", "mp4", "mov", "m4v"])

        case .redgifs(let id):
            let clean = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty else { return false }
            if trailingPostIDs.contains(clean) || normalizedStems.contains(clean) {
                return true
            }
            let stem = FilenamePolicy.downloadStem(title: "", postID: clean)
            return matchesCandidateStems([stem], extensions: ["mp4", "gif", "webm"])

        case .xMedia(let storageKey, let title):
            if xMediaIDs.contains(storageKey) { return true }
            let stem = FilenamePolicy.downloadStem(title: title, postID: storageKey)
            return matchesCandidateStems([stem], extensions: ["jpg", "jpeg", "png", "webp", "gif", "mp4"])

        case .tikTokMedia(let storageKey, let title):
            if tikTokMediaIDs.contains(storageKey) { return true }
            let stem = FilenamePolicy.downloadStem(title: title, postID: storageKey)
            return matchesCandidateStems([stem], extensions: ["mp4", "jpg", "jpeg", "webp"])

        case .instagramMedia(let storageKey, let title):
            if instagramMediaIDs.contains(storageKey) { return true }
            let stem = FilenamePolicy.downloadStem(title: title, postID: storageKey)
            return matchesCandidateStems([stem], extensions: ["jpg", "jpeg", "webp", "mp4"])

        case .xFetishAlbum(let albumID):
            return xFetishAlbumIDs.contains(albumID)

        case .xFetishImage(let albumID, let imageID, let title):
            let key = "xf-\(albumID)-\(imageID)"
            if xFetishMediaIDs.contains(key) { return true }
            let stem = FilenamePolicy.downloadStem(title: title, postID: key)
            return matchesCandidateStems([stem], extensions: ["jpg", "jpeg", "png", "webp", "gif"])

        case .xFetishVideo(let videoID, let title):
            let key = "xfv-\(videoID)"
            if xFetishMediaIDs.contains(key) { return true }
            let stem = FilenamePolicy.downloadStem(title: title, postID: key)
            return matchesCandidateStems([stem], extensions: ["mp4", "mov", "m4v"])
        }
    }

    private func matchesCandidateStems(_ stems: [String], extensions: [String]) -> Bool {
        for stem in stems {
            if normalizedStems.contains(FilenamePolicy.kDriveNormalizedName(stem)) {
                return true
            }
            for ext in extensions {
                let candidateFile = "\(stem).\(ext)"
                for remote in FilenamePolicy.kDriveRemoteCandidateNames(for: candidateFile) {
                    if normalizedFileNames.contains(FilenamePolicy.kDriveNormalizedName(remote)) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Extrait l'identifiant final après le dernier « - » (ex. `Titre - 1ghwxnf`
    /// ou `Galerie 1 - 1ghwxnf-2` -> `1ghwxnf`), ou le stem nu s'il s'agit d'un
    /// identifiant simple (ex. `upsettrash3094.mp4`).
    static func extractTrailingPostID(fromStem stem: String) -> String? {
        let rawCandidate: String
        if let range = stem.range(of: " - ", options: .backwards) {
            rawCandidate = String(stem[range.upperBound...])
        } else {
            rawCandidate = stem
        }
        let cleaned = stripCollisionSuffix(from: rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines))
            .lowercased()
        guard !cleaned.isEmpty else { return nil }
        for prefix in ["xf-", "xfv-", "xm-", "xmv-", "tkv-", "tkm-", "igm-", "igv-"] {
            if cleaned.hasPrefix(prefix) { return nil }
        }
        guard cleaned.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) || byte == 95
        }) else {
            return nil
        }
        return cleaned
    }

    /// Retire un suffixe numérique de collision (`-2`, `-3`, …) ajouté par
    /// `prepareDownloads` quand deux fichiers ont le même stem.
    private static func stripCollisionSuffix(from value: String) -> String {
        guard let dashIndex = value.lastIndex(of: "-") else { return value }
        let after = value[value.index(after: dashIndex)...]
        let before = value[..<dashIndex]
        guard !before.isEmpty,
              !after.isEmpty,
              after.count <= 3,
              after.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return value
        }
        return String(before)
    }
}

/// État de fraîcheur d'une collection sur kDrive par rapport à son site source.
public enum KDriveFreshnessStatus: Equatable, Sendable {
    /// Vérification en cours (kDrive + site source).
    case checking
    /// Tous les médias récents de la source (et les fichiers locaux) sont sur kDrive.
    case upToDate(remoteCount: Int, checkedSourceCount: Int)
    /// La source n'a aucun média inconnu de l'appareil, mais des fichiers
    /// téléchargés localement sur l'iPhone n'ont pas encore été envoyés sur kDrive.
    case pendingUpload(localPendingCount: Int, remoteCount: Int)
    /// Le site source publie des médias récents qui ne figurent pas encore sur kDrive.
    case outdated(newOnSourceCount: Int, fullPageMissing: Bool, localPendingCount: Int, remoteCount: Int)
    /// Aucun dossier correspondant à cette collection n'existe encore sur kDrive.
    case notOnDrive(sourceNewCount: Int, localPendingCount: Int)
    /// La source n'a pas pu être sondée (session requise, hors ligne, erreur).
    case unavailable(reason: String)

    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    public var isUpToDate: Bool {
        if case .upToDate = self { return true }
        return false
    }

    public var needsAttention: Bool {
        switch self {
        case .outdated, .pendingUpload, .notOnDrive:
            return true
        case .checking, .upToDate, .unavailable:
            return false
        }
    }

    /// Nom d'icône SF Symbol associé à l'état.
    public var symbolName: String {
        switch self {
        case .checking:
            return "arrow.triangle.2.circlepath.icloud"
        case .upToDate:
            return "checkmark.icloud.fill"
        case .pendingUpload:
            return "icloud.and.arrow.up.fill"
        case .outdated:
            return "exclamationmark.icloud.fill"
        case .notOnDrive:
            return "icloud.slash"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Texte court pour pastille (chip) ou badge compact.
    public var badgeText: String {
        switch self {
        case .checking:
            return L("Vérif…", "Checking…")
        case .upToDate:
            return L("À jour", "Up to date")
        case .pendingUpload(let local, _):
            return L("\(local) à envoyer", "\(local) to upload")
        case .outdated(let count, let fullPage, _, _):
            let suffix = fullPage ? "+" : ""
            return L("+\(count)\(suffix) source", "+\(count)\(suffix) source")
        case .notOnDrive:
            return L("Hors kDrive", "Not on kDrive")
        case .unavailable:
            return L("Non vérifié", "Unverified")
        }
    }

    /// Résumé lisible affiché dans les listes, bannières et détails de collection.
    public var summaryText: String {
        switch self {
        case .checking:
            return L("Vérification kDrive et source en cours…", "Checking kDrive and source…")
        case .upToDate(let remoteCount, let checkedCount):
            if checkedCount > 0 {
                return L("À jour avec la source · \(remoteCount) sur kDrive", "Up to date with source · \(remoteCount) on kDrive")
            }
            return L("À jour sur kDrive · \(remoteCount) fichier(s)", "Up to date on kDrive · \(remoteCount) file(s)")
        case .pendingUpload(let local, let remoteCount):
            return L("Source à jour · \(local) sur l'iPhone à envoyer (\(remoteCount) sur kDrive)",
                     "Source up to date · \(local) on iPhone to upload (\(remoteCount) on kDrive)")
        case .outdated(let count, let fullPage, let localPending, let remoteCount):
            let plus = fullPage ? "+" : ""
            if localPending > 0 {
                return L("Pas à jour : +\(count)\(plus) nouveau(x) sur la source, \(localPending) à envoyer (\(remoteCount) sur kDrive)",
                         "Outdated: +\(count)\(plus) new on source, \(localPending) to upload (\(remoteCount) on kDrive)")
            }
            return L("Pas à jour : +\(count)\(plus) nouveau(x) sur la source (\(remoteCount) sur kDrive)",
                     "Outdated: +\(count)\(plus) new on source (\(remoteCount) on kDrive)")
        case .notOnDrive(let sourceCount, let localPending):
            if sourceCount > 0 {
                return L("Absent de kDrive · \(sourceCount)+ média(s) sur la source",
                         "Not on kDrive · \(sourceCount)+ media on source")
            }
            if localPending > 0 {
                return L("Absent de kDrive · \(localPending) sur l'iPhone à envoyer",
                         "Not on kDrive · \(localPending) on iPhone to upload")
            }
            return L("Absent de kDrive", "Not on kDrive")
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Fonctions pures de résolution de dossiers kDrive et d'évaluation de
/// fraîcheur entre kDrive, le stockage local et le site source.
public enum KDriveFreshness {
    /// Noms de dossiers kDrive candidats pour un identifiant de collection
    /// (ex. `u/alice` ou `alice` -> `["Ualice", "Alice"]`, `tw/bob` -> `["Bob - X"]`).
    /// Permet de retrouver aussi bien les dossiers actuels (`Ualice`) que les
    /// dossiers historiques sans préfixe (`Alice`).
    public static func candidateFolderNames(for collectionID: String) -> [String] {
        let trimmed = collectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [FilenamePolicy.kDriveFolderName(trimmed)] }

        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let folder = FilenamePolicy.kDriveFolderName(raw)
            let key = FilenamePolicy.kDriveNormalizedName(folder)
            if seen.insert(key).inserted {
                candidates.append(folder)
            }
        }

        if !trimmed.contains("/") {
            add("u/\(trimmed)")
            add(trimmed)
        } else {
            add(trimmed)
            if trimmed.lowercased().hasPrefix("u/") {
                let bare = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !bare.isEmpty {
                    add(bare)
                }
            }
        }
        return candidates
    }

    /// Déduit une `FeedSource` à partir du nom d'un dossier présent sur kDrive
    /// lorsque son préfixe ou suffixe identifie la plateforme sans ambiguïté.
    public static func inferredSource(fromFolderName folderName: String) -> FeedSource? {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if lower == "tiktok - videos" || lower.hasPrefix("posts ") || lower.hasPrefix("rggif ") {
            return nil
        }
        if lower.hasSuffix(" - tiktok saved") {
            let name = String(trimmed.dropLast(" - tiktok saved".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return try? FeedSource.parse("ts/\(name.lowercased())")
        }
        if lower.hasSuffix(" - tiktok") {
            let name = String(trimmed.dropLast(" - tiktok".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return try? FeedSource.parse("tt/\(name.lowercased())")
        }
        if lower.hasSuffix(" - x") {
            let name = String(trimmed.dropLast(" - x".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return try? FeedSource.parse("tw/\(name)")
        }
        if lower.hasSuffix(" - instagram") {
            let name = String(trimmed.dropLast(" - instagram".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return try? FeedSource.parse("ig/\(name.lowercased())")
        }
        if lower.hasPrefix("x-fetish ") {
            let model = String(trimmed.dropFirst("x-fetish ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return nil }
            return try? FeedSource.parse("x/\(model.lowercased())")
        }
        if lower.hasPrefix("rg#") {
            let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            return try? FeedSource.parse("rg/#\(tag.lowercased())")
        }
        if lower.hasPrefix("rg"), trimmed.count > 2 {
            let user = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else { return nil }
            return try? FeedSource.parse("rg/\(user.lowercased())")
        }
        return nil
    }

    /// Compare les fichiers présents dans le dossier kDrive (`nil` si le
    /// dossier n'existe pas sur kDrive), les éléments récents de la première
    /// page du site source, et les fichiers locaux de l'appareil.
    public static func evaluate(
        remoteFileNames: Set<String>?,
        sourceItems: [KDriveSourceItem],
        localFileNames: [String] = []
    ) -> KDriveFreshnessStatus {
        let localIndex = KDriveRemoteIndex(fileNames: localFileNames)

        guard let remoteFileNames else {
            return .notOnDrive(
                sourceNewCount: sourceItems.count,
                localPendingCount: localFileNames.count
            )
        }

        let remoteIndex = KDriveRemoteIndex(fileNames: remoteFileNames)
        let localPendingCount = localFileNames.filter { !remoteIndex.containsLocalFile($0) }.count

        var missingFromDriveCount = 0
        var missingFromBothCount = 0
        var presentOnDriveCount = 0

        for item in sourceItems {
            if remoteIndex.contains(item) {
                presentOnDriveCount += 1
            } else {
                missingFromDriveCount += 1
                if !localIndex.contains(item) {
                    missingFromBothCount += 1
                }
            }
        }

        // S'il manque des médias de la source qui ne sont ni sur kDrive ni sur
        // l'iPhone, la collection n'est pas à jour par rapport au site source.
        if missingFromBothCount > 0 {
            let fullPageMissing = !sourceItems.isEmpty && presentOnDriveCount == 0
            return .outdated(
                newOnSourceCount: missingFromBothCount,
                fullPageMissing: fullPageMissing,
                localPendingCount: localPendingCount,
                remoteCount: remoteIndex.totalFiles
            )
        }

        // Tous les médias de la source sont connus localement ou sur kDrive,
        // mais certains fichiers locaux n'ont pas encore été envoyés sur kDrive.
        if missingFromDriveCount > 0 || localPendingCount > 0 {
            let toUpload = max(localPendingCount, missingFromDriveCount)
            return .pendingUpload(
                localPendingCount: toUpload,
                remoteCount: remoteIndex.totalFiles
            )
        }

        return .upToDate(
            remoteCount: remoteIndex.totalFiles,
            checkedSourceCount: sourceItems.count
        )
    }
}

import Foundation

/// A filesystem snapshot, independent of the UI and safe to build off the main actor.
public struct CollectionFiles: Sendable {
    public let files: [URL]
    public let totalBytes: Int64
    public let dates: [URL: Date]
    public let sizes: [URL: Int64]

    public init(files: [URL], totalBytes: Int64, dates: [URL: Date] = [:], sizes: [URL: Int64] = [:]) {
        self.files = files
        self.totalBytes = totalBytes
        self.dates = dates
        self.sizes = sizes
    }

    /// Extensions reconnues comme médias affichables dans la galerie. Point
    /// unique de vérité partagé par `scan`, `hasMedia` et la migration.
    public static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "mp4", "mov", "m4v"
    ]

    /// Vrai quand l'URL désigne un fichier régulier visible portant une
    /// extension média reconnue (exclut dossiers, sidecars cachés, résidus
    /// temporaires ou fichiers non médias).
    public static func isMediaFile(_ url: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."),
              mediaExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    /// Vrai quand le dossier contient au moins un vrai média affichable par la
    /// galerie (même règle stricte que `scan`). Un dossier absent, vide, ou ne
    /// contenant que `.metadata`, des sous-dossiers ou des fichiers non médias
    /// retourne `false`. S'arrête dès le premier média trouvé (O(1) en mémoire).
    public static func hasMedia(in folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return false }
        for case let url as URL in enumerator {
            if isMediaFile(url) { return true }
        }
        return false
    }

    /// Dossiers hérités de vidéos TikTok isolées (`ttv.<id>` créés avant le
    /// dossier global unique `ttv.videos`).
    public static func legacyTikTokVideoFolders(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { entry in
            entry.lastPathComponent.hasPrefix("ttv.")
                && entry.lastPathComponent != "ttv.videos"
                && ((try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
    }

    /// Résultat d'une fusion des anciens dossiers `ttv.<id>` vers `ttv.videos`.
    public struct LegacyTikTokMigrationResult: Sendable {
        public let movedByFolder: [(folderName: String, moved: Int)]
        public let failures: [(fileName: String, errorDescription: String)]
        public let removedLegacyFolders: Int
    }

    /// Fusionne les anciens dossiers `ttv.<id>` vers le dossier global
    /// `ttv.videos` :
    /// - Un dossier hérité sans aucun vrai média (vide, `.metadata` seul ou
    ///   résidus non médias) est supprimé sans créer `ttv.videos`.
    /// - Un dossier hérité contenant de vrais médias crée `ttv.videos` si
    ///   besoin, déplace les médias et leurs sidecars `.metadata`, puis
    ///   supprime l'ancien dossier dès qu'il ne contient plus de médias.
    @discardableResult
    public static func migrateLegacyTikTokVideoFolders(root: URL, into globalFolder: URL) -> LegacyTikTokMigrationResult {
        let fm = FileManager.default
        let legacyFolders = legacyTikTokVideoFolders(in: root)
        guard !legacyFolders.isEmpty else {
            return LegacyTikTokMigrationResult(movedByFolder: [], failures: [], removedLegacyFolders: 0)
        }
        var movedByFolder: [(folderName: String, moved: Int)] = []
        var failures: [(fileName: String, errorDescription: String)] = []
        var removedLegacyFolders = 0
        for legacy in legacyFolders {
            guard let contents = try? fm.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { continue }
            let mediaItems = contents.filter { isMediaFile($0) }
            if mediaItems.isEmpty {
                if (try? fm.removeItem(at: legacy)) != nil { removedLegacyFolders += 1 }
                continue
            }
            if !fm.fileExists(atPath: globalFolder.path) {
                do {
                    try fm.createDirectory(at: globalFolder, withIntermediateDirectories: true)
                } catch {
                    failures.append((globalFolder.lastPathComponent, error.localizedDescription))
                    continue
                }
            }
            var moved = 0
            for item in mediaItems {
                let target = globalFolder.appendingPathComponent(item.lastPathComponent)
                do {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: item, to: target)
                    moved += 1
                    MediaMetadata.move(from: item, to: target)
                } catch {
                    failures.append((item.lastPathComponent, error.localizedDescription))
                }
            }
            if !hasMedia(in: legacy) {
                if (try? fm.removeItem(at: legacy)) != nil { removedLegacyFolders += 1 }
            }
            if moved > 0 {
                movedByFolder.append((legacy.lastPathComponent, moved))
            }
        }
        return LegacyTikTokMigrationResult(
            movedByFolder: movedByFolder,
            failures: failures,
            removedLegacyFolders: removedLegacyFolders
        )
    }

    /// Supprime tous les dossiers hérités `ttv.<id>` sous `root` (appelé lors
    /// de la suppression explicite de la collection `ttv/videos`).
    public static func removeLegacyTikTokVideoFolders(in root: URL) {
        let fm = FileManager.default
        for legacy in legacyTikTokVideoFolders(in: root) {
            try? fm.removeItem(at: legacy)
        }
    }

    public static func scan(_ folder: URL) throws -> CollectionFiles {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .fileSizeKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Décision Jev A bug 13 : distinguer vide et illisible.
            // Dossier absent = premier lancement normal -> vide, pas d'erreur.
            // Autre erreur (droits, pas un dossier) -> on prévient au lieu de dire 0.
            try Task.checkCancellation()
            if !FileManager.default.fileExists(atPath: folder.path) {
                return CollectionFiles(files: [], totalBytes: 0)
            }
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError) {
                return CollectionFiles(files: [], totalBytes: 0)
            }
            throw error
        }
        var media: [(url: URL, date: Date)] = []
        var bytes: Int64 = 0
        var dates: [URL: Date] = [:]
        var sizes: [URL: Int64] = [:]
        for url in entries {
            try Task.checkCancellation()
            guard mediaExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            bytes += size
            sizes[url] = size
            if let creationDate = values.creationDate { dates[url] = creationDate }
            media.append((url, values.creationDate ?? .distantPast))
        }
        media.sort {
            $0.date == $1.date ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.date > $1.date
        }
        try Task.checkCancellation()
        return CollectionFiles(files: media.map(\.url), totalBytes: bytes, dates: dates, sizes: sizes)
    }
}

import Foundation

/// A filesystem snapshot, independent of the UI and safe to build off the main actor.
public struct CollectionFiles: Sendable {
    public let files: [URL]
    public let totalBytes: Int64

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
        for url in entries {
            try Task.checkCancellation()
            guard ["jpg", "jpeg", "png", "gif", "webp", "mp4", "mov"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            media.append((url, values.creationDate ?? .distantPast))
        }
        media.sort {
            $0.date == $1.date ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.date > $1.date
        }
        try Task.checkCancellation()
        return CollectionFiles(files: media.map(\.url), totalBytes: bytes)
    }
}

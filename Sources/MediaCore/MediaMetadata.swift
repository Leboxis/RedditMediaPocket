import Foundation

/// Sidecars contain dates only, never session cookies or private feed URLs.
public struct MediaMetadata: Codable, Equatable {
    public let downloadedAt: Date
    public let postDate: Date?

    public init(downloadedAt: Date, postDate: Date?) {
        self.downloadedAt = downloadedAt
        self.postDate = postDate
    }

    private static func location(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".metadata", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent + ".json")
    }

    public static func read(for url: URL) -> MediaMetadata? {
        guard let data = try? Data(contentsOf: location(for: url)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    @discardableResult public func save(for url: URL) -> Bool {
        do {
            let destination = Self.location(for: url)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: destination, options: .atomic)
            return true
        } catch { return false }
    }

    public static func remove(for url: URL) {
        try? FileManager.default.removeItem(at: location(for: url))
    }

    public static func move(from source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: destination.path), let metadata = read(for: source),
              metadata.save(for: destination) else { return }
        remove(for: source)
    }
}

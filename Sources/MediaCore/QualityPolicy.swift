import Foundation

public enum QualityPolicy {
    /// Imgur's legacy 5/7-character image IDs can carry a thumbnail-size suffix.
    public static func originalImageURL(_ url: URL) -> URL {
        guard url.host?.lowercased() == "i.imgur.com",
              ["jpg", "jpeg", "png", "gif", "webp"].contains(url.pathExtension.lowercased()) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.range(of: "^(?:[A-Za-z0-9]{5}|[A-Za-z0-9]{7})[sbtmlh]$", options: .regularExpression) != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let original = String(stem.dropLast()) + "." + url.pathExtension
        parts.path = "/" + original
        return parts.url ?? url
    }

    public static func redgifsURL(hd: URL?, sd: URL?) -> URL? {
        // SD is only chosen if no HD URL is exposed; an HD failure never retries in SD.
        hd ?? sd
    }
}

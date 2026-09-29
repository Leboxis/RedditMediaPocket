import Foundation

/// Requêtes X-Fetish alignées sur le lecteur web : `get_image` redirige vers
/// `storage*.x-fetish.tube/remote_control.php?file=…&acctoken=…` qui refuse
/// l'accès (HTTP 403) sans `Referer` d'album. Ces en-têtes reproduisent le
/// trafic du navigateur au lieu d'un appel nu. Le jeton reste dans l'URL,
/// jamais dans les logs (voir `LogDiagnostics`).
public enum XFetishAPI {
    public static func isXFetish(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "x-fetish.tube" || host.hasSuffix(".x-fetish.tube")
    }

    /// `Referer` = page album d'origine (anti-hotlink), `Origin` = domaine
    /// principal, `Accept` = image. Ne contient jamais le jeton.
    /// UA navigateur : le stockage refuse l'UA applicatif (HTTP 403).
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// `Accept` du lecteur web pour une image, et pour une vidéo (`get_file`).
    public static let imageAccept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
    public static let videoAccept = "video/mp4,video/*;q=0.9,image/avif,image/webp,*/*;q=0.8"

    public static func headers(referer: URL? = nil, accept: String = XFetishAPI.imageAccept) -> [String: String] {
        [
            "Referer": referer?.absoluteString ?? "https://x-fetish.tube/",
            "Origin": "https://x-fetish.tube",
            "Accept": accept,
        ]
    }
}

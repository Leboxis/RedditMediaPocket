import Foundation

/// Requête RedGIFs alignée sur les implémentations de référence
/// (yt-dlp, gallery-dl) : ID en minuscules, `?views=yes`, en-têtes
/// Referer/Origin/x-customheader. Le jeton temporaire de RedGIFs est
/// lié à l'agent et à l'adresse ; ces en-têtes reproduisent le trafic
/// du lecteur web au lieu d'un appel nu.
public enum RedgifsAPI {
    public static func gifURL(id: String) -> URL {
        var components = URLComponents(string: "https://api.redgifs.com/v2/gifs/\(id.lowercased())")!
        components.queryItems = [URLQueryItem(name: "views", value: "yes")]
        return components.url!
    }

    public static func headers(id: String) -> [String: String] {
        let lowered = id.lowercased()
        return [
            "Referer": "https://www.redgifs.com/",
            "Origin": "https://www.redgifs.com",
            "x-customheader": "https://www.redgifs.com/watch/\(lowered)"
        ]
    }
}

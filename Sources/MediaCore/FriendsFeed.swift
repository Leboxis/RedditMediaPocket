import Foundation

/// Suivis (friends) du compte connecté : extraits de la page privée
/// `old.reddit.com/prefs/friends`, même mécanisme de session que
/// `prefs/feeds`. Parsing pur : aucun réseau ici. Seuls les liens de
/// profil Reddit valides sont retenus, dédupliqués et ordonnés d'apparition.
public enum FriendsFeed {
    public static func parse(_ html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?i)\bhref\s*=\s*["']([^"']+)["']"#)
        let ns = html as NSString
        var names: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw, relativeTo: URL(string: "https://old.reddit.com/prefs/friends/")!)?.absoluteURL,
                  url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
                  ["reddit.com", "www.reddit.com", "old.reddit.com"].contains(host) else { continue }
            let parts = url.pathComponents
            guard parts.count >= 3, parts[1].lowercased() == "user",
                  let name = try? MediaExtractor.username(parts[2]),
                  seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }
}

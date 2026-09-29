import Foundation

/// Primitives HTML partagées par les parseurs X-Fetish (albums et vidéos).
/// Le HTML du site est hostile au parsing : balises sans classe stable, HTML
/// échappé, URL absolues comme relatives. Ces fonctions n'acceptent qu'HTTPS
/// sur `x-fetish.tube`, sans identifiants ni port inhabituel, afin qu'aucune
/// adresse tierce ne puisse entrer dans un téléchargement.
enum XFetishHTML {
    static let anchorRegex = try! NSRegularExpression(pattern: #"(?is)<a\b[^>]*>"#)
    static let divRegex = try! NSRegularExpression(pattern: #"(?is)</?div\b[^>]*>"#)
    static let attributeRegex = try! NSRegularExpression(pattern: #"(?i)\b([a-z][a-z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    static let slugRegex = try! NSRegularExpression(pattern: #"^[a-z0-9_-]{1,80}$"#)
    static let numericRegex = try! NSRegularExpression(pattern: #"^[0-9]+$"#)
    /// Album and video slugs are built from the media title, so they are often
    /// far longer than a model slug. Only the character set is constrained: no
    /// separator, no dot, no percent escape, nothing that could re-target the URL.
    static let pathComponentRegex = try! NSRegularExpression(pattern: #"^[0-9A-Za-z_-]{1,300}$"#)

    static let siteRoot = URL(string: "https://x-fetish.tube/")!

    static func matches(_ value: String, _ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    static func slug(_ value: String) -> Bool { matches(value, slugRegex) }

    static func pathComponent(_ value: String) -> Bool { matches(value, pathComponentRegex) }

    static func numeric(_ value: String) -> Bool { matches(value, numericRegex) }

    static func pathParts(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    static func siteURL(_ raw: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: decoded(raw), relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host?.lowercased() == "x-fetish.tube",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    static func decoded(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func anchorTags(_ html: String) -> [String] {
        let ns = html as NSString
        return anchorRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// Section `<div id="…">` balancing nested divs, used to ignore the
    /// vignettes, les vidéos recommandées et les blocs hors galerie.
    static func divSection(id: String, in html: String) -> String? {
        let ns = html as NSString
        let tags = divRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var start: Int?
        var depth = 0
        for match in tags {
            let tag = ns.substring(with: match.range)
            if start == nil {
                guard !tag.hasPrefix("</"), attributes(tag)["id"] == id else { continue }
                start = match.range.location
            }
            depth += tag.hasPrefix("</") ? -1 : 1
            if depth == 0, let start {
                return ns.substring(with: NSRange(location: start, length: NSMaxRange(match.range) - start))
            }
        }
        return nil
    }

    static func attributes(_ tag: String) -> [String: String] {
        let ns = tag as NSString
        var attrs: [String: String] = [:]
        for match in attributeRegex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let valueRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            attrs[key] = ns.substring(with: valueRange)
        }
        return attrs
    }
}

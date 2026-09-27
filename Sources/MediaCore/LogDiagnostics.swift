import Foundation

/// Text safe to display, persist and share in a diagnostic log.
public enum LogDiagnostics {
    public static func sanitize(_ message: String) -> String {
        var clean = message
        let replacements: [(String, String)] = [
            (#"(?i)\b(?:Cookie|Set-Cookie)\s*:\s*[^\r\n]*"#, "[cookie masqué]"),
            (#"(?i)\b(Authorization\s*:\s*(?:Bearer|Basic)\s+|Bearer\s+)[^\s,;]+"#, "$1[masqué]"),
            (#"(?i)\b((?:feed|user|token|access_token|refresh_token|client_secret|api_key|reddit_session|password|session)\s*=\s*)[^\s&;#\"'<>]+"#, "$1[masqué]")
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            clean = regex.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: replacement)
        }
        return clean.count > 500 ? String(clean.prefix(500)) + "…" : clean
    }

    /// Include pagination context while never copying a private feed token or cookies.
    public static func requestSummary(_ url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "[adresse invalide]" }
        var details: [String] = []
        let items = parts.queryItems ?? []
        if items.contains(where: { $0.name == "feed" }) { details.append(L("flux privé", "private feed")) }
        for key in ["limit", "after"] {
            if let value = items.first(where: { $0.name == key })?.value {
                let safe = value.range(of: #"^[A-Za-z0-9_]{1,64}$"#, options: .regularExpression) != nil
                details.append("\(key)=\(safe ? value : "[masqué]")")
            }
        }
        let endpoint = "\(parts.host ?? "serveur")\(parts.path)"
        return details.isEmpty ? endpoint : endpoint + " [" + details.joined(separator: ", ") + "]"
    }
}

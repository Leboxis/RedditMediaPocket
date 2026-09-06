import Foundation

public enum FilenamePolicy {
    public static func postTitle(_ title: String, fallback: String = "post", maxUTF8Bytes: Int = 180) -> String {
        let separators = CharacterSet(charactersIn: "/:")
        let sanitized = title.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { scalar in
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                if separators.contains(scalar) { return "-" }
                return String(scalar)
            }
            .joined()
        let compact = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let candidate = compact.isEmpty ? fallback : compact

        var result = ""
        var byteCount = 0
        for character in candidate {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maxUTF8Bytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return result.isEmpty ? "post" : result
    }
}

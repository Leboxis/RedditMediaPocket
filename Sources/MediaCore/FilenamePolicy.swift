import Foundation

public enum FilenamePolicy {
    /// Caractères rejetés par kDrive/Windows dans un nom de fichier.
    /// Source : FAQ Infomaniak « Troubleshooting kDrive synchronization issues ».
    /// L'app ne remplaçait que `/` et `:` : les titres Reddit contenant
    /// `? " * < > | \` provoquaient un HTTP 422 `validation_failed` à l'upload.
    private static let kDriveForbidden = CharacterSet(charactersIn: "<>:\"/\\|?*")

    private static let reservedStems: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]

    public static func postTitle(_ title: String, fallback: String = "post", maxUTF8Bytes: Int = 180) -> String {
        let sanitized = title.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { scalar in
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                if kDriveForbidden.contains(scalar) { return "-" }
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

    /// Nom de fichier sûr pour l'API kDrive, dérivé d'un nom local existant
    /// (qui peut contenir des caractères aujourd'hui interdits côté serveur).
    /// Conserve l'extension, remplace les interdits par `-`, lève les noms
    /// réservés Windows et tronque en gardant l'unicité via un suffixe court.
    public static func kDriveFileName(_ original: String, fallback: String = "media", maxUTF8Bytes: Int = 150) -> String {
        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension
        var stem = url.deletingPathExtension().lastPathComponent
        if stem.isEmpty { stem = (original as NSString).deletingPathExtension }

        stem = stem.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { scalar in
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                if kDriveForbidden.contains(scalar) { return "-" }
                return String(scalar)
            }
            .joined()
        stem = stem
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if stem.isEmpty { stem = fallback }
        if reservedStems.contains(stem.uppercased()) { stem = "_" + stem }

        let candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
        if candidate.utf8.count <= maxUTF8Bytes { return candidate }

        // Tronque le stem en gardant l'extension et un suffixe distinctif.
        let hash = String(abs(original.hashValue), radix: 36)
        let suffix = "-" + hash.prefix(6)
        let extBytes = ext.isEmpty ? 0 : ext.utf8.count + 1
        let allowedStemBytes = max(1, maxUTF8Bytes - extBytes - suffix.utf8.count)
        var truncated = ""
        var byteCount = 0
        for character in stem {
            let n = String(character).utf8.count
            guard byteCount + n <= allowedStemBytes else { break }
            truncated.append(character)
            byteCount += n
        }
        truncated = truncated.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if truncated.isEmpty { truncated = fallback }
        if reservedStems.contains(truncated.uppercased()) { truncated = "_" + truncated }
        // Recalcule si le préfixe "_" a dépassé le budget.
        while (truncated + suffix + (ext.isEmpty ? "" : ".\(ext)")).utf8.count > maxUTF8Bytes, truncated.count > 1 {
            truncated.removeLast()
        }
        return ext.isEmpty ? truncated + suffix : "\(truncated)\(suffix).\(ext)"
    }

    /// Nom de repli ultra-sûr (ASCII, court) utilisé en 2e tentative si le
    /// serveur rejette encore le nom assaini avec un 422.
    public static func kDriveFallbackName(for original: String) -> String {
        let ext = URL(fileURLWithPath: original).pathExtension
        let hash = String(abs(original.hashValue), radix: 36)
        let stem = "media-" + hash.prefix(8)
        return ext.isEmpty ? String(stem) : "\(stem).\(ext)"
    }

    /// Nom de dossier kDrive : juste le pseudo/sub, première lettre en
    /// majuscule, assaini pour l'API (interdits Windows, réservés, longueur).
    /// Accepte aussi les anciens libellés `u/pseudo`, `r/sub`, `saved/pseudo`.
    public static func kDriveFolderName(_ raw: String, fallback: String = "Pocket", maxUTF8Bytes: Int = 100) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelSeparators = CharacterSet(charactersIn: "/／\\＼")
        let parts = base.components(separatedBy: labelSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let last = parts.last { base = last }
        if base.isEmpty { base = fallback }

        base = base.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { scalar in
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                if kDriveForbidden.contains(scalar) { return "-" }
                return String(scalar)
            }
            .joined()
        base = base
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if base.isEmpty { base = fallback }
        if reservedStems.contains(base.uppercased()) { base = "_" + base }
        if let first = base.first {
            base = String(first).uppercased() + base.dropFirst()
        }
        if base.isEmpty { base = fallback }

        guard base.utf8.count > maxUTF8Bytes else { return base }
        var truncated = ""
        var byteCount = 0
        for character in base {
            let n = String(character).utf8.count
            guard byteCount + n <= maxUTF8Bytes else { break }
            truncated.append(character)
            byteCount += n
        }
        truncated = truncated.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return truncated.isEmpty ? fallback : truncated
    }
}

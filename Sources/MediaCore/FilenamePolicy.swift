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

    /// Stem local `Titre - IDcourt` (galerie : `Titre {position} - IDcourt`).
    /// L'ID est toujours en dernier avant `.ext`, sans préfixe `t3_`, avec un
    /// seul séparateur ` - `. Le `-` traînant issu de l'assainissement
    /// (ex. `?` → `-`) est retiré pour éviter `tips- - 1ghwxnf`.
    public static func downloadStem(title: String, postID: String, position: Int? = nil, maxUTF8Bytes: Int = 180) -> String {
        var short = postID.hasPrefix("t3_") ? String(postID.dropFirst(3)) : postID
        short = short.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        guard !short.isEmpty else {
            let base = postTitle(title, maxUTF8Bytes: maxUTF8Bytes)
            return base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        }
        let suffix = position.map { " \($0) - \(short)" } ?? " - \(short)"
        let allowedBase = max(1, maxUTF8Bytes - suffix.utf8.count)
        var base = postTitle(title, fallback: short, maxUTF8Bytes: allowedBase)
        base = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        if base.isEmpty || base == short { return short }
        if let position {
            return "\(base) \(position) - \(short)"
        }
        return "\(base) - \(short)"
    }

    /// Recover the immutable album/image or video key from an existing X-Fetish
    /// file. Titles can change, so the download scan compares this key rather
    /// than the full filename when deciding whether a file is already saved.
    /// Images use `xf-<album>-<image>`, videos use `xfv-<video>`.
    public static func xFetishMediaID(inFileName filename: String) -> String? {
        let file = URL(fileURLWithPath: filename)
        guard ["jpg", "jpeg", "png", "webp", "gif", "mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()) else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        guard let marker = [" - xfv-", " - xf-"].compactMap({ stem.range(of: $0, options: .backwards) })
                .max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let parts = stem[marker.upperBound...].split(separator: "-", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.utf8.allSatisfy({ byte in byte >= 48 && byte <= 57 })
              }) else { return nil }
        let prefix = stem[marker.lowerBound...].hasPrefix(" - xfv-") ? "xfv-" : "xf-"
        return prefix + parts.joined(separator: "-")
    }

    /// Recover the immutable media key of an X file. Titles change and a
    /// post can hold several media, so the scan compares this key rather than
    /// the whole filename. Images use `xm-<mediaId>`, videos and animated GIFs
    /// use `xmv-<mediaId>`. `XMedia.storageKey` writes this exact form; the
    /// two must stay in step.
    public static func xMediaID(inFileName filename: String) -> String? {
        let file = URL(fileURLWithPath: filename)
        guard ["jpg", "jpeg", "png", "webp", "gif", "mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()) else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        // Un post X sans texte produit un nom nu (`xm-123.jpg`) : le préfixe
        // seul doit alors suffire. Sinon le nom est `Titre - xm-123`.
        if let bare = Self.xBareKey(stem) { return bare }
        // ` - xm-` exigerait un tiret après `xm`, donc il ne peut pas matcher
        // ` - xmv-` : les deux marqueurs sont mutuellement exclusifs et il suffit
        // de retenir la dernière occurrence de l'un ou l'autre.
        guard let marker = [" - xmv-", " - xm-"].compactMap({ stem.range(of: $0, options: .backwards) })
                .max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let key = String(stem[marker.upperBound...])
        guard Self.isMediaKey(key) else { return nil }
        return stem[marker.lowerBound...].hasPrefix(" - xmv-") ? "xmv-" + key : "xm-" + key
    }

    /// Clé d'un nom de fichier réduit à sa seule clé, sans titre.
    private static func xBareKey(_ stem: String) -> String? {
        for prefix in ["xmv-", "xm-"] where stem.hasPrefix(prefix) {
            let key = String(stem.dropFirst(prefix.count))
            if isMediaKey(key) { return prefix + key }
        }
        return nil
    }

    /// L'identifiant de média X est numérique : un suffixe de collision `-2` ou
    /// un fragment de titre ne doit jamais être accepté comme clé.
    private static func isMediaKey(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
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
        let suffix = "-" + stableSuffix(original).prefix(6)
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
        let stem = "media-" + stableSuffix(original).prefix(8)
        return ext.isEmpty ? String(stem) : "\(stem).\(ext)"
    }

    /// FNV-1a over UTF-8: persisted names must not depend on Swift's
    /// randomly seeded hashValue (which changes between app launches).
    private static func stableSuffix(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    /// Comparaison de noms de dossiers kDrive : insensible à la casse et aux
    /// diacritiques, comme la recherche dans `prepareCollectionFolder`.
    public static func kDriveNameMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Noms distants possibles d'un fichier local : le nom assaini envoyé en
    /// premier, puis le repli déterministe utilisé après un 422. Un fichier
    /// déjà présent sous l'un ou l'autre ne doit pas être ré-uploadé.
    public static func kDriveRemoteCandidateNames(for original: String) -> [String] {
        let safe = kDriveFileName(original)
        let fallback = kDriveFallbackName(for: original)
        return fallback == safe ? [safe] : [safe, fallback]
    }

    /// Nom de dossier kDrive : juste le pseudo/sub, première lettre en
    /// majuscule, assaini pour l'API (interdits Windows, réservés, longueur).
    /// Accepte aussi les libellés `u/pseudo`, `r/sub`, `saved/pseudo`, `x/model`,
    /// `rg/pseudo` et `tw/pseudo`.
    public static func kDriveFolderName(_ raw: String, fallback: String = "Pocket", maxUTF8Bytes: Int = 100) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelSeparators = CharacterSet(charactersIn: "/／\\＼")
        let parts = base.components(separatedBy: labelSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Le préfixe de type est conservé : sans lui, `u/foo`
        // et `saved/foo` produiraient le même dossier `Foo` et leurs médias
        // se surécriraient dans kDrive. X-Fetish inclut un espace afin de ne
        // jamais coïncider avec un pseudo Reddit tel que `u/xfoo`.
        // RedGifs utilise `Rg` (distinct de `R` des subreddits).
        var typePrefix = ""
        if parts.count > 1, let first = parts.first?.lowercased() {
            if first == "x" { typePrefix = "X-Fetish " }
            else if first == "rg" { typePrefix = "Rg" }
            // `tw` doit rester distinct de `t` : un compte X ne doit jamais
            // hériter du dossier d'un profil Reddit au même pseudo.
            else if first == "tw" { typePrefix = "Tw" }
            else if ["u", "r", "saved"].contains(first) { typePrefix = String(first.prefix(1)).uppercased() }
        }
        if let last = parts.last { base = last }
        if base.isEmpty { base = fallback }
        base = typePrefix + base

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

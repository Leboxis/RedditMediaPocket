import Foundation

/// Filtres appliqués avant la mise en file d'un média. Ils décident de ce qui
/// est téléchargé, pas de ce qui est parcouru : un post écarté par un filtre
/// reste « vu », il ne sera donc pas réévalué au lancement suivant. C'est
/// volontaire — sans quoi un filtre exigeant ferait relire tout le flux à
/// chaque exécution.
public struct DownloadFilter: Codable, Equatable, Sendable {
    /// Types retenus. Vide signifie « tous » (aucun filtrage par type).
    public var kinds: Set<MediaKind>
    /// Date de publication minimale. Un post sans date connue passe le filtre.
    public var since: Date?
    /// Taille minimale en octets. Un média dont la taille n'est pas connue
    /// avant transfert passe le filtre : elle n'est vérifiée qu'à l'arrivée.
    public var minimumBytes: Int64
    /// Mots-clés exigés, insensibles à la casse. Tous doivent être présents.
    public var includes: [String]
    /// Mots-clés exclus, insensibles à la casse. Un seul suffit à écarter.
    public var excludes: [String]

    public enum MediaKind: String, Codable, CaseIterable, Sendable {
        case image, video, gif
    }

    public init(kinds: Set<MediaKind> = [], since: Date? = nil, minimumBytes: Int64 = 0,
                includes: [String] = [], excludes: [String] = []) {
        self.kinds = kinds
        self.since = since
        self.minimumBytes = minimumBytes
        self.includes = includes
        self.excludes = excludes
    }

    /// Vrai quand aucun critère n'est actif : le filtre ne doit alors rien
    /// changer, et l'appelant peut éviter le coût du test.
    public var isEmpty: Bool {
        kinds.isEmpty && since == nil && minimumBytes <= 0 && includes.isEmpty && excludes.isEmpty
    }

    /// Un filtre actif, pour savoir si un post écarté doit être mémorisé comme
    /// tel plutôt que comme téléchargé.
    public var isActive: Bool { !isEmpty }

    /// Décide du sort d'un média candidat.
    ///
    /// `title` est le titre du post (ou son texte pour X) : c'est la seule
    /// information textuelle disponible avant transfert. `publishedAt` et
    /// `size` sont facultatifs : une valeur absente ne fait jamais échouer le
    /// filtre, seule une valeur connue et hors critère écarte le média.
    public func allows(kind: MediaKind, title: String, publishedAt: Date?, size: Int64? = nil) -> Bool {
        if !kinds.isEmpty, !kinds.contains(kind) { return false }
        if let since, let publishedAt, publishedAt < since { return false }
        if minimumBytes > 0, let size, size < minimumBytes { return false }
        let haystack = title.lowercased()
        if !includes.isEmpty {
            let words = Self.words(includes)
            guard words.allSatisfy({ haystack.contains($0) }) else { return false }
        }
        if !excludes.isEmpty {
            let words = Self.words(excludes)
            guard !words.contains(where: { haystack.contains($0) }) else { return false }
        }
        return true
    }

    /// Mots-clés prêts à l'emploi : minuscules, sans espaces superflus, sans
    /// entrée vide. Une liste saisie « a, b , ,c » vaut `["a", "b", "c"]`.
    static func words(_ raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Analyse une saisie libre de mots-clés (virgules ou retours à la ligne).
    public static func parseWords(_ text: String) -> [String] {
        words(text.split { $0 == "," || $0.isNewline }.map(String.init))
    }
}

/// Codec commun aux réglages de filtre, mémorisés par collection.
public enum DownloadFilterStore {
    public static func key(_ canonical: String) -> String { "downloadFilter.\(canonical)" }

    public static func load(_ canonical: String, defaults: UserDefaults = .standard) -> DownloadFilter {
        guard let data = defaults.data(forKey: key(canonical)),
              let filter = try? JSONDecoder().decode(DownloadFilter.self, from: data) else {
            return DownloadFilter()
        }
        return filter
    }

    public static func save(_ filter: DownloadFilter, for canonical: String, defaults: UserDefaults = .standard) {
        if filter.isEmpty {
            // Un filtre vide ne vaut pas la peine d'être conservé : la clé
            // absente et la clé vide se comportent de la même façon.
            defaults.removeObject(forKey: key(canonical))
            return
        }
        if let data = try? JSONEncoder().encode(filter) { defaults.set(data, forKey: key(canonical)) }
    }

    public static func remove(_ canonical: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(canonical))
    }
}

/// Plafond d'espace disque. Le compte est fait sur le dossier de la collection
/// avant chaque page ; dès que le plafond serait dépassé, la session s'arrête
/// proprement au lieu de remplir l'appareil.
public struct StorageQuota: Codable, Equatable, Sendable {
    /// Plafond en octets. Zéro signifie « aucun plafond ».
    public var bytes: Int64

    public init(bytes: Int64 = 0) { self.bytes = bytes }

    public var isActive: Bool { bytes > 0 }

    /// Valeurs proposées dans les réglages, en gigaoctets.
    public static let optionsGB: [Int] = [0, 5, 10, 25, 50, 100]

    /// Échelle des réglages : 1 Go = 10^9 octets, comme `ByteCountFormatter`
    /// l'affiche pour cette application. Le plafond reste stocké en octets.
    public static let bytesPerGB: Int64 = 1_000_000_000

    /// Vrai quand il reste de la place pour un média de `incoming` octets.
    /// Sans plafond, la réponse est toujours vraie.
    public func allows(currentBytes: Int64, incoming: Int64 = 0) -> Bool {
        guard isActive else { return true }
        return currentBytes + max(0, incoming) <= bytes
    }

    /// Plafond atteint, indépendamment du média à venir : sert à arrêter la
    /// session avant même de préparer une page.
    public func isReached(currentBytes: Int64) -> Bool {
        isActive && currentBytes >= bytes
    }

    public static func label(gb: Int) -> String {
        gb <= 0 ? L("Sans limite", "No limit") : "\(gb) GB"
    }

    public static let defaultsKey = "storageQuotaBytes"

    public static func load(defaults: UserDefaults = .standard) -> StorageQuota {
        StorageQuota(bytes: (defaults.object(forKey: defaultsKey) as? NSNumber)?.int64Value ?? 0)
    }

    public static func save(_ quota: StorageQuota, defaults: UserDefaults = .standard) {
        if quota.isActive { defaults.set(quota.bytes, forKey: defaultsKey) }
        else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// Plus grand gigaoctet correspondant à `bytes`, ou 0. Sert à restaurer un
    /// choix dans le sélecteur sans inventer une valeur absente de la liste.
    public static func gigabytes(for bytes: Int64) -> Int {
        optionsGB.last { $0 > 0 && Int64($0) * bytesPerGB <= bytes } ?? 0
    }
}

import Foundation
import MediaCore
import Observation
import SwiftUI

extension KDriveFreshnessStatus {
    /// Palette « Apple Calm Tech » (Colorimétrie C) :
    /// - Vert Sauge (`DS.calmSage`) : à jour avec le site source (coche discrète, texte neutre).
    /// - Ambre (`DS.calmAmber`) : nouveautés disponibles sur la source ou fichiers locaux à envoyer.
    /// - Rose-Corail (`DS.calmRose`) : absent de kDrive ou erreur de vérification.
    var tintColor: Color {
        switch self {
        case .checking:
            return DS.onSurfaceMuted
        case .upToDate:
            return DS.calmSage
        case .pendingUpload, .outdated:
            return DS.calmAmber
        case .notOnDrive, .unavailable:
            return DS.calmRose
        }
    }
}

/// Centre de vérification de fraîcheur des collections kDrive par rapport
/// aux sites sources. Partagé entre la Bibliothèque, l'écran Suivis et l'onglet Activité.
@MainActor
@Observable
final class KDriveFreshnessCenter {
    static let shared = KDriveFreshnessCenter()

    private enum CachedFolder {
        case found(KDriveFolderItem)
        case missing
    }

    /// État de fraîcheur par identifiant canonique de collection (`u/pseudo`, `tw/pseudo`, etc.).
    private(set) var statuses: [String: KDriveFreshnessStatus] = [:]
    /// Horodatage de dernière vérification par identifiant canonique.
    private(set) var checkedDates: [String: Date] = [:]
    /// Index des sous-dossiers présents dans le répertoire kDrive cible (clé = nom normalisé).
    private(set) var remoteFolders: [String: KDriveFolderItem] = [:]
    /// Index et caches internes non observés : leurs lectures/écritures
    /// paresseuses ne doivent jamais déclencher d'invalidation SwiftUI pendant
    /// l'évaluation des vues ou le défilement.
    @ObservationIgnored private var statusIndex: [String: KDriveFreshnessStatus] = [:]
    @ObservationIgnored private var canonicalKeysByLower: [String: String] = [:]
    @ObservationIgnored private var folderCache: [String: CachedFolder] = [:]
    @ObservationIgnored private var inferredRemoteCollections: [UserCollection] = []
    private(set) var isCheckingAll = false
    private(set) var checkedCount = 0
    private(set) var totalToCheck = 0
    private(set) var lastGlobalError: String?

    @ObservationIgnored private var checkAllTask: Task<Void, Never>?
    @ObservationIgnored private var singleTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Identifiant canonique (`alice` nu -> `u/alice`).
    static func canonicalID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if !trimmed.contains("/") {
            return "u/\(trimmed)"
        }
        return trimmed
    }

    func status(for collectionID: String) -> KDriveFreshnessStatus? {
        guard !statuses.isEmpty else { return nil }
        let canonical = Self.canonicalID(collectionID)
        if let exact = statuses[canonical] { return exact }
        return statusIndex[canonical.lowercased()]
    }

    func remoteFolder(for collectionID: String) -> KDriveFolderItem? {
        guard !remoteFolders.isEmpty else { return nil }
        let cacheKey = Self.canonicalID(collectionID).lowercased()
        if let cached = folderCache[cacheKey] {
            switch cached {
            case .found(let folder): return folder
            case .missing: return nil
            }
        }
        for candidate in KDriveFreshness.candidateFolderNames(for: collectionID) {
            let key = FilenamePolicy.kDriveNormalizedName(candidate)
            if let folder = remoteFolders[key] {
                folderCache[cacheKey] = .found(folder)
                return folder
            }
        }
        folderCache[cacheKey] = .missing
        return nil
    }

    /// Écrit (ou supprime) un statut en tenant l'index secondaire à jour.
    private func setStatus(_ status: KDriveFreshnessStatus?, forCanonical canonical: String) {
        let lower = canonical.lowercased()
        if let existingKey = canonicalKeysByLower[lower], existingKey != canonical {
            statuses.removeValue(forKey: existingKey)
        }
        if let status {
            canonicalKeysByLower[lower] = canonical
            statuses[canonical] = status
            statusIndex[lower] = status
        } else {
            canonicalKeysByLower.removeValue(forKey: lower)
            statuses.removeValue(forKey: canonical)
            statusIndex.removeValue(forKey: lower)
        }
    }

    /// Marque une collection comme fraîchement envoyée sur kDrive après un upload réussi.
    func markUploaded(collectionLabel: String, remoteFileCount: Int) {
        let canonical = Self.canonicalID(collectionLabel)
        setStatus(.upToDate(remoteCount: remoteFileCount, checkedSourceCount: 0), forCanonical: canonical)
        checkedDates[canonical] = Date()
    }

    /// Liste consolidée de toutes les collections vérifiables :
    /// 1. les collections locales de `Downloader` ;
    /// 2. les comptes suivis (`SuiviStore` : Reddit, X, TikTok) présents sur kDrive ;
    /// 3. les dossiers présents sur kDrive dont la source est déductible sans ambiguïté.
    func allCheckableCollections(model: Downloader) -> [UserCollection] {
        var result: [UserCollection] = []
        var seen = Set<String>()

        func append(_ collection: UserCollection) {
            let key = collection.id.lowercased()
            guard seen.insert(key).inserted else { return }
            result.append(collection)
        }

        for collection in model.collections {
            append(collection)
        }

        guard !remoteFolders.isEmpty else {
            return result
        }

        for name in SuiviStore.pseudosConnus(plateforme: .reddit) {
            let candidate = UserCollection(name: name)
            if remoteFolder(for: candidate.id) != nil {
                append(candidate)
            }
        }
        for name in SuiviStore.pseudosConnus(plateforme: .x) {
            let candidate = UserCollection(name: name, isTwitter: true)
            if remoteFolder(for: candidate.id) != nil {
                append(candidate)
            }
        }
        for name in SuiviStore.pseudosConnus(plateforme: .tiktok) {
            let candidate = UserCollection(name: name, isTikTok: true)
            if remoteFolder(for: candidate.id) != nil {
                append(candidate)
            }
        }

        for collection in inferredRemoteCollections {
            append(collection)
        }

        return result
    }

    /// Indexe et pré-trie les sous-dossiers distants en une passe.
    func applyDirectoryIndex(_ existing: [KDriveFolderItem]) {
        var index: [String: KDriveFolderItem] = [:]
        for item in existing {
            let key = FilenamePolicy.kDriveNormalizedName(item.name)
            if index[key] == nil {
                index[key] = item
            }
        }
        let inferred: [UserCollection] = index.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .compactMap { folder in
                KDriveFreshness.inferredSource(fromFolderName: folder.name).map { UserCollection(source: $0) }
            }
        folderCache.removeAll()
        inferredRemoteCollections = inferred
        remoteFolders = index
    }

    /// Recharge l'index des sous-dossiers du dossier parent kDrive configuré.
    func refreshDirectoryIndex(token: String, driveId: String, directoryId: String) async throws {
        let parentId = directoryId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "1"
            : directoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await KDriveService.shared.fetchSubdirectories(
            token: token,
            driveId: driveId,
            directoryId: parentId
        )
        applyDirectoryIndex(existing)
    }

    /// Vérifie une seule collection en comparant son dossier kDrive au site source.
    func check(
        collection: UserCollection,
        model: Downloader,
        token: String,
        driveId: String,
        directoryId: String,
        refreshFoldersFirst: Bool = true
    ) async {
        let canonical = collection.id
        setStatus(.checking, forCanonical: canonical)
        lastGlobalError = nil

        do {
            if refreshFoldersFirst || remoteFolders.isEmpty {
                try await refreshDirectoryIndex(token: token, driveId: driveId, directoryId: directoryId)
            }
            try Task.checkCancellation()

            let folder = remoteFolder(for: canonical)
            let remoteNames: Set<String>?
            if let folder {
                remoteNames = try await KDriveService.shared.fetchFileNames(
                    token: token,
                    driveId: driveId,
                    directoryId: String(folder.id)
                )
            } else {
                remoteNames = nil
            }
            try Task.checkCancellation()

            let localNames = await model.localFileNames(forFolderName: collection.folderName)
            try Task.checkCancellation()

            let sourceItems: [KDriveSourceItem]
            if let source = collection.feedSource {
                sourceItems = try await model.probeSourceHeadItems(for: source)
            } else {
                sourceItems = []
            }
            try Task.checkCancellation()

            let evaluation = KDriveFreshness.evaluate(
                remoteFileNames: remoteNames,
                sourceItems: sourceItems,
                localFileNames: localNames
            )
            setStatus(evaluation, forCanonical: canonical)
            checkedDates[canonical] = Date()
            LogCenter.kdrive(L("kDrive : vérification de \(collection.displayName) — \(evaluation.summaryText).",
                               "kDrive: checked \(collection.displayName) — \(evaluation.summaryText)."))
        } catch is CancellationError {
            if statuses[canonical]?.isChecking == true {
                setStatus(nil, forCanonical: canonical)
            }
        } catch {
            let message = error.localizedDescription
            setStatus(.unavailable(reason: message), forCanonical: canonical)
            checkedDates[canonical] = Date()
            LogCenter.err(L("kDrive : vérification impossible pour \(collection.displayName) : \(message)",
                            "kDrive: could not check \(collection.displayName): \(message)"))
        }
    }

    /// Lance la vérification asynchrone d'une collection individuelle.
    func startSingleCheck(
        collection: UserCollection,
        model: Downloader,
        token: String,
        driveId: String,
        directoryId: String
    ) {
        let canonical = collection.id
        singleTasks[canonical]?.cancel()
        singleTasks[canonical] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.singleTasks.removeValue(forKey: canonical) }
            await self.check(
                collection: collection,
                model: model,
                token: token,
                driveId: driveId,
                directoryId: directoryId,
                refreshFoldersFirst: self.remoteFolders.isEmpty
            )
        }
    }

    /// Vérifie un lot de collections (ou toutes les collections connues) à la suite.
    func checkAll(
        collections: [UserCollection]? = nil,
        model: Downloader,
        token: String,
        driveId: String,
        directoryId: String
    ) {
        stopChecking()
        isCheckingAll = true
        lastGlobalError = nil
        checkedCount = 0
        totalToCheck = collections?.count ?? max(1, model.collections.count)

        checkAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isCheckingAll = false
                self.checkAllTask = nil
            }
            do {
                try await self.refreshDirectoryIndex(token: token, driveId: driveId, directoryId: directoryId)
            } catch is CancellationError {
                return
            } catch {
                self.lastGlobalError = error.localizedDescription
                LogCenter.err(L("kDrive : impossible de lister les dossiers pour la vérification : \(error.localizedDescription)",
                                "kDrive: could not list folders for verification: \(error.localizedDescription)"))
                return
            }

            let targets = collections ?? self.allCheckableCollections(model: model)
            self.totalToCheck = targets.count
            self.checkedCount = 0
            guard !targets.isEmpty else { return }

            for collection in targets {
                if Task.isCancelled { break }
                await self.check(
                    collection: collection,
                    model: model,
                    token: token,
                    driveId: driveId,
                    directoryId: directoryId,
                    refreshFoldersFirst: false
                )
                self.checkedCount += 1
            }
        }
    }

    func stopChecking() {
        checkAllTask?.cancel()
        checkAllTask = nil
        for (_, task) in singleTasks {
            task.cancel()
        }
        singleTasks.removeAll()
        isCheckingAll = false
        for (key, value) in statuses where value.isChecking {
            setStatus(nil, forCanonical: key)
        }
    }

    // MARK: - Compteurs synthétiques

    var statusCounts: (upToDate: Int, outdated: Int, pendingUpload: Int, notOnDrive: Int, unavailable: Int) {
        var upToDate = 0
        var outdated = 0
        var pendingUpload = 0
        var notOnDrive = 0
        var unavailable = 0
        for status in statuses.values {
            switch status {
            case .checking: break
            case .upToDate: upToDate += 1
            case .outdated: outdated += 1
            case .pendingUpload: pendingUpload += 1
            case .notOnDrive: notOnDrive += 1
            case .unavailable: unavailable += 1
            }
        }
        return (upToDate, outdated, pendingUpload, notOnDrive, unavailable)
    }

    var upToDateCount: Int {
        statusCounts.upToDate
    }

    var outdatedCount: Int {
        statusCounts.outdated
    }

    var pendingUploadCount: Int {
        statusCounts.pendingUpload
    }

    var notOnDriveCount: Int {
        statusCounts.notOnDrive
    }

    var unavailableCount: Int {
        statusCounts.unavailable
    }

    /// Compteur Orange (collections avec nouveautés sur la source ou fichiers locaux à envoyer).
    var orangeCount: Int {
        let counts = statusCounts
        return counts.outdated + counts.pendingUpload
    }

    /// Compteur Rouge (collections absentes de kDrive ou en erreur de vérification).
    var redCount: Int {
        let counts = statusCounts
        return counts.notOnDrive + counts.unavailable
    }

    /// Résumé court pour la ligne de l'onglet Activité ou l'en-tête.
    var summaryLine: String {
        if isCheckingAll {
            return L("Vérification \(checkedCount)/\(max(1, totalToCheck))…",
                     "Checking \(checkedCount)/\(max(1, totalToCheck))…")
        }
        guard !statuses.isEmpty else {
            return L("Non vérifié", "Not checked")
        }
        let counts = statusCounts
        let up = counts.upToDate
        let orange = counts.outdated + counts.pendingUpload
        let red = counts.notOnDrive + counts.unavailable
        if red > 0 {
            return L("\(up) à jour · \(orange) en retard · \(red) absent/err.",
                     "\(up) up to date · \(orange) behind · \(red) missing/err.")
        }
        if orange > 0 {
            return L("\(orange) en retard · \(up) à jour",
                     "\(orange) behind · \(up) up to date")
        }
        return L("\(up) à jour sur kDrive",
                 "\(up) up to date on kDrive")
    }
}

/// Ligne de détail « Apple Calm Tech » (Colorimétrie C) :
/// - Quand la collection est **à jour**, tout le texte reste en gris secondaire apaisé (`DS.onSurfaceMuted`).
/// - Quand une action est requise, seul le mot-clé (`+4 sur la source`, `3 à envoyer`, `Absent de kDrive`)
///   s'allume en Ambre (`DS.calmAmber`) ou Rose-Corail (`DS.calmRose`), tandis que le compteur technique
///   (`· 98 sur kDrive`) reste en gris secondaire `DS.onSurfaceMuted`.
struct KDriveBicolorDetail: View {
    let status: KDriveFreshnessStatus
    var font: Font = .caption

    var body: some View {
        Group {
            if status.isUpToDate || status.isChecking {
                Text(status.summaryText)
                    .font(font)
                    .foregroundStyle(DS.onSurfaceMuted)
            } else {
                HStack(spacing: 0) {
                    Text(status.primaryLabel)
                        .font(font.weight(.semibold))
                        .foregroundStyle(status.tintColor)
                    if let detail = status.secondaryDetail {
                        Text(" · \(detail)")
                            .font(font)
                            .foregroundStyle(DS.onSurfaceMuted)
                    }
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.summaryText)
    }
}

/// Indicateur sobre (coche Sauge ou point lumineux 6 pt + libellé court).
struct KDriveFreshnessBadge: View {
    let status: KDriveFreshnessStatus
    var onAccentBackground = false

    var body: some View {
        let color = onAccentBackground ? DS.onAccent : status.tintColor
        HStack(spacing: 5) {
            if status.isChecking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else if status.isUpToDate {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(status.badgeText)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(status.isUpToDate && !onAccentBackground ? DS.onSurfaceMuted : color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.summaryText)
    }
}

/// Filtre de la feuille « État kDrive des collections ».
private enum KDriveFreshnessFilter: String, CaseIterable, Identifiable {
    case all
    case outdated
    case upToDate
    case notOnDrive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return L("Toutes", "All")
        case .outdated: return L("À mettre à jour", "Outdated")
        case .upToDate: return L("À jour", "Up to date")
        case .notOnDrive: return L("Hors kDrive", "Not on kDrive")
        }
    }
}

/// Feuille complète « État kDrive des collections » : compare les collections
/// de l'app, les suivis et les dossiers du Drive avec la première page de chaque
/// site source, affiche un indicateur détaillé et permet de lancer la mise à jour.
struct KDriveCollectionsStatusView: View {
    var model: Downloader
    var onDownloadCollection: ((UserCollection) -> Void)? = nil

    @State private var center = KDriveFreshnessCenter.shared
    @State private var batch = KDriveBatchController.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kDriveApiToken") private var token = ""
    @AppStorage("kDriveId") private var driveId = ""
    @AppStorage("kDriveDirectoryId") private var directoryId = "1"
    @AppStorage("kDriveDirectoryName") private var directoryName = ""
    @State private var filter: KDriveFreshnessFilter = .all
    @State private var selectedIds: Set<String> = []
    @State private var confirmDownloadSync = false
    @State private var confirmUploadAndDelete = false

    private var kDriveConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Collections à télécharger en lot : uniquement celles déjà présentes sur
    /// kDrive, dans la liste filtrée, qui ne sont ni déjà à jour ni uniquement
    /// en attente d'envoi local.
    private func downloadableCollections(from filtered: [UserCollection]) -> [UserCollection] {
        filtered.filter { collection in
            guard center.remoteFolder(for: collection.id) != nil else { return false }
            switch center.status(for: collection.id) {
            case .upToDate, .pendingUpload, .notOnDrive:
                return false
            default:
                return true
            }
        }
    }

    private func toggleSelection(for id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func filteredCollections(from all: [UserCollection]) -> [UserCollection] {
        if filter == .all { return all }
        return all.filter { collection in
            let status = center.status(for: collection.id)
            switch filter {
            case .all:
                return true
            case .outdated:
                switch status {
                case .outdated, .pendingUpload:
                    return true
                default:
                    return false
                }
            case .upToDate:
                return status?.isUpToDate == true
            case .notOnDrive:
                switch status {
                case .notOnDrive, .unavailable:
                    return true
                default:
                    return status == nil && center.remoteFolder(for: collection.id) == nil
                }
            }
        }
    }

    var body: some View {
        let configured = kDriveConfigured
        let all = configured ? center.allCheckableCollections(model: model) : []
        let filtered = configured ? filteredCollections(from: all) : []
        let selected = (configured && !selectedIds.isEmpty)
            ? all.filter { selectedIds.contains($0.id) }
            : []
        let targets = selected.isEmpty
            ? (configured ? downloadableCollections(from: filtered) : [])
            : selected
        let local = model.collections
        let allFilteredSelected = !filtered.isEmpty && filtered.allSatisfy { selectedIds.contains($0.id) }
        let remoteEmpty = center.remoteFolders.isEmpty
        let batchRunning = batch.isRunning
        let modelRunning = model.running

        NavigationStack {
            Group {
                if !configured {
                    ContentUnavailableView {
                        Label(L("kDrive non configuré", "kDrive not configured"), systemImage: "icloud.slash")
                    } description: {
                        Text(L("Configure le token API et l’ID du Drive dans Réglages > Infomaniak kDrive pour comparer tes collections au site source.",
                               "Configure the API token and Drive ID in Settings > Infomaniak kDrive to compare your collections with the source site."))
                    }
                } else {
                    List {
                        Section {
                            KDriveStatusHeaderCard(
                                downloadTargetsCount: targets.count,
                                hasSelection: !selected.isEmpty,
                                canUploadLocal: !local.isEmpty,
                                modelRunning: modelRunning,
                                onStopBatch: { batch.stop(model: model) },
                                onConfirmDownload: { confirmDownloadSync = true },
                                onConfirmUpload: { confirmUploadAndDelete = true }
                            )
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                        Section {
                            Picker(L("Filtre", "Filter"), selection: $filter) {
                                ForEach(KDriveFreshnessFilter.allCases) { item in
                                    Text(item.label).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: DS.space(2), trailing: 0))

                        if filtered.isEmpty {
                            Section {
                                Text(L("Aucune collection dans cette catégorie.", "No collection in this category."))
                                    .font(.footnote)
                                    .foregroundStyle(DS.onSurfaceMuted)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, DS.space(4))
                            }
                        } else {
                            Section {
                                ForEach(filtered, id: \.id) { collection in
                                    collectionRow(
                                        collection,
                                        remoteIndexEmpty: remoteEmpty,
                                        batchRunning: batchRunning,
                                        modelRunning: modelRunning
                                    )
                                }
                            } header: {
                                HStack(spacing: DS.space(2)) {
                                    if !selected.isEmpty {
                                        Text(L("\(selected.count) sélectionnée(s)", "\(selected.count) selected"))
                                            .foregroundStyle(DS.accentEmphasis)
                                    } else {
                                        Text(L("\(filtered.count) collection(s)", "\(filtered.count) collection(s)"))
                                    }
                                    Spacer(minLength: 4)
                                    if !allFilteredSelected {
                                        Button(selected.isEmpty
                                            ? L("Tout sélectionner", "Select all")
                                            : L("Tout", "All")) {
                                            var updated = selectedIds
                                            for item in filtered {
                                                updated.insert(item.id)
                                            }
                                            selectedIds = updated
                                        }
                                        .font(.caption.weight(.semibold))
                                        .textCase(nil)
                                        .disabled(batchRunning)
                                    }
                                    if !selected.isEmpty {
                                        Button(L("Effacer", "Clear")) {
                                            selectedIds.removeAll()
                                        }
                                        .font(.caption.weight(.semibold))
                                        .textCase(nil)
                                        .foregroundStyle(DS.onSurfaceMuted)
                                        .disabled(batchRunning)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L("État kDrive", "kDrive Status"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if configured {
                    ToolbarItem(placement: .topBarLeading) {
                        KDriveCheckAllToolbarButton(isDisabledWhenIdle: all.isEmpty) {
                            center.checkAll(
                                model: model,
                                token: token,
                                driveId: driveId,
                                directoryId: directoryId
                            )
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("OK", "OK")) { dismiss() }
                }
            }
            .task {
                if configured, center.remoteFolders.isEmpty {
                    try? await center.refreshDirectoryIndex(
                        token: token,
                        driveId: driveId,
                        directoryId: directoryId
                    )
                }
            }
        }
        .tint(DS.accentEmphasis)
        .confirmationDialog(
            selected.isEmpty
                ? L("Télécharger, envoyer sur kDrive et nettoyer ?", "Download, upload to kDrive and clean up?")
                : L("Télécharger, envoyer et nettoyer (\(selected.count)) ?", "Download, upload and clean up (\(selected.count))?"),
            isPresented: $confirmDownloadSync,
            titleVisibility: .visible
        ) {
            Button(L("Lancer", "Start"), role: .destructive) {
                selectedIds.removeAll()
                batch.startDownloadUploadAndDelete(
                    collections: targets,
                    model: model,
                    token: token,
                    driveId: driveId,
                    parentDirectoryId: directoryId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1" : directoryId
                )
            }
            Button(L("Annuler", "Cancel"), role: .cancel) { }
        } message: {
            if selected.isEmpty {
                Text(L("Pour chaque collection déjà présente sur kDrive, seuls les médias manquants seront téléchargés, envoyés sur kDrive puis supprimés de l'app (médias et collection) avant de passer à la suivante.",
                       "For each collection already on kDrive, only missing media will be downloaded, uploaded to kDrive, then removed from the app (media and collection) before moving to the next."))
            } else {
                Text(L("Pour chacune des \(selected.count) collection(s) sélectionnée(s), seuls les médias manquants seront téléchargés, envoyés sur kDrive puis supprimés automatiquement de l'app (médias et collection) avant de passer à la suivante.",
                       "For each of the \(selected.count) selected collection(s), only missing media will be downloaded, uploaded to kDrive, then automatically removed from the app (media and collection) before moving to the next."))
            }
        }
        .confirmationDialog(
            L("Tout envoyer sur kDrive et supprimer ?", "Upload all to kDrive and delete?"),
            isPresented: $confirmUploadAndDelete,
            titleVisibility: .visible
        ) {
            Button(L("Envoyer et supprimer", "Upload & delete"), role: .destructive) {
                batch.startUploadAllAndDelete(
                    collections: local,
                    model: model,
                    token: token,
                    driveId: driveId,
                    parentDirectoryId: directoryId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1" : directoryId
                )
            }
            Button(L("Annuler", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("Toutes les collections locales seront envoyées vers leur dossier kDrive, puis les médias et collections envoyés avec succès seront supprimés automatiquement de l'app.",
                   "All local collections will be uploaded to their kDrive folder, then successfully uploaded media and collections will be automatically removed from the app."))
        }
    }

    private func collectionRow(
        _ collection: UserCollection,
        remoteIndexEmpty: Bool,
        batchRunning: Bool,
        modelRunning: Bool
    ) -> some View {
        let status = center.status(for: collection.id)
        return KDriveCollectionRowView(
            collection: collection,
            status: status,
            folder: center.remoteFolder(for: collection.id),
            remoteIndexEmpty: remoteIndexEmpty,
            isSelected: selectedIds.contains(collection.id),
            batchRunning: batchRunning,
            modelRunning: modelRunning,
            showsDownload: shouldOfferDownload(for: status) && onDownloadCollection != nil,
            onToggle: { toggleSelection(for: collection.id) },
            onDownload: onDownloadCollection.map { handler in {
                dismiss()
                handler(collection)
            } },
            onSingleCheck: {
                center.startSingleCheck(
                    collection: collection,
                    model: model,
                    token: token,
                    driveId: driveId,
                    directoryId: directoryId
                )
            }
        )
        .equatable()
    }

    private func shouldOfferDownload(for status: KDriveFreshnessStatus?) -> Bool {
        if case .outdated = status {
            return true
        }
        return false
    }
}

private struct KDriveCheckAllToolbarButton: View {
    @State private var center = KDriveFreshnessCenter.shared
    let isDisabledWhenIdle: Bool
    let onStart: () -> Void

    var body: some View {
        Button {
            if center.isCheckingAll {
                center.stopChecking()
            } else {
                onStart()
            }
        } label: {
            if center.isCheckingAll {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("\(center.checkedCount)/\(max(1, center.totalToCheck))")
                        .font(.caption.monospacedDigit())
                }
            } else {
                Text(L("Vérifier", "Check"))
            }
        }
        .disabled(isDisabledWhenIdle && !center.isCheckingAll)
    }
}

/// Carte d'en-tête isolée de la liste : les progressions de vérification ou
/// d'envoi en lot ne réévaluent que cette carte et jamais les lignes `ForEach`.
private struct KDriveStatusHeaderCard: View {
    @State private var center = KDriveFreshnessCenter.shared
    @State private var batch = KDriveBatchController.shared
    @State private var uploader = KDriveContinuousUploadController.shared

    let downloadTargetsCount: Int
    let hasSelection: Bool
    let canUploadLocal: Bool
    let modelRunning: Bool
    let onStopBatch: () -> Void
    let onConfirmDownload: () -> Void
    let onConfirmUpload: () -> Void

    var body: some View {
        let counts = center.statusCounts
        let upCount = counts.upToDate
        let orangeCount = counts.outdated + counts.pendingUpload
        let redCount = counts.notOnDrive + counts.unavailable

        VStack(alignment: .leading, spacing: DS.space(3)) {
            HStack(spacing: 0) {
                consoleMetric(
                    count: upCount,
                    label: L("à jour", "up to date"),
                    valueColor: DS.onSurface,
                    leadingSymbol: "checkmark",
                    symbolColor: DS.calmSage
                )
                metricDivider
                consoleMetric(
                    count: orangeCount,
                    label: L("en retard", "behind"),
                    valueColor: DS.calmAmber
                )
                metricDivider
                consoleMetric(
                    count: redCount,
                    label: L("absents", "missing"),
                    valueColor: DS.calmRose
                )
            }

            if center.isCheckingAll, center.totalToCheck > 0 {
                let fraction = min(1.0, Double(center.checkedCount) / Double(max(1, center.totalToCheck)))
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(DS.calmAmber)
            } else {
                calmTricolorGauge(up: upCount, orange: orangeCount, red: redCount)
            }

            if let error = center.lastGlobalError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(DS.calmRose)
            }

            batchActionBar

            if batch.isRunning {
                VStack(alignment: .leading, spacing: DS.space(1)) {
                    HStack(spacing: DS.space(2)) {
                        ProgressView().controlSize(.mini)
                        Text(batch.progressLabel)
                            .font(DS.monoCaption)
                            .foregroundStyle(DS.onSurface)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(batch.completedCount)/\(max(1, batch.totalCount))")
                            .font(DS.monoCaption)
                            .foregroundStyle(DS.onSurfaceMuted)
                    }
                    ProgressView(value: Double(batch.completedCount), total: Double(max(1, batch.totalCount)))
                        .progressViewStyle(.linear)
                        .tint(batch.mode == .uploadAndDelete ? DS.calmAmber : DS.accent)
                }
            } else if let summary = batch.lastSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(batch.lastHadError ? DS.calmRose : DS.onSurfaceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.space(3))
        .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusM))
        .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
    }

    private func consoleMetric(
        count: Int,
        label: String,
        valueColor: Color,
        leadingSymbol: String? = nil,
        symbolColor: Color? = nil
    ) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(symbolColor ?? valueColor)
                }
                Text("\(count)")
                    .font(DS.monoTitle)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Text(label)
                .font(DS.caption2)
                .foregroundStyle(DS.onSurfaceMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        DS.separator
            .frame(width: 1, height: 30)
            .padding(.vertical, DS.space(1))
    }

    private func calmTricolorGauge(up: Int, orange: Int, red: Int) -> some View {
        let total = up + orange + red
        return GeometryReader { geo in
            let width = geo.size.width
            if total == 0 {
                Capsule()
                    .fill(DS.separator)
                    .frame(width: width, height: 3)
            } else {
                HStack(spacing: 3) {
                    if up > 0 {
                        Capsule()
                            .fill(DS.calmSage.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .layoutPriority(Double(up))
                    }
                    if orange > 0 {
                        Capsule()
                            .fill(DS.calmAmber)
                            .frame(maxWidth: .infinity)
                            .layoutPriority(Double(orange))
                    }
                    if red > 0 {
                        Capsule()
                            .fill(DS.calmRose)
                            .frame(maxWidth: .infinity)
                            .layoutPriority(Double(red))
                    }
                }
                .frame(width: width, height: 3)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private var batchActionBar: some View {
        let downloadRunning = batch.mode == .downloadAll && batch.isRunning
        let uploadRunning = batch.mode == .uploadAndDelete && batch.isRunning
        let canStartDownload = downloadTargetsCount > 0 && !modelRunning && !batch.isRunning && !uploader.isUploading
        let canStartUpload = canUploadLocal && !modelRunning && !batch.isRunning && !uploader.isUploading

        return HStack(spacing: DS.space(2)) {
            Button {
                if downloadRunning {
                    onStopBatch()
                } else {
                    onConfirmDownload()
                }
            } label: {
                HStack(spacing: DS.space(1)) {
                    Image(systemName: downloadRunning ? "stop.fill" : "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(downloadRunning
                        ? L("Arrêter", "Stop")
                        : (hasSelection
                            ? L("Télécharger (\(downloadTargetsCount))", "Download (\(downloadTargetsCount))")
                            : L("Tout télécharger", "Download all")))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(downloadRunning ? DS.error : (canStartDownload ? DS.onAccent : DS.onSurfaceMuted))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, DS.space(2))
                .background(
                    downloadRunning ? DS.error.opacity(0.12) : (canStartDownload ? DS.accent : DS.surface),
                    in: RoundedRectangle(cornerRadius: DS.radiusS)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.radiusS))
            }
            .buttonStyle(DSPressableButtonStyle())
            .disabled(!downloadRunning && !canStartDownload)
            .accessibilityLabel(downloadRunning
                ? L("Arrêter le téléchargement groupé", "Stop batch download")
                : (hasSelection
                    ? L("Télécharger, envoyer et nettoyer la sélection (\(downloadTargetsCount) collections)", "Download, upload and clean up selection (\(downloadTargetsCount) collections)")
                    : L("Tout télécharger (\(downloadTargetsCount) collections)", "Download all (\(downloadTargetsCount) collections)")))

            Button {
                if uploadRunning {
                    onStopBatch()
                } else {
                    onConfirmUpload()
                }
            } label: {
                HStack(spacing: DS.space(1)) {
                    Image(systemName: uploadRunning ? "stop.fill" : "icloud.and.arrow.up.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(uploadRunning ? L("Arrêter", "Stop") : L("Uploader & suppr.", "Upload & delete"))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(uploadRunning ? DS.error : (canStartUpload ? DS.accentEmphasis : DS.onSurfaceMuted))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, DS.space(2))
                .background(
                    uploadRunning ? DS.error.opacity(0.12) : DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.radiusS)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusS)
                        .strokeBorder(uploadRunning ? DS.error.opacity(0.4) : (canStartUpload ? DS.accentEmphasis.opacity(0.35) : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.radiusS))
            }
            .buttonStyle(DSPressableButtonStyle())
            .disabled(!uploadRunning && !canStartUpload)
            .accessibilityLabel(uploadRunning
                ? L("Arrêter l'envoi kDrive groupé", "Stop batch kDrive upload")
                : L("Tout envoyer sur kDrive puis supprimer localement", "Upload all to kDrive then delete locally"))
        }
    }
}

/// Logo vectoriel dédié à l'état kDrive des collections (nuage + coche de
/// vérification), dessiné en géométrie native pour rester net à toute taille
/// Dynamic Type et cohérent avec le style de l'app.
struct KDriveStatusIcon: View {
    var baseSize: CGFloat = 20
    var statusDotColor: Color? = nil
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var renderedSize: CGFloat {
        min(baseSize * scale, baseSize * 1.35)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            KDriveCloudCheckShape()
                .stroke(
                    style: StrokeStyle(
                        lineWidth: max(1.5, renderedSize * 0.095),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: renderedSize, height: renderedSize)

            if let statusDotColor {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(DS.surfaceElevated, lineWidth: 1.2))
                    .offset(x: 2, y: -1)
            }
        }
    }
}

private struct KDriveCloudCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24.0
        let sy = rect.height / 24.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        // Contour nuage équilibré (viewBox 24×24)
        path.move(to: pt(6.5, 18.0))
        path.addCurve(to: pt(3.0, 14.5), control1: pt(4.5, 18.0), control2: pt(3.0, 16.5))
        path.addCurve(to: pt(6.2, 11.1), control1: pt(3.0, 12.7), control2: pt(4.4, 11.3))
        path.addCurve(to: pt(12.2, 6.0), control1: pt(6.8, 8.1), control2: pt(9.2, 6.0))
        path.addCurve(to: pt(17.8, 10.6), control1: pt(15.2, 6.0), control2: pt(17.6, 8.0))
        path.addCurve(to: pt(21.0, 14.3), control1: pt(19.7, 10.9), control2: pt(21.0, 12.4))
        path.addCurve(to: pt(17.4, 18.0), control1: pt(21.0, 16.4), control2: pt(19.4, 18.0))
        path.closeSubpath()

        // Coche de vérification centrée dans le nuage
        path.move(to: pt(9.0, 13.4))
        path.addLine(to: pt(11.2, 15.5))
        path.addLine(to: pt(15.4, 11.1))
        return path
    }
}

private struct KDriveCollectionRowView: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.collection == rhs.collection
            && lhs.status == rhs.status
            && lhs.folder == rhs.folder
            && lhs.remoteIndexEmpty == rhs.remoteIndexEmpty
            && lhs.isSelected == rhs.isSelected
            && lhs.batchRunning == rhs.batchRunning
            && lhs.modelRunning == rhs.modelRunning
            && lhs.showsDownload == rhs.showsDownload
    }

    let collection: UserCollection
    let status: KDriveFreshnessStatus?
    let folder: KDriveFolderItem?
    let remoteIndexEmpty: Bool
    let isSelected: Bool
    let batchRunning: Bool
    let modelRunning: Bool
    let showsDownload: Bool
    let onToggle: () -> Void
    let onDownload: (() -> Void)?
    let onSingleCheck: () -> Void

    private var detailColor: Color {
        if let status { return status.tintColor }
        if folder != nil { return DS.calmSage }
        if !remoteIndexEmpty { return DS.calmRose }
        return DS.onSurfaceMuted
    }

    private var expectedFolderName: String {
        folder?.name ?? FilenamePolicy.kDriveFolderName(collection.kDriveLabel)
    }

    private var isCalmUpToDate: Bool {
        (status?.isUpToDate == true) || (status == nil && folder != nil)
    }

    var body: some View {
        HStack(spacing: DS.space(2)) {
            Button(action: onToggle) {
                HStack(spacing: DS.space(3)) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? DS.accent : DS.onSurfaceMuted.opacity(0.45))
                        .accessibilityHidden(true)

                    leadingTile

                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCalmUpToDate ? DS.onSurface.opacity(0.84) : DS.onSurface)
                            .lineLimit(1)

                        if let status {
                            KDriveBicolorDetail(status: status, font: .caption)
                        } else if let folder {
                            folderDetailRow(folder)
                        } else if !remoteIndexEmpty {
                            HStack(spacing: 0) {
                                Text(L("Absent de kDrive", "Not on kDrive"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(DS.calmRose)
                                Text(" \u{00B7} \(expectedFolderName)")
                                    .font(.caption)
                                    .foregroundStyle(DS.onSurfaceMuted)
                            }
                            .lineLimit(1)
                        } else {
                            Text(L("Non vérifié \u{00B7} \(expectedFolderName)", "Not checked \u{00B7} \(expectedFolderName)"))
                                .font(.caption)
                                .foregroundStyle(DS.onSurfaceMuted)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(batchRunning)
            .accessibilityLabel(collection.displayName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(isSelected
                ? L("Appuyer pour désélectionner", "Tap to deselect")
                : L("Appuyer pour sélectionner pour téléchargement, envoi kDrive et nettoyage",
                    "Tap to select for download, kDrive upload and cleanup"))

            if showsDownload {
                Button(action: { onDownload?() }) {
                    Image(systemName: "arrow.down.circle")
                        .font(.body)
                        .foregroundStyle(detailColor)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(modelRunning)
                .accessibilityLabel(L("Télécharger les nouveautés de \(collection.displayName)",
                                      "Download new media from \(collection.displayName)"))
            }

            Button(action: onSingleCheck) {
                if status?.isChecking == true {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(DS.onSurfaceMuted)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.borderless)
            .disabled(status?.isChecking == true)
            .accessibilityLabel(L("Vérifier \(collection.displayName)", "Check \(collection.displayName)"))
        }
        .padding(.vertical, 1)
    }

    /// Formateur de date partagé entre les lignes : évite de reconstruire un
    /// formateur ICU par cellule au défilement et n'est appelé qu'une fois.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func folderDetailRow(_ folder: KDriveFolderItem) -> some View {
        let ts = folder.lastModifiedAt ?? folder.updatedAt ?? 0
        return Group {
            if ts > 0 {
                let dateText = Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
                Text(L("Sur kDrive \u{00B7} \(dateText)",
                       "On kDrive \u{00B7} \(dateText)"))
            } else {
                Text(L("Sur kDrive \u{00B7} \(expectedFolderName)",
                       "On kDrive \u{00B7} \(expectedFolderName)"))
            }
        }
        .font(.caption)
        .foregroundStyle(DS.onSurfaceMuted)
        .lineLimit(1)
    }

    @ViewBuilder
    private var leadingTile: some View {
        if isCalmUpToDate {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(DS.calmSage)
                .frame(width: 30, height: 30)
                .background(DS.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.radiusS))
                .accessibilityHidden(true)
        } else if let status, !status.isChecking {
            Image(systemName: "icloud.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(status.tintColor)
                .frame(width: 30, height: 30)
                .background(status.tintColor.opacity(0.13), in: RoundedRectangle(cornerRadius: DS.radiusS))
                .accessibilityHidden(true)
        } else if !remoteIndexEmpty, status == nil {
            Image(systemName: "icloud.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.calmRose)
                .frame(width: 30, height: 30)
                .background(DS.calmRose.opacity(0.13), in: RoundedRectangle(cornerRadius: DS.radiusS))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "icloud")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.onSurfaceMuted)
                .frame(width: 30, height: 30)
                .background(DS.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.radiusS))
                .accessibilityHidden(true)
        }
    }
}

/// Orchestrateur d'actions groupées réservé à la feuille « État kDrive » :
/// - « Tout télécharger » : pour chaque collection déjà sur kDrive, enchaîne
///   téléchargement → envoi kDrive → suppression des médias et de la collection
///   dans l'app, puis passe à la suivante.
/// - « Uploader & supprimer » : pour chaque collection locale, envoie vers
///   kDrive, déduplique, puis supprime les médias et la collection (les échecs
///   éventuels sont conservés).
@MainActor
@Observable
final class KDriveBatchController {
    enum Mode {
        case idle
        case downloadAll
        case uploadAndDelete
    }

    static let shared = KDriveBatchController()

    private(set) var mode: Mode = .idle
    private(set) var isRunning = false
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var progressLabel = ""
    private(set) var lastSummary: String?
    private(set) var lastHadError = false

    @ObservationIgnored private var batchTask: Task<Void, Never>?

    private init() {}

    func stop(model: Downloader) {
        batchTask?.cancel()
        batchTask = nil
        if model.running {
            model.stop()
        }
        if KDriveContinuousUploadController.shared.isUploading {
            KDriveContinuousUploadController.shared.cancel()
        }
        isRunning = false
        mode = .idle
        progressLabel = ""
        lastSummary = L("Opération groupée interrompue.", "Batch operation stopped.")
        lastHadError = false
    }

    func startDownloadUploadAndDelete(
        collections: [UserCollection],
        model: Downloader,
        token: String,
        driveId: String,
        parentDirectoryId: String
    ) {
        guard !isRunning, !collections.isEmpty else { return }
        mode = .downloadAll
        isRunning = true
        completedCount = 0
        totalCount = collections.count
        progressLabel = L("Préparation…", "Preparing…")
        lastSummary = nil
        lastHadError = false

        batchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let service = KDriveService.shared
            var existingSubdirectories: [KDriveFolderItem] = []

            do {
                existingSubdirectories = try await service.fetchSubdirectories(
                    token: token,
                    driveId: driveId,
                    directoryId: parentDirectoryId
                )
            } catch {
                self.isRunning = false
                self.mode = .idle
                self.batchTask = nil
                self.progressLabel = ""
                self.lastSummary = L("Impossible de lire kDrive : \(error.localizedDescription)",
                                     "Could not read kDrive: \(error.localizedDescription)")
                self.lastHadError = true
                return
            }

            var totalUploaded = 0
            var totalDeleted = 0
            var totalFailed = 0
            var stoppedForStorage = false
            var cancelled = false

            for collection in collections {
                if Task.isCancelled { cancelled = true; break }

                var remoteIndex: KDriveRemoteIndex?
                var preFetchedRemoteCount: Int?
                if let remoteFolder = self.matchingRemoteFolder(for: collection, in: existingSubdirectories) {
                    self.progressLabel = L("Analyse kDrive : \(collection.displayName)",
                                           "Scanning kDrive: \(collection.displayName)")
                    do {
                        let remoteNames = try await service.fetchFileNames(
                            token: token,
                            driveId: driveId,
                            directoryId: String(remoteFolder.id)
                        )
                        remoteIndex = KDriveRemoteIndex(fileNames: remoteNames)
                        preFetchedRemoteCount = remoteNames.count
                        LogCenter.kdrive(L("kDrive (lot) : \(remoteNames.count) fichier(s) déjà présent(s) pour \(collection.displayName) — seuls les médias manquants seront téléchargés.",
                                           "kDrive (batch): \(remoteNames.count) file(s) already present for \(collection.displayName) — downloading missing media only."))
                    } catch is CancellationError {
                        cancelled = true
                        break
                    } catch {
                        LogCenter.err(L("kDrive (lot) : lecture impossible pour \(collection.displayName) : \(error.localizedDescription)",
                                        "kDrive (batch): could not read \(collection.displayName): \(error.localizedDescription)"))
                        totalFailed += 1
                        self.completedCount += 1
                        continue
                    }
                }

                if Task.isCancelled { cancelled = true; break }

                self.progressLabel = L("Téléchargement : \(collection.displayName)",
                                       "Downloading: \(collection.displayName)")
                model.download(user: collection.id, skippingRemoteMedia: remoteIndex)

                while model.running {
                    if Task.isCancelled {
                        model.stop()
                        while model.running {
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        cancelled = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }

                if cancelled || Task.isCancelled { cancelled = true; break }

                if model.storageLimitReached {
                    stoppedForStorage = true
                }

                let outcome = await self.uploadAndCleanCollection(
                    collection,
                    model: model,
                    token: token,
                    driveId: driveId,
                    parentDirectoryId: parentDirectoryId,
                    existingSubdirectories: &existingSubdirectories,
                    preFetchedRemoteCount: preFetchedRemoteCount
                )
                totalUploaded += outcome.uploaded
                totalDeleted += outcome.deleted
                totalFailed += outcome.failed
                if outcome.cancelled {
                    cancelled = true
                    break
                }

                self.completedCount += 1
                if stoppedForStorage { break }
            }

            self.isRunning = false
            self.mode = .idle
            self.batchTask = nil
            self.progressLabel = ""

            if cancelled || Task.isCancelled {
                self.lastSummary = L("Synchronisation arrêtée (\(self.completedCount)/\(collections.count) · \(totalUploaded) envoyé(s), \(totalDeleted) supprimé(s)).",
                                     "Sync stopped (\(self.completedCount)/\(collections.count) · \(totalUploaded) uploaded, \(totalDeleted) deleted).")
                self.lastHadError = false
            } else if stoppedForStorage {
                self.lastSummary = L("Plafond disque atteint (\(self.completedCount)/\(collections.count) · \(totalUploaded) envoyé(s), \(totalDeleted) supprimé(s)).",
                                     "Disk limit reached (\(self.completedCount)/\(collections.count) · \(totalUploaded) uploaded, \(totalDeleted) deleted).")
                self.lastHadError = true
            } else if totalFailed > 0 {
                self.lastSummary = L("\(self.completedCount) collection(s) · \(totalUploaded) envoyé(s), \(totalDeleted) supprimé(s) · \(totalFailed) échec(s) conservé(s).",
                                     "\(self.completedCount) collection(s) · \(totalUploaded) uploaded, \(totalDeleted) deleted · \(totalFailed) failure(s) kept.")
                self.lastHadError = true
            } else {
                self.lastSummary = L("Terminé : \(self.completedCount) collection(s) · \(totalUploaded) envoyé(s), \(totalDeleted) supprimé(s).",
                                     "Done: \(self.completedCount) collection(s) · \(totalUploaded) uploaded, \(totalDeleted) deleted.")
                self.lastHadError = false
            }
        }
    }

    func startUploadAllAndDelete(
        collections: [UserCollection],
        model: Downloader,
        token: String,
        driveId: String,
        parentDirectoryId: String
    ) {
        guard !isRunning, !collections.isEmpty else { return }
        mode = .uploadAndDelete
        isRunning = true
        completedCount = 0
        totalCount = collections.count
        progressLabel = L("Analyse des collections locales…", "Scanning local collections…")
        lastSummary = nil
        lastHadError = false

        batchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let service = KDriveService.shared
            var existingSubdirectories: [KDriveFolderItem] = []

            do {
                existingSubdirectories = try await service.fetchSubdirectories(
                    token: token,
                    driveId: driveId,
                    directoryId: parentDirectoryId
                )
            } catch {
                self.isRunning = false
                self.mode = .idle
                self.batchTask = nil
                self.progressLabel = ""
                self.lastSummary = L("Impossible de lire kDrive : \(error.localizedDescription)",
                                     "Could not read kDrive: \(error.localizedDescription)")
                self.lastHadError = true
                return
            }

            var totalUploaded = 0
            var totalDeleted = 0
            var totalFailed = 0
            var cancelled = false

            for collection in collections {
                if Task.isCancelled { cancelled = true; break }

                let outcome = await self.uploadAndCleanCollection(
                    collection,
                    model: model,
                    token: token,
                    driveId: driveId,
                    parentDirectoryId: parentDirectoryId,
                    existingSubdirectories: &existingSubdirectories
                )
                totalUploaded += outcome.uploaded
                totalDeleted += outcome.deleted
                totalFailed += outcome.failed
                if outcome.cancelled {
                    cancelled = true
                    break
                }

                self.completedCount += 1
            }

            self.isRunning = false
            self.mode = .idle
            self.batchTask = nil
            self.progressLabel = ""

            if cancelled || Task.isCancelled {
                self.lastSummary = L("Envoi groupé arrêté (\(totalUploaded) envoyé(s), \(totalDeleted) supprimé(s)).",
                                     "Batch upload stopped (\(totalUploaded) uploaded, \(totalDeleted) deleted).")
                self.lastHadError = false
            } else if totalFailed > 0 {
                self.lastSummary = L("\(totalUploaded) envoyé(s), \(totalDeleted) supprimé(s) · \(totalFailed) échec(s) conservé(s).",
                                     "\(totalUploaded) uploaded, \(totalDeleted) deleted · \(totalFailed) failure(s) kept.")
                self.lastHadError = true
            } else {
                self.lastSummary = L("Terminé : \(totalUploaded) envoyé(s), \(totalDeleted) supprimé(s) de l'app.",
                                     "Done: \(totalUploaded) uploaded, \(totalDeleted) deleted from app.")
                self.lastHadError = false
            }
        }
    }

    private func matchingRemoteFolder(
        for collection: UserCollection,
        in subdirectories: [KDriveFolderItem]
    ) -> KDriveFolderItem? {
        for candidate in KDriveFreshness.candidateFolderNames(for: collection.id) {
            if let match = subdirectories.first(where: { FilenamePolicy.kDriveNameMatch($0.name, candidate) }) {
                return match
            }
        }
        return nil
    }

    private func uploadAndCleanCollection(
        _ collection: UserCollection,
        model: Downloader,
        token: String,
        driveId: String,
        parentDirectoryId: String,
        existingSubdirectories: inout [KDriveFolderItem],
        preFetchedRemoteCount: Int? = nil
    ) async -> (uploaded: Int, deleted: Int, failed: Int, cancelled: Bool) {
        let service = KDriveService.shared
        let uploader = KDriveContinuousUploadController.shared

        self.progressLabel = L("Préparation : \(collection.displayName)",
                               "Preparing: \(collection.displayName)")

        let localURLs = await model.localFileURLs(forFolderName: collection.folderName)
        if localURLs.isEmpty {
            if model.collections.contains(where: { $0.id == collection.id }) {
                model.deleteDownloads(for: collection.id)
            }
            if let preFetchedRemoteCount {
                KDriveFreshnessCenter.shared.markUploaded(
                    collectionLabel: collection.id,
                    remoteFileCount: preFetchedRemoteCount
                )
            }
            return (0, 0, 0, false)
        }

        do {
            let targetFolderName = FilenamePolicy.kDriveFolderName(collection.kDriveLabel)
            let folder: KDriveFolderItem
            if let match = matchingRemoteFolder(for: collection, in: existingSubdirectories) {
                folder = match
            } else {
                let created = try await service.createDirectory(
                    token: token,
                    driveId: driveId,
                    parentDirectoryId: parentDirectoryId,
                    folderName: targetFolderName
                )
                existingSubdirectories.append(created)
                folder = created
            }

            if Task.isCancelled { return (0, 0, 0, true) }
            let remoteNames = try await service.fetchFileNames(
                token: token,
                driveId: driveId,
                directoryId: String(folder.id)
            )
            if Task.isCancelled { return (0, 0, 0, true) }

            let (toUpload, duplicates) = await Task.detached(priority: .utility) {
                let normalizedRemote = Set(remoteNames.map { FilenamePolicy.kDriveNormalizedName($0) })
                var pending: [URL] = []
                var dupes: [URL] = []
                for url in localURLs {
                    if Task.isCancelled { break }
                    let candidates = FilenamePolicy.kDriveRemoteCandidateNames(for: url.lastPathComponent)
                    let alreadyThere = candidates.contains {
                        normalizedRemote.contains(FilenamePolicy.kDriveNormalizedName($0))
                    }
                    if alreadyThere {
                        dupes.append(url)
                    } else {
                        pending.append(url)
                    }
                }
                return (pending, dupes)
            }.value

            if Task.isCancelled { return (0, 0, 0, true) }

            var uploaded = 0
            var failed = 0
            var confirmedOnDrive = duplicates

            if !toUpload.isEmpty {
                self.progressLabel = L("Envoi : \(collection.displayName) (\(toUpload.count))",
                                       "Uploading: \(collection.displayName) (\(toUpload.count))")
                let lot = KDriveUploadLot(
                    files: toUpload,
                    directoryId: String(folder.id),
                    directoryName: folder.name,
                    collectionLabel: collection.kDriveLabel,
                    collectionID: collection.id,
                    skippedCount: duplicates.count,
                    alreadyOnDriveURLs: duplicates
                )
                uploader.start(lot: lot, token: token, driveId: driveId)

                while uploader.isUploading || !uploader.finished {
                    if Task.isCancelled {
                        uploader.cancel()
                        while uploader.isUploading {
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        return (uploaded, 0, failed, true)
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }

                if Task.isCancelled || uploader.wasCancelled {
                    return (uploader.successCount, 0, uploader.failedCount, true)
                }
                uploaded = uploader.successCount
                failed = uploader.failedCount
                confirmedOnDrive.append(contentsOf: uploader.uploadedFileURLs)
                if failed == 0 {
                    KDriveFreshnessCenter.shared.markUploaded(
                        collectionLabel: collection.id,
                        remoteFileCount: remoteNames.count + uploaded
                    )
                }
            } else if !duplicates.isEmpty {
                KDriveFreshnessCenter.shared.markUploaded(
                    collectionLabel: collection.id,
                    remoteFileCount: remoteNames.count
                )
            }

            if failed == 0 {
                self.progressLabel = L("Suppression : \(collection.displayName)",
                                       "Deleting: \(collection.displayName)")
                if model.collections.contains(where: { $0.id == collection.id }) {
                    model.deleteDownloads(for: collection.id)
                } else {
                    let urlsToDelete = confirmedOnDrive
                    await Task.detached(priority: .userInitiated) {
                        let fm = FileManager.default
                        for url in urlsToDelete where fm.fileExists(atPath: url.path) {
                            try? fm.removeItem(at: url)
                            MediaMetadata.remove(for: url)
                        }
                    }.value
                }
                NotificationCenter.default.post(name: .rmpFilesDeletedLocally, object: nil)
                return (uploaded, localURLs.count, 0, false)
            }

            var deleted = 0
            if !confirmedOnDrive.isEmpty {
                self.progressLabel = L("Nettoyage partiel : \(collection.displayName)",
                                       "Partial cleanup: \(collection.displayName)")
                let urlsToDelete = confirmedOnDrive
                deleted = await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    var count = 0
                    for url in urlsToDelete where fm.fileExists(atPath: url.path) {
                        do {
                            try fm.removeItem(at: url)
                            MediaMetadata.remove(for: url)
                            count += 1
                        } catch {
                            LogCenter.err(L("kDrive : suppression impossible de \(url.lastPathComponent) : \(error.localizedDescription)",
                                            "kDrive: could not delete \(url.lastPathComponent): \(error.localizedDescription)"))
                        }
                    }
                    return count
                }.value
                if deleted > 0 {
                    NotificationCenter.default.post(name: .rmpFilesDeletedLocally, object: nil)
                }
            }
            return (uploaded, deleted, failed, false)
        } catch is CancellationError {
            return (0, 0, 0, true)
        } catch {
            LogCenter.err(L("kDrive (lot) : erreur sur \(collection.displayName) : \(error.localizedDescription)",
                            "kDrive (batch): error on \(collection.displayName): \(error.localizedDescription)"))
            return (0, 0, 1, false)
        }
    }
}

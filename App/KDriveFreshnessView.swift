import Foundation
import MediaCore
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

    /// État de fraîcheur par identifiant canonique de collection (`u/pseudo`, `tw/pseudo`, etc.).
    private(set) var statuses: [String: KDriveFreshnessStatus] = [:]
    /// Horodatage de dernière vérification par identifiant canonique.
    private(set) var checkedDates: [String: Date] = [:]
    /// Index des sous-dossiers présents dans le répertoire kDrive cible (clé = nom normalisé).
    private(set) var remoteFolders: [String: KDriveFolderItem] = [:]
    private(set) var isCheckingAll = false
    private(set) var checkedCount = 0
    private(set) var totalToCheck = 0
    private(set) var lastGlobalError: String?

    private var checkAllTask: Task<Void, Never>?
    private var singleTasks: [String: Task<Void, Never>] = [:]

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
        let canonical = Self.canonicalID(collectionID)
        if let exact = statuses[canonical] { return exact }
        let lower = canonical.lowercased()
        return statuses.first { $0.key.lowercased() == lower }?.value
    }

    func remoteFolder(for collectionID: String) -> KDriveFolderItem? {
        for candidate in KDriveFreshness.candidateFolderNames(for: collectionID) {
            let key = FilenamePolicy.kDriveNormalizedName(candidate)
            if let folder = remoteFolders[key] {
                return folder
            }
        }
        return nil
    }

    /// Marque une collection comme fraîchement envoyée sur kDrive après un upload réussi.
    func markUploaded(collectionLabel: String, remoteFileCount: Int) {
        let canonical = Self.canonicalID(collectionLabel)
        statuses[canonical] = .upToDate(remoteCount: remoteFileCount, checkedSourceCount: 0)
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

        let sortedRemote = remoteFolders.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for folder in sortedRemote {
            if let source = KDriveFreshness.inferredSource(fromFolderName: folder.name) {
                append(UserCollection(source: source))
            }
        }

        return result
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
        var index: [String: KDriveFolderItem] = [:]
        for item in existing {
            let key = FilenamePolicy.kDriveNormalizedName(item.name)
            if index[key] == nil {
                index[key] = item
            }
        }
        remoteFolders = index
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
        statuses[canonical] = .checking
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
            statuses[canonical] = evaluation
            checkedDates[canonical] = Date()
            LogCenter.kdrive(L("kDrive : vérification de \(collection.displayName) — \(evaluation.summaryText).",
                               "kDrive: checked \(collection.displayName) — \(evaluation.summaryText)."))
        } catch is CancellationError {
            if statuses[canonical]?.isChecking == true {
                statuses.removeValue(forKey: canonical)
            }
        } catch {
            let message = error.localizedDescription
            statuses[canonical] = .unavailable(reason: message)
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
            statuses.removeValue(forKey: key)
        }
    }

    // MARK: - Compteurs synthétiques

    var upToDateCount: Int {
        statuses.values.filter(\.isUpToDate).count
    }

    var outdatedCount: Int {
        statuses.values.filter {
            if case .outdated = $0 { return true }
            return false
        }.count
    }

    var pendingUploadCount: Int {
        statuses.values.filter {
            if case .pendingUpload = $0 { return true }
            return false
        }.count
    }

    var notOnDriveCount: Int {
        statuses.values.filter {
            if case .notOnDrive = $0 { return true }
            return false
        }.count
    }

    var unavailableCount: Int {
        statuses.values.filter {
            if case .unavailable = $0 { return true }
            return false
        }.count
    }

    /// Compteur Orange (collections avec nouveautés sur la source ou fichiers locaux à envoyer).
    var orangeCount: Int {
        outdatedCount + pendingUploadCount
    }

    /// Compteur Rouge (collections absentes de kDrive ou en erreur de vérification).
    var redCount: Int {
        notOnDriveCount + unavailableCount
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
        if redCount > 0 {
            return L("\(upToDateCount) à jour · \(orangeCount) en retard · \(redCount) absent/err.",
                     "\(upToDateCount) up to date · \(orangeCount) behind · \(redCount) missing/err.")
        }
        if orangeCount > 0 {
            return L("\(orangeCount) en retard · \(upToDateCount) à jour",
                     "\(orangeCount) behind · \(upToDateCount) up to date")
        }
        return L("\(upToDateCount) à jour sur kDrive",
                 "\(upToDateCount) up to date on kDrive")
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
    @State private var uploader = KDriveContinuousUploadController.shared
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

    private var allCollections: [UserCollection] {
        center.allCheckableCollections(model: model)
    }

    /// Collections à télécharger en lot : uniquement celles déjà présentes sur
    /// kDrive, dans la liste filtrée, qui ne sont ni déjà à jour ni uniquement
    /// en attente d'envoi local.
    private var downloadableCollections: [UserCollection] {
        filteredCollections.filter { collection in
            guard center.remoteFolder(for: collection.id) != nil else { return false }
            switch center.status(for: collection.id) {
            case .upToDate, .pendingUpload, .notOnDrive:
                return false
            default:
                return true
            }
        }
    }

    private var localCollections: [UserCollection] {
        model.collections
    }

    private var selectedCollections: [UserCollection] {
        allCollections.filter { selectedIds.contains($0.id) }
    }

    private var targetDownloadCollections: [UserCollection] {
        selectedCollections.isEmpty ? downloadableCollections : selectedCollections
    }

    private var allFilteredSelected: Bool {
        !filteredCollections.isEmpty && filteredCollections.allSatisfy { selectedIds.contains($0.id) }
    }

    private func toggleSelection(for id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private var filteredCollections: [UserCollection] {
        allCollections.filter { collection in
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
        NavigationStack {
            Group {
                if !kDriveConfigured {
                    ContentUnavailableView {
                        Label(L("kDrive non configuré", "kDrive not configured"), systemImage: "icloud.slash")
                    } description: {
                        Text(L("Configure le token API et l’ID du Drive dans Réglages > Infomaniak kDrive pour comparer tes collections au site source.",
                               "Configure the API token and Drive ID in Settings > Infomaniak kDrive to compare your collections with the source site."))
                    }
                } else {
                    List {
                        Section {
                            summaryHeader
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

                        if filteredCollections.isEmpty {
                            Section {
                                Text(L("Aucune collection dans cette catégorie.", "No collection in this category."))
                                    .font(.footnote)
                                    .foregroundStyle(DS.onSurfaceMuted)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, DS.space(4))
                            }
                        } else {
                            Section {
                                ForEach(filteredCollections, id: \.id) { collection in
                                    collectionRow(collection)
                                }
                            } header: {
                                HStack(spacing: DS.space(2)) {
                                    if !selectedCollections.isEmpty {
                                        Text(L("\(selectedCollections.count) sélectionnée(s)", "\(selectedCollections.count) selected"))
                                            .foregroundStyle(DS.accentEmphasis)
                                    } else {
                                        Text(L("\(filteredCollections.count) collection(s)", "\(filteredCollections.count) collection(s)"))
                                    }
                                    Spacer(minLength: 4)
                                    if !allFilteredSelected {
                                        Button(selectedCollections.isEmpty
                                            ? L("Tout sélectionner", "Select all")
                                            : L("Tout", "All")) {
                                            for item in filteredCollections {
                                                selectedIds.insert(item.id)
                                            }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .textCase(nil)
                                        .disabled(batch.isRunning)
                                    }
                                    if !selectedCollections.isEmpty {
                                        Button(L("Effacer", "Clear")) {
                                            selectedIds.removeAll()
                                        }
                                        .font(.caption.weight(.semibold))
                                        .textCase(nil)
                                        .foregroundStyle(DS.onSurfaceMuted)
                                        .disabled(batch.isRunning)
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
                if kDriveConfigured {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if center.isCheckingAll {
                                center.stopChecking()
                            } else {
                                center.checkAll(
                                    model: model,
                                    token: token,
                                    driveId: driveId,
                                    directoryId: directoryId
                                )
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
                        .disabled(allCollections.isEmpty && !center.isCheckingAll)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("OK", "OK")) { dismiss() }
                }
            }
            .task {
                if kDriveConfigured, center.remoteFolders.isEmpty {
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
            selectedCollections.isEmpty
                ? L("Télécharger, envoyer sur kDrive et nettoyer ?", "Download, upload to kDrive and clean up?")
                : L("Télécharger, envoyer et nettoyer (\(selectedCollections.count)) ?", "Download, upload and clean up (\(selectedCollections.count))?"),
            isPresented: $confirmDownloadSync,
            titleVisibility: .visible
        ) {
            Button(L("Lancer", "Start"), role: .destructive) {
                let targets = targetDownloadCollections
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
            if selectedCollections.isEmpty {
                Text(L("Pour chaque collection déjà présente sur kDrive, seuls les médias manquants seront téléchargés, envoyés sur kDrive puis supprimés de l'app (médias et collection) avant de passer à la suivante.",
                       "For each collection already on kDrive, only missing media will be downloaded, uploaded to kDrive, then removed from the app (media and collection) before moving to the next."))
            } else {
                Text(L("Pour chacune des \(selectedCollections.count) collection(s) sélectionnée(s), seuls les médias manquants seront téléchargés, envoyés sur kDrive puis supprimés automatiquement de l'app (médias et collection) avant de passer à la suivante.",
                       "For each of the \(selectedCollections.count) selected collection(s), only missing media will be downloaded, uploaded to kDrive, then automatically removed from the app (media and collection) before moving to the next."))
            }
        }
        .confirmationDialog(
            L("Tout envoyer sur kDrive et supprimer ?", "Upload all to kDrive and delete?"),
            isPresented: $confirmUploadAndDelete,
            titleVisibility: .visible
        ) {
            Button(L("Envoyer et supprimer", "Upload & delete"), role: .destructive) {
                batch.startUploadAllAndDelete(
                    collections: localCollections,
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

    /// Fine jauge de répartition 3 pt (Sauge / Ambre / Rose-Corail) placée
    /// sous les 3 compteurs de la console (« Apple Calm Tech »).
    private var calmTricolorGauge: some View {
        let up = max(0, center.upToDateCount)
        let orange = max(0, center.orangeCount)
        let red = max(0, center.redCount)
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

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: DS.space(3)) {
            HStack(spacing: 0) {
                consoleMetric(
                    count: center.upToDateCount,
                    label: L("à jour", "up to date"),
                    valueColor: DS.onSurface,
                    leadingSymbol: "checkmark",
                    symbolColor: DS.calmSage
                )
                metricDivider
                consoleMetric(
                    count: center.orangeCount,
                    label: L("en retard", "behind"),
                    valueColor: DS.calmAmber
                )
                metricDivider
                consoleMetric(
                    count: center.redCount,
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
                calmTricolorGauge
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

    private var batchActionBar: some View {
        let targets = targetDownloadCollections
        let hasSelection = !selectedCollections.isEmpty
        let downloadRunning = batch.mode == .downloadAll && batch.isRunning
        let uploadRunning = batch.mode == .uploadAndDelete && batch.isRunning
        let canStartDownload = !targets.isEmpty && !model.running && !batch.isRunning && !uploader.isUploading
        let canStartUpload = !localCollections.isEmpty && !model.running && !batch.isRunning && !uploader.isUploading

        return HStack(spacing: DS.space(2)) {
            Button {
                if downloadRunning {
                    batch.stop(model: model)
                } else {
                    confirmDownloadSync = true
                }
            } label: {
                HStack(spacing: DS.space(1)) {
                    Image(systemName: downloadRunning ? "stop.fill" : "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(downloadRunning
                        ? L("Arrêter", "Stop")
                        : (hasSelection
                            ? L("Télécharger (\(targets.count))", "Download (\(targets.count))")
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
                    ? L("Télécharger, envoyer et nettoyer la sélection (\(targets.count) collections)", "Download, upload and clean up selection (\(targets.count) collections)")
                    : L("Tout télécharger (\(targets.count) collections)", "Download all (\(targets.count) collections)")))

            Button {
                if uploadRunning {
                    batch.stop(model: model)
                } else {
                    confirmUploadAndDelete = true
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

    @ViewBuilder
    private func calmLeadingTile(status: KDriveFreshnessStatus?, folder: KDriveFolderItem?) -> some View {
        let isCalmUpToDate = (status?.isUpToDate == true) || (status == nil && folder != nil)
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
        } else if !center.remoteFolders.isEmpty, status == nil {
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

    private func rowDetailColor(status: KDriveFreshnessStatus?, folder: KDriveFolderItem?) -> Color {
        if let status { return status.tintColor }
        if folder != nil { return DS.calmSage }
        if !center.remoteFolders.isEmpty { return DS.calmRose }
        return DS.onSurfaceMuted
    }

    @ViewBuilder
    private func collectionRow(_ collection: UserCollection) -> some View {
        let status = center.status(for: collection.id)
        let folder = center.remoteFolder(for: collection.id)
        let expectedFolderName = folder?.name ?? FilenamePolicy.kDriveFolderName(collection.kDriveLabel)
        let detailColor = rowDetailColor(status: status, folder: folder)
        let isCalmUpToDate = (status?.isUpToDate == true) || (status == nil && folder != nil)
        let isSelected = selectedIds.contains(collection.id)

        HStack(spacing: DS.space(2)) {
            Button {
                toggleSelection(for: collection.id)
            } label: {
                HStack(spacing: DS.space(3)) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? DS.accent : DS.onSurfaceMuted.opacity(0.45))
                        .accessibilityHidden(true)

                    calmLeadingTile(status: status, folder: folder)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCalmUpToDate ? DS.onSurface.opacity(0.84) : DS.onSurface)
                            .lineLimit(1)

                        if let status {
                            KDriveBicolorDetail(status: status, font: .caption)
                        } else if let folder {
                            let ts = folder.lastModifiedAt ?? folder.updatedAt ?? 0
                            if ts > 0 {
                                let date = Date(timeIntervalSince1970: TimeInterval(ts))
                                Text(L("Sur kDrive · \(date.formatted(date: .abbreviated, time: .omitted))",
                                       "On kDrive · \(date.formatted(date: .abbreviated, time: .omitted))"))
                                    .font(.caption)
                                    .foregroundStyle(DS.onSurfaceMuted)
                                    .lineLimit(1)
                            } else {
                                Text(L("Sur kDrive · \(expectedFolderName)",
                                       "On kDrive · \(expectedFolderName)"))
                                    .font(.caption)
                                    .foregroundStyle(DS.onSurfaceMuted)
                                    .lineLimit(1)
                            }
                        } else if !center.remoteFolders.isEmpty {
                            HStack(spacing: 0) {
                                Text(L("Absent de kDrive", "Not on kDrive"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(DS.calmRose)
                                Text(" · \(expectedFolderName)")
                                    .font(.caption)
                                    .foregroundStyle(DS.onSurfaceMuted)
                            }
                            .lineLimit(1)
                        } else {
                            Text(L("Non vérifié · \(expectedFolderName)", "Not checked · \(expectedFolderName)"))
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
            .disabled(batch.isRunning)
            .accessibilityLabel(collection.displayName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(isSelected
                ? L("Appuyer pour désélectionner", "Tap to deselect")
                : L("Appuyer pour sélectionner pour téléchargement, envoi kDrive et nettoyage",
                    "Tap to select for download, kDrive upload and cleanup"))

            if let onDownloadCollection, shouldOfferDownload(for: status) {
                Button {
                    dismiss()
                    onDownloadCollection(collection)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.body)
                        .foregroundStyle(detailColor)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(model.running)
                .accessibilityLabel(L("Télécharger les nouveautés de \(collection.displayName)",
                                      "Download new media from \(collection.displayName)"))
            }

            Button {
                center.startSingleCheck(
                    collection: collection,
                    model: model,
                    token: token,
                    driveId: driveId,
                    directoryId: directoryId
                )
            } label: {
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

    private func shouldOfferDownload(for status: KDriveFreshnessStatus?) -> Bool {
        if case .outdated = status {
            return true
        }
        return false
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

    private var batchTask: Task<Void, Never>?

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

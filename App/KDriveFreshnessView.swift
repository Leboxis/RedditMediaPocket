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
final class KDriveFreshnessCenter: ObservableObject {
    static let shared = KDriveFreshnessCenter()

    /// État de fraîcheur par identifiant canonique de collection (`u/pseudo`, `tw/pseudo`, etc.).
    @Published private(set) var statuses: [String: KDriveFreshnessStatus] = [:]
    /// Horodatage de dernière vérification par identifiant canonique.
    @Published private(set) var checkedDates: [String: Date] = [:]
    /// Index des sous-dossiers présents dans le répertoire kDrive cible (clé = nom normalisé).
    @Published private(set) var remoteFolders: [String: KDriveFolderItem] = [:]
    @Published private(set) var isCheckingAll = false
    @Published private(set) var checkedCount = 0
    @Published private(set) var totalToCheck = 0
    @Published private(set) var lastGlobalError: String?

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

/// Carte compacte « Apple Calm Tech » affichée sous les pastilles de la Bibliothèque :
/// coche Vert Sauge + texte gris apaisé + compteur monospaced à droite quand tout est à jour,
/// ou point Ambre / Rose-Corail + détail bicolore en cas d'écart.
struct KDriveActiveCollectionStrip: View {
    let collection: UserCollection
    @ObservedObject var model: Downloader
    let onDownloadCollection: (UserCollection) -> Void
    let onOpenDashboard: () -> Void

    @ObservedObject private var center = KDriveFreshnessCenter.shared
    @AppStorage("kDriveApiToken") private var token = ""
    @AppStorage("kDriveId") private var driveId = ""
    @AppStorage("kDriveDirectoryId") private var directoryId = "1"

    private var status: KDriveFreshnessStatus? {
        center.status(for: collection.id)
    }

    var body: some View {
        HStack(spacing: DS.space(2)) {
            if let status {
                if status.isChecking {
                    ProgressView()
                        .controlSize(.mini)
                } else if status.isUpToDate {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DS.calmSage)
                } else {
                    Circle()
                        .fill(status.tintColor)
                        .frame(width: 6, height: 6)
                }
            } else {
                Image(systemName: "icloud")
                    .font(.caption)
                    .foregroundStyle(DS.onSurfaceMuted)
            }

            Button {
                onOpenDashboard()
            } label: {
                HStack {
                    if case .upToDate(let remoteCount, _) = status {
                        Text(L("kDrive synchronisé avec la source", "kDrive synced with source"))
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(L("\(remoteCount) fichiers", "\(remoteCount) files"))
                            .font(DS.monoCaption)
                            .foregroundStyle(DS.onSurfaceMuted)
                            .lineLimit(1)
                    } else if let status {
                        KDriveBicolorDetail(status: status, font: .caption)
                        Spacer(minLength: 4)
                    } else {
                        Text(L("kDrive : toucher pour vérifier avec la source",
                               "kDrive: tap to check against source"))
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if case .outdated = status {
                Button {
                    onDownloadCollection(collection)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline)
                        .foregroundStyle(DS.calmAmber)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(DS.onSurfaceMuted)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(status?.isChecking == true)
            .accessibilityLabel(L("Vérifier \(collection.displayName) sur kDrive et le site source",
                                  "Check \(collection.displayName) on kDrive and source site"))
        }
        .padding(.horizontal, DS.space(3))
        .padding(.vertical, DS.space(2))
        .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusM))
        .padding(.horizontal, DS.space(4))
        .padding(.bottom, DS.space(2))
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
    @ObservedObject var model: Downloader
    var onDownloadCollection: ((UserCollection) -> Void)? = nil

    @ObservedObject private var center = KDriveFreshnessCenter.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kDriveApiToken") private var token = ""
    @AppStorage("kDriveId") private var driveId = ""
    @AppStorage("kDriveDirectoryId") private var directoryId = "1"
    @AppStorage("kDriveDirectoryName") private var directoryName = ""
    @State private var filter: KDriveFreshnessFilter = .all

    private var kDriveConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var allCollections: [UserCollection] {
        center.allCheckableCollections(model: model)
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
                                Text(L("\(filteredCollections.count) collection(s)", "\(filteredCollections.count) collection(s)"))
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
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
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
        }
        .padding(DS.space(3))
        .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusM))
        .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
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

        HStack(spacing: DS.space(3)) {
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
        switch status {
        case .outdated, .notOnDrive:
            return true
        default:
            return false
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

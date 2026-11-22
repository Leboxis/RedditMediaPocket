import Foundation
import MediaCore
import SwiftUI

extension KDriveFreshnessStatus {
    /// Couleur sémantique du Design System associée à l'état de fraîcheur.
    var tintColor: Color {
        switch self {
        case .checking:
            return DS.accentEmphasis
        case .upToDate:
            return DS.success
        case .pendingUpload:
            return DS.accentEmphasis
        case .outdated:
            return DS.warning
        case .notOnDrive:
            return DS.onSurfaceMuted
        case .unavailable:
            return DS.error
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

    /// Résumé court pour la ligne de l'onglet Activité ou l'en-tête.
    var summaryLine: String {
        if isCheckingAll {
            return L("Vérification \(checkedCount)/\(max(1, totalToCheck))…",
                     "Checking \(checkedCount)/\(max(1, totalToCheck))…")
        }
        guard !statuses.isEmpty else {
            return L("Non vérifié", "Not checked")
        }
        if outdatedCount > 0 {
            return L("\(outdatedCount) à mettre à jour · \(upToDateCount) à jour",
                     "\(outdatedCount) outdated · \(upToDateCount) up to date")
        }
        if pendingUploadCount > 0 {
            return L("\(pendingUploadCount) à envoyer · \(upToDateCount) à jour",
                     "\(pendingUploadCount) to upload · \(upToDateCount) up to date")
        }
        return L("\(upToDateCount) à jour sur kDrive",
                 "\(upToDateCount) up to date on kDrive")
    }
}

/// Pastille compacte d'indicateur de fraîcheur kDrive vs site source.
struct KDriveFreshnessBadge: View {
    let status: KDriveFreshnessStatus
    var onAccentBackground = false

    var body: some View {
        let color = onAccentBackground ? DS.onAccent : status.tintColor
        HStack(spacing: 4) {
            if status.isChecking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Image(systemName: status.symbolName)
                    .font(.caption2.weight(.semibold))
            }
            Text(status.badgeText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            (onAccentBackground ? DS.onAccent : status.tintColor).opacity(0.14),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.summaryText)
    }
}

/// Bandeau compact affiché sous les pastilles de la Bibliothèque pour indiquer
/// si la collection active est à jour sur kDrive par rapport au site source,
/// avec vérification en un geste et accès au tableau de bord complet.
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
            Group {
                if let status {
                    if status.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: status.symbolName)
                            .foregroundStyle(status.tintColor)
                    }
                } else {
                    Image(systemName: "icloud.badge.magnifyingglass")
                        .foregroundStyle(DS.accentEmphasis)
                }
            }
            .font(.subheadline.weight(.semibold))

            Button {
                onOpenDashboard()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(status?.summaryText ?? L("kDrive : toucher pour vérifier si la collection est à jour avec la source",
                                                  "kDrive: tap to check if collection is up to date with source"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status?.tintColor ?? DS.onSurface)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if case .outdated = status {
                Button {
                    onDownloadCollection(collection)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.body)
                        .foregroundStyle(DS.warning)
                        .frame(width: 34, height: 34)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.accentEmphasis)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(status?.isChecking == true)
            .accessibilityLabel(L("Vérifier \(collection.displayName) sur kDrive et le site source",
                                  "Check \(collection.displayName) on kDrive and source site"))

            Button {
                onOpenDashboard()
            } label: {
                Image(systemName: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.onSurfaceMuted)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("État kDrive de toutes les collections",
                                  "kDrive status of all collections"))
        }
        .padding(.horizontal, DS.space(3))
        .padding(.vertical, DS.space(1))
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusM))
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
                if case .notOnDrive = status { return true }
                return status == nil && center.remoteFolder(for: collection.id) == nil
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
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Fermer", "Close")) { dismiss() }
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

    private var summaryHeader: some View {
        let stats: [(label: String, value: String)] = [
            (L("À jour", "Up to date"), "\(center.upToDateCount)"),
            (L("Nouveaux source", "New on source"), "\(center.outdatedCount)"),
            (L("À envoyer", "Pending upload"), "\(center.pendingUploadCount)"),
            (L("Hors kDrive", "Not on kDrive"), "\(center.notOnDriveCount)")
        ]
        let progress: Double? = center.isCheckingAll && center.totalToCheck > 0
            ? Double(center.checkedCount) / Double(max(1, center.totalToCheck))
            : nil
        let counter: String? = center.isCheckingAll
            ? "\(center.checkedCount) / \(max(1, center.totalToCheck))"
            : nil
        let folderTitle = directoryName.isEmpty
            ? L("Racine kDrive", "kDrive Root")
            : directoryName

        return VStack(spacing: DS.space(3)) {
            UploadConsoleCard(
                icon: center.outdatedCount > 0
                    ? "exclamationmark.icloud.fill"
                    : (center.upToDateCount > 0 ? "checkmark.icloud.fill" : "icloud.fill"),
                iconColor: center.outdatedCount > 0
                    ? DS.warning
                    : (center.upToDateCount > 0 ? DS.success : DS.accentEmphasis),
                title: L("Collections kDrive vs sites sources", "kDrive collections vs source sites"),
                status: L("Dossier cible : \(folderTitle) · \(center.summaryLine)",
                          "Target folder: \(folderTitle) · \(center.summaryLine)"),
                counter: counter,
                progress: progress,
                stats: stats,
                summary: center.lastGlobalError
            )

            if center.isCheckingAll {
                UploadActionButton(
                    title: L("Arrêter la vérification", "Stop checking"),
                    systemImage: "stop.fill",
                    destructive: true
                ) {
                    center.stopChecking()
                }
            } else {
                UploadActionButton(
                    title: L("Vérifier toutes les collections", "Check all collections"),
                    systemImage: "icloud.badge.magnifyingglass",
                    prominent: true
                ) {
                    center.checkAll(
                        model: model,
                        token: token,
                        driveId: driveId,
                        directoryId: directoryId
                    )
                }
                .disabled(allCollections.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: UserCollection) -> some View {
        let status = center.status(for: collection.id)
        let folder = center.remoteFolder(for: collection.id)
        let expectedFolderName = folder?.name ?? FilenamePolicy.kDriveFolderName(collection.kDriveLabel)

        HStack(spacing: DS.space(3)) {
            Image(systemName: collection.icon)
                .font(.title3)
                .foregroundStyle(DS.accentEmphasis)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.space(2)) {
                    Text(collection.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.onSurface)
                        .lineLimit(1)
                    if let status {
                        KDriveFreshnessBadge(status: status)
                    }
                }

                Text(L("Dossier kDrive : \(expectedFolderName)", "kDrive folder: \(expectedFolderName)"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(DS.onSurfaceMuted)
                    .lineLimit(1)

                if let status {
                    Text(status.summaryText)
                        .font(.caption)
                        .foregroundStyle(status.tintColor)
                        .lineLimit(2)
                } else if let folder {
                    let ts = folder.lastModifiedAt ?? folder.updatedAt ?? 0
                    if ts > 0 {
                        let date = Date(timeIntervalSince1970: TimeInterval(ts))
                        Text(L("Présent sur kDrive (modifié le \(date.formatted(date: .abbreviated, time: .shortened)))",
                               "Present on kDrive (modified \(date.formatted(date: .abbreviated, time: .shortened)))"))
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                    } else {
                        Text(L("Présent sur kDrive — non comparé à la source",
                               "Present on kDrive — not yet compared with source"))
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                    }
                } else {
                    Text(L("Non vérifié", "Not checked"))
                        .font(.caption)
                        .foregroundStyle(DS.onSurfaceMuted)
                }
            }

            Spacer(minLength: 4)

            if let onDownloadCollection, shouldOfferDownload(for: status) {
                Button {
                    dismiss()
                    onDownloadCollection(collection)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.warning)
                        .frame(width: 40, height: 40)
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
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title3)
                        .foregroundStyle(DS.accentEmphasis)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.borderless)
            .disabled(status?.isChecking == true)
            .accessibilityLabel(L("Vérifier \(collection.displayName)", "Check \(collection.displayName)"))
        }
        .padding(.vertical, 2)
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

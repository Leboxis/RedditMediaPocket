import Foundation
import CryptoKit
import MediaCore
import SwiftUI

/// Action « Envoyer vers kDrive » : elle apparaît à plat dans le menu « … »
/// de la barre de navigation, sans sous-menu imbriqué.
struct KDriveCollectionUploadAction: View {
    let files: [URL]
    let collectionLabel: String
    let collectionID: String?

    @AppStorage("kDriveApiToken") private var token = ""
    @AppStorage("kDriveId") private var driveId = ""
    @State private var showUpload = false
    @State private var showNotConfigured = false

    private var configured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button {
            if configured {
                showUpload = true
            } else {
                showNotConfigured = true
            }
        } label: {
            Label(L("Envoyer vers kDrive", "Upload to kDrive"), systemImage: "icloud.and.arrow.up")
        }
        .disabled(files.isEmpty)
        .accessibilityLabel(L("Envoyer les médias affichés vers kDrive", "Upload displayed media to kDrive"))
        .sheet(isPresented: $showUpload) {
            KDriveCollectionUploadFlow(
                files: files,
                token: token,
                driveId: driveId,
                collectionLabel: collectionLabel,
                collectionID: collectionID
            )
        }
        .alert(L("kDrive non configuré", "kDrive is not configured"), isPresented: $showNotConfigured) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(L("Renseigne le token API et l’ID du Drive dans Réglages > Infomaniak kDrive.", "Enter the API token and Drive ID in Settings > Infomaniak kDrive."))
        }
    }
}

private struct KDriveCollectionUploadFlow: View {
    let files: [URL]
    let token: String
    let driveId: String
    let collectionLabel: String
    let collectionID: String?

    @AppStorage("kDriveDirectoryId") private var configuredDirectoryId = "1"
    @AppStorage("kDriveDirectoryName") private var configuredDirectoryName = ""

    @Environment(\.dismiss) private var dismiss
    @State private var uploadDirectoryId: String?
    @State private var uploadDirectoryName = ""
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var activeLot: KDriveUploadLot?
    @State private var skippedCount = 0
    @State private var skippedExistingURLs: [URL] = []
    @State private var prepareTask: Task<Void, Never>?

    /// Dossier parent : celui choisi dans Réglages > Infomaniak kDrive.
    private var parentDirectoryId: String {
        let cleaned = configuredDirectoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "1" : cleaned
    }

    private var targetFolderName: String {
        // Dossier kDrive = juste le pseudo/sub, première lettre en majuscule
        // (ex. `leboxis` → `Leboxis`). Assaini pour l'API kDrive.
        FilenamePolicy.kDriveFolderName(collectionLabel)
    }

    var body: some View {
        Group {
            if let uploadDirectoryId, let activeLot {
                KDriveContinuousUploadSheet(
                    lot: activeLot,
                    token: token,
                    driveId: driveId
                )
            } else if isPreparing {
                NavigationStack {
                    VStack(spacing: 18) {
                        Spacer()
                        ProgressView()
                            .controlSize(.large)
                        Text(L("Préparation du dossier…", "Preparing folder…"))
                            .font(.headline)
                        Text(targetFolderName)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(DS.onSurfaceMuted)
                        Text(L("Analyse des médias déjà présents…", "Scanning media already present…"))
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .navigationTitle("Infomaniak kDrive")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("Annuler", "Cancel")) {
                                prepareTask?.cancel()
                                prepareTask = nil
                                isPreparing = false
                                dismiss()
                            }
                        }
                    }
                }
            } else if let errorMessage {
                NavigationStack {
                    VStack(spacing: DS.space(4)) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(DS.error)
                        Text(errorMessage)
                            .font(DS.body)
                            .foregroundStyle(DS.onSurfaceMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, DS.space(6))
                        Spacer()
                        Button(L("Réessayer", "Retry")) {
                            prepareCollectionFolder()
                        }
                        .buttonStyle(DSPrimaryButtonStyle())
                        .padding(.horizontal, DS.space(4))
                        Button(L("Annuler", "Cancel")) { dismiss() }
                            .tint(DS.accentEmphasis)
                            .padding(.bottom)
                    }
                    .navigationTitle("Infomaniak kDrive")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                // Le dossier parent vient des Réglages : on prépare directement
                // le sous-dossier de la collection, sans choix à chaque upload.
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .errorAlert(errorMessage)
        .task {
            prepareCollectionFolder()
        }
        .onDisappear {
            prepareTask?.cancel()
            prepareTask = nil
        }
    }

    private func prepareCollectionFolder() {
        guard uploadDirectoryId == nil, activeLot == nil, !isPreparing else { return }
        guard !KDriveContinuousUploadController.shared.isUploading else {
            errorMessage = L("Un envoi kDrive est déjà en cours. Consulte la barre d'état ou attends sa fin.", "A kDrive upload is already in progress. Check the status banner or wait for it to finish.")
            return
        }
        isPreparing = true
        errorMessage = nil

        let parentId = parentDirectoryId
        prepareTask?.cancel()
        prepareTask = Task { @MainActor in
            defer { prepareTask = nil }
            do {
                LogCenter.kdrive(L("kDrive : préparation du dossier « \(targetFolderName) » (parent \(parentId)).", "kDrive: preparing folder “\(targetFolderName)” (parent \(parentId))."))
                let service = KDriveService.shared
                let existing = try await service.fetchSubdirectories(
                    token: token,
                    driveId: driveId,
                    directoryId: parentId
                )

                let folder: KDriveFolderItem
                if let match = existing.first(where: {
                    $0.name.compare(targetFolderName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) {
                    folder = match
                } else {
                    do {
                        folder = try await service.createDirectory(
                            token: token,
                            driveId: driveId,
                            parentDirectoryId: parentId,
                            folderName: targetFolderName
                        )
                    } catch {
                        if error is CancellationError { throw error }
                        // Si deux créations se croisent, on relit les dossiers et on
                        // réutilise celui qui vient d'être créé plutôt que d'échouer.
                        let refreshed = try await service.fetchSubdirectories(
                            token: token,
                            driveId: driveId,
                            directoryId: parentId
                        )
                        if let match = refreshed.first(where: {
                            $0.name.compare(targetFolderName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                        }) {
                            folder = match
                        } else {
                            throw error
                        }
                    }
                }

                try Task.checkCancellation()
                uploadDirectoryId = String(folder.id)
                uploadDirectoryName = folder.name

                // Déduplication par nom : on ne ré-uploade jamais un média
                // déjà présent (nom assaini ou repli 422 déterministe).
                let remoteNames = try await service.fetchFileNames(
                    token: token,
                    driveId: driveId,
                    directoryId: String(folder.id)
                )
                try Task.checkCancellation()
                let filesSnapshot = files
                let (filtered, matchedDuplicates) = await Task.detached(priority: .utility) {
                    let normalizedRemote = Set(remoteNames.map { FilenamePolicy.kDriveNormalizedName($0) })
                    var toUpload: [URL] = []
                    var duplicates: [URL] = []
                    for localURL in filesSnapshot {
                        if Task.isCancelled { break }
                        let candidates = FilenamePolicy.kDriveRemoteCandidateNames(for: localURL.lastPathComponent)
                        let alreadyPresent = candidates.contains {
                            normalizedRemote.contains(FilenamePolicy.kDriveNormalizedName($0))
                        }
                        if alreadyPresent {
                            duplicates.append(localURL)
                        } else {
                            toUpload.append(localURL)
                        }
                    }
                    return (toUpload, duplicates)
                }.value
                try Task.checkCancellation()
                skippedCount = files.count - filtered.count
                LogCenter.kdrive(L("kDrive : \(remoteNames.count) fichier(s) distant(s) analysé(s) — \(skippedCount) ignoré(s), \(filtered.count) à envoyer.", "kDrive: \(remoteNames.count) remote file(s) scanned — \(skippedCount) skipped, \(filtered.count) to upload."))
                if filtered.isEmpty {
                    LogCenter.kdrive(L("kDrive : rien à envoyer, tous les médias sont déjà présents.", "kDrive: nothing to upload, all media already present."))
                }
                skippedExistingURLs = matchedDuplicates
                activeLot = KDriveUploadLot(
                    files: filtered,
                    directoryId: uploadDirectoryId ?? String(folder.id),
                    directoryName: uploadDirectoryName.isEmpty ? folder.name : uploadDirectoryName,
                    collectionLabel: collectionLabel,
                    collectionID: collectionID,
                    skippedCount: skippedCount,
                    alreadyOnDriveURLs: matchedDuplicates
                )
                isPreparing = false
            } catch is CancellationError {
                uploadDirectoryId = nil
                isPreparing = false
            } catch {
                uploadDirectoryId = nil
                isPreparing = false
                errorMessage = error.localizedDescription
                LogCenter.err(L("kDrive : échec de préparation du dossier « \(targetFolderName) » : \(error.localizedDescription)", "kDrive: folder preparation failed for “\(targetFolderName)”: \(error.localizedDescription)"))
            }
        }
    }
}

private struct KDriveContinuousUploadOutcome {
    let fileURL: URL
    let fileName: String
    let succeeded: Bool
    let errorMessage: String?
}

/// Session URLSession dédiée aux envois kDrive : elle rapporte les octets
/// réellement transmis (progression pendant l'envoi d'un fichier, pas
/// seulement à sa fin) — sans elle, la fenêtre reste bloquée à « 0 sur N »
/// tant qu'aucun fichier n'est terminé.
final class KDriveUploadSession: NSObject, URLSessionTaskDelegate {
    static let shared = KDriveUploadSession()

    private let lock = NSLock()
    /// taskIdentifier -> octets envoyés. Les tâches réussies y restent
    /// jusqu'au lot suivant : leurs octets comptent dans la progression.
    private var sent: [Int: Int64] = [:]
    private var totalSentBytes: Int64 = 0

    /// `static let` : initialisation thread-safe, au contraire d'un `lazy var`
    /// accessible depuis plusieurs uploads concurrents. 8 connexions par hôte,
    /// comme Orvian-IOS : l'edge Infomaniak bride une IP qui ouvre trop de
    /// connexions simultanées (FAQ 231), et 8 suffisent avec 4 chunks × 4
    /// fichiers en vol.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = max(
            KDriveUploadPolicy.maxConnectionsPerHost,
            KDriveUploadPolicy.uploadConcurrencyOptions.max() ?? KDriveUploadPolicy.maxConnectionsPerHost
        )
        return URLSession(configuration: configuration, delegate: KDriveUploadSession.shared, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend totalBytesExpected: Int64) {
        lock.lock()
        let previous = sent[task.taskIdentifier] ?? 0
        sent[task.taskIdentifier] = totalBytesSent
        totalSentBytes += totalBytesSent - previous
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        lock.lock()
        if let removed = sent.removeValue(forKey: task.taskIdentifier) {
            totalSentBytes -= removed
        }
        lock.unlock()
    }

    /// Octets transmis du lot en cours (fichiers finis + en cours).
    func sentTotal() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalSentBytes
    }

    /// Nouveau lot : on repart de zéro.
    func reset() {
        lock.lock()
        sent.removeAll()
        totalSentBytes = 0
        lock.unlock()
    }

}

/// Lot d'envoi kDrive prêt à démarrer : fichiers filtrés (sans doublons),
/// dossier cible et médias déjà présents (supprimables localement).
struct KDriveUploadLot {
    let id = UUID()
    let files: [URL]
    let directoryId: String
    let directoryName: String
    /// Collection d'origine (`u/pseudo` pour un compte Reddit suivi).
    let collectionLabel: String
    /// Identifiant de la collection locale, pour la retirer si elle devient vide
    /// après suppression manuelle des médias envoyés.
    let collectionID: String?
    let skippedCount: Int
    let alreadyOnDriveURLs: [URL]
}

@MainActor
@Observable
final class KDriveContinuousUploadController {
    static let shared = KDriveContinuousUploadController()
    static var concurrentLimit: Int { KDriveService.concurrentUploadLimit }

    var isUploading = false
    var completedCount = 0
    var totalCount = 0
    var progress = 0.0
    var lastCompletedFileName = ""
    var uploadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSecond: Double = 0
    var startedCount = 0
    var activeUploadCount: Int { max(startedCount - completedCount, 0) }
    var activeLimit = KDriveContinuousUploadController.concurrentLimit
    private(set) var uploadedFileURLs: [URL] = []
    private(set) var wasCancelled = false
    private(set) var activeLot: KDriveUploadLot?
    private(set) var finished = false
    private(set) var finalError: String?
    private(set) var successCount = 0
    private(set) var failedCount = 0

    private var activeTask: Task<Void, Never>?
    private var uploadGeneration = UUID()

    func start(
        lot: KDriveUploadLot,
        token: String,
        driveId: String
    ) {
        let files = lot.files
        let directoryId = lot.directoryId
        let libelleCollection = lot.collectionLabel
        cancel()
        let generation = UUID()
        uploadGeneration = generation
        wasCancelled = false
        finished = false
        finalError = nil
        activeLot = lot
        KDriveUploadSession.shared.reset()
        LogCenter.kdrive(L("Envoi kDrive démarré : \(files.count) fichiers.", "kDrive upload started: \(files.count) files."))
        isUploading = true
        uploadedFileURLs = []
        completedCount = 0
        startedCount = 0
        totalCount = files.count
        successCount = 0
        failedCount = 0
        progress = 0
        lastCompletedFileName = ""
        uploadedBytes = 0
        speedBytesPerSecond = 0
        totalBytes = 0
        // 4 fichiers en parallèle : avec 4 chunks par fichier
        // et 8 connexions/hôte, on reste sous la limite officielle de 60
        // req/min (pacing global espacé à 58) et sous le seuil de bridage edge.
        activeLimit = Self.concurrentLimit

        activeTask = Task {
            let computedBytes = await Task.detached(priority: .utility) {
                files.reduce(Int64(0)) {
                    $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)?.int64Value ?? 0)
                }
            }.value
            guard self.uploadGeneration == generation, !Task.isCancelled else { return }
            totalBytes = computedBytes

            // Supervision : progression par octets + vitesse. Sans elle, la
            // fenêtre reste bloquée à « 0 sur N » tant qu'aucun fichier
            // n'est terminé.
            let monitor = Task {
                var lastBytes: Int64 = 0
                var lastDate = Date()
                while !Task.isCancelled {
                    guard self.uploadGeneration == generation else { return }
                    let bytes = KDriveUploadSession.shared.sentTotal()
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastDate)
                    if elapsed >= 1 {
                        let instant = Double(bytes - lastBytes) / elapsed
                        speedBytesPerSecond = instant * 0.5 + speedBytesPerSecond * 0.5
                        lastBytes = bytes
                        lastDate = now
                    }
                    uploadedBytes = bytes
                    KDriveRateLimitCenter.shared.refreshPacingInfo()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            defer { monitor.cancel() }
            var success = 0
            var failed = 0
            var completed = 0
            var failedExamples: [KDriveContinuousUploadOutcome] = []

            await withTaskGroup(of: KDriveContinuousUploadOutcome.self) { group in
                var nextIndex = 0
                let initialCount = min(activeLimit, files.count)

                for _ in 0..<initialCount {
                    let fileURL = files[nextIndex]
                    nextIndex += 1
                    startedCount = nextIndex
                    group.addTask {
                        await Self.uploadOutcome(
                            fileURL: fileURL,
                            token: token,
                            driveId: driveId,
                            directoryId: directoryId
                        )
                    }
                }

                while let outcome = await group.next() {
                    if Task.isCancelled || self.uploadGeneration != generation {
                        group.cancelAll()
                        break
                    }

                    completed += 1
                    completedCount = completed
                    lastCompletedFileName = outcome.fileName
                    progress = Double(completed) / Double(max(1, files.count))

                    if outcome.succeeded {
                        success += 1
                        uploadedFileURLs.append(outcome.fileURL)
                    } else {
                        failed += 1
                        LogCenter.err(L("kDrive : échec — \(outcome.fileName) : \(outcome.errorMessage ?? "")", "kDrive: failed — \(outcome.fileName): \(outcome.errorMessage ?? "")"))
                        if failedExamples.count < 5 { failedExamples.append(outcome) }
                    }

                    // File glissante : dès qu’une connexion se libère, le fichier
                    // suivant démarre immédiatement. On n’attend jamais la fin
                    // des trois autres uploads du groupe initial.
                    if nextIndex < files.count && !Task.isCancelled && self.uploadGeneration == generation {
                        let fileURL = files[nextIndex]
                        nextIndex += 1
                        startedCount = nextIndex
                        group.addTask {
                            await Self.uploadOutcome(
                                fileURL: fileURL,
                                token: token,
                                driveId: driveId,
                                directoryId: directoryId
                            )
                        }
                    }
                }
            }

            guard self.uploadGeneration == generation else { return }
            isUploading = false
            activeTask = nil

            let summaryMessage: String? = {
                guard failed > 0 else { return nil }
                let examples = failedExamples.compactMap { o -> String? in
                    guard let msg = o.errorMessage, !msg.isEmpty else { return o.fileName }
                    return "\(o.fileName) : \(msg)"
                }.joined(separator: "\n")
                return L("\(failed) échec(s) sur \(files.count). Exemples :\n\(examples)", "\(failed) failure(s) out of \(files.count). Examples:\n\(examples)")
            }()

            if Task.isCancelled || wasCancelled {
                LogCenter.kdrive(L("Envoi kDrive annulé.", "kDrive upload cancelled."))
            } else {
                if failed > 0 { LogCenter.err(L("Envoi kDrive : \(success) réussis, \(failed) échoués.", "kDrive upload: \(success) ok, \(failed) failed.")) }
                else {
                    LogCenter.kdrive(L("Envoi kDrive terminé : \(success) fichiers.", "kDrive upload done: \(success) files."))
                    if success > 0, let identifiant = SuiviStore.identifiantCollection(libelleCollection) {
                        SuiviStore.noterUpload(pseudo: identifiant.pseudo, plateforme: identifiant.plateforme)
                    }
                    KDriveFreshnessCenter.shared.markUploaded(
                        collectionLabel: libelleCollection,
                        remoteFileCount: lot.skippedCount + success
                    )
                }
                progress = files.isEmpty ? 0 : 1
            }
            finished = true
            finalError = summaryMessage
            successCount = success
            failedCount = failed
        }
    }

    func cancel() {
        uploadGeneration = UUID()
        wasCancelled = true
        activeTask?.cancel()
        activeTask = nil
        isUploading = false
        // État final immédiat : la feuille repasse en « terminé » et les médias
        // déjà uploadés restent supprimables. `start()` remet finished à false.
        successCount = uploadedFileURLs.count
        finished = true
    }

    nonisolated private static func uploadOutcome(
        fileURL: URL,
        token: String,
        driveId: String,
        directoryId: String
    ) async -> KDriveContinuousUploadOutcome {
        if Task.isCancelled {
            return KDriveContinuousUploadOutcome(
                fileURL: fileURL,
                fileName: fileURL.lastPathComponent,
                succeeded: false,
                errorMessage: KDriveError.cancelled.localizedDescription
            )
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return KDriveContinuousUploadOutcome(
                fileURL: fileURL,
                fileName: fileURL.lastPathComponent,
                succeeded: false,
                errorMessage: L("Fichier introuvable : \(fileURL.lastPathComponent)", "File not found: \(fileURL.lastPathComponent)")
            )
        }

        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        LogCenter.kdrive(L("kDrive : envoi démarré — \(fileURL.lastPathComponent) (\(sizeBytes / 1_000_000) Mo).", "kDrive: upload started — \(fileURL.lastPathComponent) (\(sizeBytes / 1_000_000) MB)."))
        let startedAt = Date()

        do {
            try await performUpload(
                fileURL: fileURL,
                token: token,
                driveId: driveId,
                directoryId: directoryId
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            let speed = elapsed > 0 ? Int64(Double(sizeBytes) / elapsed) : 0
            LogCenter.kdrive(L("kDrive : envoyé — \(fileURL.lastPathComponent) (\(sizeBytes / 1_000_000) Mo en \(String(format: "%.0f", elapsed)) s ≈ \(speed / 1_000) Ko/s).", "kDrive: uploaded — \(fileURL.lastPathComponent) (\(sizeBytes / 1_000_000) MB in \(String(format: "%.0f", elapsed)) s ≈ \(speed / 1_000) KB/s)."))
            return KDriveContinuousUploadOutcome(
                fileURL: fileURL,
                fileName: fileURL.lastPathComponent,
                succeeded: true,
                errorMessage: nil
            )
        } catch {
            // Une erreur réseau (timeout, connexion coupée) ou un refus
            // transitoire du serveur (408, 429, 5xx) mérite une relance : le
            // fichier n'a jamais été écrit côté serveur, réessayer une fois
            // évite un échec définitif sur un incident passager.
            if KDriveError.isTransientUploadError(error), !Task.isCancelled {
                LogCenter.kdrive(L("kDrive : erreur transitoire sur \(fileURL.lastPathComponent), nouvelle tentative…", "kDrive: transient error on \(fileURL.lastPathComponent), retrying…"))
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else {
                    return KDriveContinuousUploadOutcome(
                        fileURL: fileURL,
                        fileName: fileURL.lastPathComponent,
                        succeeded: false,
                        errorMessage: KDriveError.cancelled.localizedDescription
                    )
                }
                do {
                    try await performUpload(
                        fileURL: fileURL,
                        token: token,
                        driveId: driveId,
                        directoryId: directoryId
                    )
                    return KDriveContinuousUploadOutcome(
                        fileURL: fileURL,
                        fileName: fileURL.lastPathComponent,
                        succeeded: true,
                        errorMessage: nil
                    )
                } catch {
                    // On tombe dans le retour d'échec ci-dessous.
                }
            }
            return KDriveContinuousUploadOutcome(
                fileURL: fileURL,
                fileName: fileURL.lastPathComponent,
                succeeded: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    nonisolated private static func performUpload(
        fileURL: URL,
        token: String,
        driveId: String,
        directoryId: String
    ) async throws {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectoryId = trimmedDirectory.isEmpty ? "1" : trimmedDirectory
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else {
            throw KDriveError.invalidConfiguration
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let originalName = fileURL.lastPathComponent
        guard fileSize > 0 else {
            throw KDriveError.uploadFailed(L("Fichier vide (0 octet) : \(originalName)", "Empty file (0 bytes): \(originalName)"))
        }
        let safeName = FilenamePolicy.kDriveFileName(originalName)

        // À partir de 95 Mio (seuil Orvian-IOS, marge sous les 100 Mo
        // officiels), on passe par une session chunkée, comme recommandé par
        // Infomaniak au-delà de 100 Mo. Cela lève au passage la limite de 1 Go.
        if KDriveUploadPolicy.usesChunkedSession(fileSize: fileSize) {
            try await performChunkedUpload(
                fileURL: fileURL, remoteFileName: safeName, fileSize: fileSize,
                token: cleanToken, driveId: cleanDriveId, directoryId: cleanDirectoryId
            )
            return
        }

        do {
            try await performSingleUpload(
                fileURL: fileURL, remoteFileName: safeName, fileSize: fileSize,
                token: cleanToken, driveId: cleanDriveId, directoryId: cleanDirectoryId
            )
        } catch let error as KDriveError {
            if case .serverError(let code, let message) = error, code == 422 {
                let fallback = FilenamePolicy.kDriveFallbackName(for: originalName)
                if fallback != safeName {
                    LogCenter.kdrive(L("kDrive : nom refusé (422) pour \(originalName), nouvelle tentative avec \(fallback).", "kDrive: name rejected (422) for \(originalName), retrying with \(fallback)."))
                    do {
                        try await performSingleUpload(
                            fileURL: fileURL, remoteFileName: fallback, fileSize: fileSize,
                            token: cleanToken, driveId: cleanDriveId, directoryId: cleanDirectoryId
                        )
                        return
                    } catch {
                        throw KDriveError.serverError(code, L("\(originalName) refusé même renommé (\(fallback)) : \(message)", "\(originalName) rejected even renamed (\(fallback)): \(message)"))
                    }
                }
            }
            throw error
        }
    }

    /// Envoi chunké (fichiers >= 95 Mio), identique à Orvian-IOS : ouverture
    /// d'une session kDrive (`conflict=rename`, `last_modified_at`), chunks de
    /// 250 Mo envoyés 4 par 4 avec hash SHA256 sur l'hôte `upload_url` de
    /// confiance, chacun relancé individuellement (3 tentatives, backoff),
    /// puis `finish` qui assemble le fichier. En cas d'échec, la session est
    /// supprimée côté serveur (DELETE).
    nonisolated private static func performChunkedUpload(
        fileURL: URL,
        remoteFileName: String,
        fileSize: Int64,
        token cleanToken: String,
        driveId cleanDriveId: String,
        directoryId cleanDirectoryId: String
    ) async throws {
        // Plan de chunks : 250 Mo par chunk, augmenté si le
        // fichier dépasse la limite de 10 000 chunks par session.
        let plan = KDriveUploadPolicy.chunkPlan(fileSize: fileSize)
        let chunkSize = plan.chunkSize
        let totalChunks = plan.totalChunks

        struct StartReply: Decodable {
            struct StartData: Decodable {
                let token: String?
                let sessionToken: String?
                let uploadURL: String?
                let uploadUrl: String?
                enum CodingKeys: String, CodingKey {
                    case token
                    case sessionToken = "session_token"
                    case uploadURL = "upload_url"
                    case uploadUrl = "uploadUrl"
                }
                var resolvedToken: String? { token ?? sessionToken }
            }
            let data: StartData?
        }

        guard let startURL = URL(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/upload/session/start") else {
            throw KDriveError.invalidURL
        }
        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.timeoutInterval = 30
        startRequest.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let lastModifiedAt = Int(((fileAttrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        let startBody = try JSONSerialization.data(withJSONObject: [
            "file_name": remoteFileName,
            "directory_id": Int(cleanDirectoryId) ?? 1,
            "conflict": "rename",
            "total_chunks": totalChunks,
            "total_size": Int(fileSize),
            "last_modified_at": lastModifiedAt
        ])
        await KDriveRateLimitCenter.waitForRequestSlot()
        let (startData, startResponse) = try await KDriveUploadSession.session.upload(for: startRequest, from: startBody)
        guard let startHTTP = startResponse as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        KDriveRateLimitCenter.register(response: startHTTP, body: startData)
        guard (200..<300).contains(startHTTP.statusCode) else {
            throw KDriveError.serverError(startHTTP.statusCode, detailedMessage(from: startData, statusCode: startHTTP.statusCode, fileName: remoteFileName))
        }
        if let json = try? JSONSerialization.jsonObject(with: startData) as? [String: Any],
           let result = json["result"] as? String, result != "success", result != "asynchronous" {
            throw KDriveError.serverError(startHTTP.statusCode, detailedMessage(from: startData, statusCode: startHTTP.statusCode, fileName: remoteFileName))
        }
        let reply = try JSONDecoder().decode(StartReply.self, from: startData)
        guard let sessionToken = reply.data?.resolvedToken, !sessionToken.isEmpty else {
            throw KDriveError.uploadFailed(L("Session d'envoi kDrive absente pour \(remoteFileName).", "kDrive upload session missing for \(remoteFileName)."))
        }

        // Comme Orvian-IOS : l'hôte d'upload reçoit le jeton API en en-tête,
        // on ne suit que les hôtes Infomaniak de confiance.
        let rawUploadURL = (reply.data?.uploadURL ?? reply.data?.uploadUrl).flatMap { URL(string: $0) }
        let trustedUploadURL = rawUploadURL.flatMap { KDriveUploadURL.isTrustedUploadURL($0) ? $0 : nil }
        if rawUploadURL == nil {
            LogCenter.kdrive(L("kDrive : upload_url absente de la réponse de session — chunks envoyés sur api.infomaniak.com pour \(remoteFileName).", "kDrive: upload_url missing from session response — chunks sent to api.infomaniak.com for \(remoteFileName)."))
        } else if trustedUploadURL == nil {
            LogCenter.err(L("kDrive : upload_url non fiable ignorée — chunks envoyés sur api.infomaniak.com pour \(remoteFileName).", "kDrive: untrusted upload_url ignored — chunks sent to api.infomaniak.com for \(remoteFileName)."))
        }

        // Session incomplète (erreur ou annulation) : supprimée côté serveur,
        // comme Orvian-IOS (DELETE /upload/session/{token}). La tâche de
        // nettoyage n'hérite pas de l'annulation et peut finir seule.
        var sessionClosed = false
        defer {
            if !sessionClosed {
                Task { await Self.cancelUploadSession(sessionToken: sessionToken, driveId: cleanDriveId, apiToken: cleanToken, fileName: remoteFileName) }
            }
        }

        LogCenter.kdrive(L("kDrive : session chunkée ouverte — \(remoteFileName) (\(totalChunks) chunks de \(chunkSize / 1_000_000) Mo).", "kDrive: chunked session opened — \(remoteFileName) (\(totalChunks) chunks of \(chunkSize / 1_000_000) MB)."))

        // 4 chunks en parallèle par fichier, comme Orvian-IOS : avec 8
        // connexions/hôte et le pacing global espacé (58 req/min), on reste sous
        // la limite officielle de 60 req/min et sous le seuil de bridage edge.
        let chunkConcurrency = KDriveUploadPolicy.maxConcurrentChunks
        let maxChunkAttempts = 3
        let sendChunk: (Int) async throws -> Void = { chunkIndex in
            let offset = Int64(chunkIndex) * chunkSize
            let length = min(chunkSize, fileSize - offset)
            let chunkStarted = Date()
            // Si le fichier tient en 1 chunk (95 Mio–250 Mo), on le streame
            // directement sans copie temporaire ; sinon extrait par chunk.
            let chunkURLToUpload: URL
            let chunkSHA256: String
            let deleteTempChunk: Bool
            if totalChunks == 1 {
                chunkURLToUpload = fileURL
                chunkSHA256 = try Self.sha256Hex(fileURL: fileURL)
                deleteTempChunk = false
            } else {
                let chunk = try Self.extractChunkToTempFile(fileURL: fileURL, offset: offset, length: length)
                chunkURLToUpload = chunk.url
                chunkSHA256 = chunk.sha256
                deleteTempChunk = true
            }
            defer {
                if deleteTempChunk { try? FileManager.default.removeItem(at: chunkURLToUpload) }
            }

            // Chemin canonique /3/drive/.../chunk, hôte = upload_url de
            // confiance (sinon api.infomaniak.com), paramètres conservés.
            guard let chunkURL = KDriveUploadURL.chunkURL(
                uploadURL: trustedUploadURL,
                driveId: cleanDriveId,
                sessionToken: sessionToken,
                chunkNumber: chunkIndex + 1,
                chunkSize: length,
                chunkHash: chunkSHA256
            ) else { throw KDriveError.invalidURL }
            var chunkRequest = URLRequest(url: chunkURL)
            chunkRequest.httpMethod = "POST"
            chunkRequest.timeoutInterval = 600
            chunkRequest.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
            chunkRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            // Relance du chunk lui-même (3 tentatives, backoff 1 s/2 s +
            // `Retry-After`), comme Orvian-IOS. Renvoyer le même
            // `chunk_number` est sans risque : un chunk refusé n'est jamais
            // assemblé côté serveur.
            var lastError: Error?
            for attempt in 1...maxChunkAttempts {
                if Task.isCancelled { throw KDriveError.cancelled }
                await KDriveRateLimitCenter.waitForRequestSlot()
                do {
                    let (chunkData, chunkResponse) = try await KDriveUploadSession.session.upload(for: chunkRequest, fromFile: chunkURLToUpload)
                    guard let chunkHTTP = chunkResponse as? HTTPURLResponse else {
                        throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
                    }
                    KDriveRateLimitCenter.register(response: chunkHTTP, body: chunkData)
                    if (200..<300).contains(chunkHTTP.statusCode) {
                        // Un 2xx ne suffit pas : le corps doit confirmer
                        // `data.status == "ok"` (comme Orvian-IOS).
                        if KDriveChunkReply.isAccepted(data: chunkData, chunkNumber: chunkIndex + 1, chunkSize: length) {
                            lastError = nil
                            break
                        }
                        lastError = KDriveError.serverError(chunkHTTP.statusCode, L("\(remoteFileName) : chunk \(chunkIndex + 1)/\(totalChunks) non confirmé par le serveur.", "\(remoteFileName): chunk \(chunkIndex + 1)/\(totalChunks) not confirmed by the server."))
                    } else {
                        lastError = KDriveError.serverError(chunkHTTP.statusCode, L("\(remoteFileName) : chunk \(chunkIndex + 1)/\(totalChunks) refusé (HTTP \(chunkHTTP.statusCode)).", "\(remoteFileName): chunk \(chunkIndex + 1)/\(totalChunks) rejected (HTTP \(chunkHTTP.statusCode))."))
                        // 429 et 5xx sont transitoires ; tout autre code est définitif.
                        if chunkHTTP.statusCode != 429 && chunkHTTP.statusCode < 500 { throw lastError! }
                    }
                    if attempt < maxChunkAttempts {
                        let retryAfter = chunkHTTP.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                        let wait = min(retryAfter ?? Double(attempt), 120)
                        LogCenter.kdrive(L("kDrive : chunk \(chunkIndex + 1)/\(totalChunks) de \(remoteFileName) en HTTP \(chunkHTTP.statusCode), nouvelle tentative dans \(Int(wait)) s.", "kDrive: chunk \(chunkIndex + 1)/\(totalChunks) of \(remoteFileName) got HTTP \(chunkHTTP.statusCode), retrying in \(Int(wait)) s."))
                        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }
                } catch let urlError as URLError {
                    // Annulation (bouton Arrêt) : URLError(.cancelled) n'est
                    // pas une erreur transitoire, on propage sans relancer ni
                    // attendre (sinon l'arrêt continue de logger des retries).
                    if urlError.code == .cancelled || Task.isCancelled { throw urlError }
                    lastError = urlError
                    if attempt == maxChunkAttempts { throw urlError }
                    let wait = min(Double(attempt), 120)
                    LogCenter.kdrive(L("kDrive : erreur réseau sur le chunk \(chunkIndex + 1)/\(totalChunks) de \(remoteFileName), nouvelle tentative dans \(Int(wait)) s.", "kDrive: network error on chunk \(chunkIndex + 1)/\(totalChunks) of \(remoteFileName), retrying in \(Int(wait)) s."))
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
            if let lastError { throw lastError }
            let chunkElapsed = Date().timeIntervalSince(chunkStarted)
            let chunkSpeed = chunkElapsed > 0 ? Int64(TimeInterval(length) / chunkElapsed) : 0
            LogCenter.kdrive(L("kDrive : chunk \(chunkIndex + 1)/\(totalChunks) envoyé pour \(remoteFileName) (\(length / 1_000_000) Mo en \(String(format: "%.0f", chunkElapsed)) s ≈ \(chunkSpeed / 1_000) Ko/s).", "kDrive: chunk \(chunkIndex + 1)/\(totalChunks) sent for \(remoteFileName) (\(length / 1_000_000) MB in \(String(format: "%.0f", chunkElapsed)) s ≈ \(chunkSpeed / 1_000) KB/s)."))
        }

        var nextChunk = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            var activeChunks = 0
            while nextChunk < totalChunks && activeChunks < chunkConcurrency {
                if Task.isCancelled { throw KDriveError.cancelled }
                let index = nextChunk
                group.addTask { try await sendChunk(index) }
                nextChunk += 1
                activeChunks += 1
            }
            while activeChunks > 0 {
                _ = try await group.next()
                activeChunks -= 1
                if nextChunk < totalChunks {
                    if Task.isCancelled { throw KDriveError.cancelled }
                    let index = nextChunk
                    group.addTask { try await sendChunk(index) }
                    nextChunk += 1
                    activeChunks += 1
                }
            }
        }

        guard let finishURL = URL(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/upload/session/\(sessionToken)/finish") else {
            throw KDriveError.invalidURL
        }
        var finishRequest = URLRequest(url: finishURL)
        finishRequest.httpMethod = "POST"
        finishRequest.timeoutInterval = 120
        finishRequest.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        finishRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let finishAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let finishModifiedAt = Int(((finishAttrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        let finishBody = (try? JSONSerialization.data(withJSONObject: ["last_modified_at": finishModifiedAt])) ?? Data("{}".utf8)
        await KDriveRateLimitCenter.waitForRequestSlot()
        let (finishData, finishResponse) = try await KDriveUploadSession.session.upload(for: finishRequest, from: finishBody)
        guard let finishHTTP = finishResponse as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        KDriveRateLimitCenter.register(response: finishHTTP, body: finishData)
        guard (200..<300).contains(finishHTTP.statusCode) else {
            throw KDriveError.serverError(finishHTTP.statusCode, L("\(remoteFileName) : finalisation refusée (HTTP \(finishHTTP.statusCode)).", "\(remoteFileName): finish rejected (HTTP \(finishHTTP.statusCode))."))
        }
        if let json = try? JSONSerialization.jsonObject(with: finishData) as? [String: Any],
           let result = json["result"] as? String, result != "success", result != "asynchronous" {
            throw KDriveError.serverError(finishHTTP.statusCode, detailedMessage(from: finishData, statusCode: finishHTTP.statusCode, fileName: remoteFileName))
        }
        if let json = try? JSONSerialization.jsonObject(with: finishData) as? [String: Any],
           let file = json["data"] as? [String: Any] {
            let remoteName = (file["name"] as? String) ?? remoteFileName
            let remoteId = (file["id"] as? NSNumber)?.stringValue ?? "?"
            LogCenter.kdrive(L("kDrive : session close — \(remoteFileName) assemblé côté serveur en \(remoteName) (id \(remoteId), \(totalChunks) chunks).", "kDrive: session closed — \(remoteFileName) assembled server-side as \(remoteName) (id \(remoteId), \(totalChunks) chunks)."))
            if remoteName != remoteFileName {
                LogCenter.kdrive(L("kDrive : « \(remoteFileName) » existe déjà sur le Drive, enregistré sous « \(remoteName) ».", "kDrive: “\(remoteFileName)” already exists on the Drive, saved as “\(remoteName)”."))
            }
        }
        sessionClosed = true
    }

    /// Extrait l'intervalle [offset, offset+length[ du fichier source vers un
    /// fichier temporaire, pour uploader le chunk en streaming depuis le disque
    /// (`upload(for:fromFile:)`) sans charger tout le chunk en mémoire.
    /// Renvoie l'URL temporaire et le hash SHA256 du chunk (envoyé en
    /// `chunk_hash=sha256:…`, comme Orvian-IOS).
    nonisolated private static func sha256Hex(fileURL: URL) throws -> String {
        let src = try FileHandle(forReadingFrom: fileURL)
        defer { try? src.close() }
        var digest = SHA256()
        while true {
            let count: Int = try autoreleasepool {
                guard let data = try src.read(upToCount: 4_000_000), !data.isEmpty else { return 0 }
                digest.update(data: data)
                return data.count
            }
            if count == 0 { break }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func extractChunkToTempFile(fileURL: URL, offset: Int64, length: Int64) throws -> (url: URL, sha256: String) {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdrive-chunk-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil) else {
            throw KDriveError.uploadFailed(L("Écriture du chunk temporaire impossible.", "Could not create temporary chunk file."))
        }
        let src = try FileHandle(forReadingFrom: fileURL)
        defer { try? src.close() }
        try src.seek(toOffset: UInt64(offset))
        // `FileHandle(forWritingAtPath:)` est un initialiseur failable (FileHandle?).
        guard let dst = FileHandle(forWritingAtPath: tmpURL.path) else {
            throw KDriveError.uploadFailed(L("Ouverture du chunk temporaire en écriture impossible.", "Could not open temporary chunk file for writing."))
        }
        defer { try? dst.close() }
        var digest = SHA256()
        var remaining = length
        while remaining > 0 {
            let block = Int(min(remaining, 4_000_000))
            let written: Int64 = try autoreleasepool {
                guard let data = try src.read(upToCount: block), !data.isEmpty else {
                    throw KDriveError.uploadFailed(L("Lecture impossible du chunk à l'offset \(offset) de \(fileURL.lastPathComponent).", "Could not read chunk at offset \(offset) of \(fileURL.lastPathComponent)."))
                }
                digest.update(data: data)
                try dst.write(contentsOf: data)
                return Int64(data.count)
            }
            remaining -= written
        }
        return (tmpURL, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Supprime une session d'upload incomplète côté serveur
    /// (DELETE /3/drive/{driveId}/upload/session/{token}), comme Orvian-IOS.
    /// Best-effort : les erreurs sont ignorées.
    nonisolated private static func cancelUploadSession(sessionToken: String, driveId: String, apiToken: String, fileName: String) async {
        guard let url = URL(string: "https://api.infomaniak.com/3/drive/\(driveId)/upload/session/\(sessionToken)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        await KDriveRateLimitCenter.waitForRequestSlot()
        guard let (data, response) = try? await KDriveUploadSession.session.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        KDriveRateLimitCenter.register(response: http, body: data)
        LogCenter.kdrive(L("kDrive : session d'envoi annulée côté serveur pour \(fileName) (HTTP \(http.statusCode)).", "kDrive: upload session cancelled server-side for \(fileName) (HTTP \(http.statusCode))."))
    }

    nonisolated private static func performSingleUpload(
        fileURL: URL,
        remoteFileName: String,
        fileSize: Int64,
        token cleanToken: String,
        driveId cleanDriveId: String,
        directoryId cleanDirectoryId: String
    ) async throws {
        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let lastModifiedAt = Int(((fileAttrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        var components = URLComponents(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/upload")
        components?.queryItems = [
            URLQueryItem(name: "directory_id", value: cleanDirectoryId),
            URLQueryItem(name: "file_name", value: remoteFileName),
            URLQueryItem(name: "total_size", value: String(fileSize)),
            URLQueryItem(name: "last_modified_at", value: String(lastModifiedAt)),
            URLQueryItem(name: "conflict", value: "rename")
        ]
        // `URLComponents` ne percent-encode pas le « + » : kDrive le décode
        // comme un espace (sémantique application/x-www-form-urlencoded), le
        // fichier distant était renommé et le dédoublonnage ne le retrouvait
        // jamais. On l'encode explicitement en %2B.
        if let encodedQuery = components?.percentEncodedQuery {
            components?.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let requestURL = components?.url else {
            throw KDriveError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        // Sans timeout généreux, un upload lent (le timer compte les données
        // reçues, inexistantes pendant un envoi) était tué en pleine transfert.
        request.timeoutInterval = 600
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        await KDriveRateLimitCenter.waitForRequestSlot()
        let (data, response) = try await KDriveUploadSession.session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        KDriveRateLimitCenter.register(response: httpResponse, body: data)
        if httpResponse.statusCode == 401 {
            throw KDriveError.authenticationFailed
        }
        if httpResponse.statusCode == 404 {
            throw KDriveError.uploadFailed(L("Dossier ou Drive introuvable", "Folder or Drive not found"))
        }
        if httpResponse.statusCode == 429 {
            throw KDriveError.serverError(429, L("\(remoteFileName) : trop de requêtes, réessaie dans un moment.", "\(remoteFileName): too many requests, try again shortly."))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw KDriveError.serverError(httpResponse.statusCode, detailedMessage(from: data, statusCode: httpResponse.statusCode, fileName: remoteFileName))
        }
        // kDrive peut répondre 200 avec un corps « result: error » : sans cette
        // vérification, un envoi refusé serveur passe pour une réussite et le
        // fichier est réenvoyé à chaque fois (jamais présent dans le listing).
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LogCenter.kdrive(L("kDrive : envoyé — \(remoteFileName) (réponse serveur illisible, non vérifiée).", "kDrive: uploaded — \(remoteFileName) (unreadable server response, unverified)."))
            return
        }
        if let result = reply["result"] as? String, result != "success", result != "asynchronous" {
            throw KDriveError.serverError(httpResponse.statusCode, detailedMessage(from: data, statusCode: httpResponse.statusCode, fileName: remoteFileName))
        }
        if let file = reply["data"] as? [String: Any] {
            let remoteName = (file["name"] as? String) ?? remoteFileName
            let remoteId = (file["id"] as? NSNumber)?.stringValue ?? "?"
            LogCenter.kdrive(L("kDrive : fichier créé sur le Drive — \(remoteName) (id \(remoteId)).", "kDrive: file created on Drive — \(remoteName) (id \(remoteId))."))
            if remoteName != remoteFileName {
                LogCenter.kdrive(L("kDrive : « \(remoteFileName) » existe déjà sur le Drive, enregistré sous « \(remoteName) ».", "kDrive: “\(remoteFileName)” already exists on the Drive, saved as “\(remoteName)”."))
            }
        }
    }

    nonisolated private static func detailedMessage(from data: Data, statusCode: Int, fileName: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let description = (error["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var details: [String] = []
            if let items = error["errors"] as? [[String: Any]] {
                for item in items.prefix(3) {
                    let d = (item["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let code = (item["code"] as? String) ?? ""
                    let attribute = ((item["context"] as? [String: Any])?["attribute"] as? String) ?? ""
                    let part = [attribute, code, d].filter { !$0.isEmpty }.joined(separator: " ")
                    if !part.isEmpty { details.append(part) }
                }
            }
            var base = description?.isEmpty == false ? description! : "HTTP \(statusCode)"
            if !details.isEmpty { base += " — " + details.joined(separator: " · ") }
            return "\(fileName) : \(base)"
        }
        return "\(fileName) : HTTP \(statusCode)"
    }
}

private struct KDriveContinuousUploadSheet: View {
    let lot: KDriveUploadLot
    let token: String
    let driveId: String

    private var uploader = KDriveContinuousUploadController.shared
    private var rateLimit = KDriveRateLimitCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var deletedCount = 0
    @State private var deleteFailures = 0
    @State private var showDuplicateDeleteConfirm = false
    @State private var duplicateDeletedCount = 0
    @State private var duplicateDeleteFailures = 0
    @State private var isDeleting = false

    /// Médias locaux déjà présents sur le Drive, prêts à la suppression.
    var alreadyOnDriveURLs: [URL] { lot.alreadyOnDriveURLs }

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.space(3)) {
                ScrollView {
                    Group {
                        if uploader.finished {
                            UploadConsoleCard(
                                icon: uploader.wasCancelled ? "xmark.circle.fill" : (uploader.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"),
                                iconColor: uploader.wasCancelled ? DS.accentEmphasis : (uploader.failedCount == 0 ? DS.accentEmphasis : DS.error),
                                title: uploader.wasCancelled ? L("Upload annulé", "Upload cancelled") : (uploader.failedCount == 0 ? L("Upload terminé", "Upload complete") : L("Upload terminé avec avertissements", "Upload completed with warnings")),
                                status: L("« \(lot.directoryName) »", "“\(lot.directoryName)”"),
                                counter: nil,
                                progress: nil,
                                stats: finishedStats,
                                summary: L("\(uploader.successCount) média(s) envoyé(s).", "\(uploader.successCount) media file(s) uploaded."))
                        } else {
                            UploadConsoleCard(
                                icon: "icloud.and.arrow.up.fill",
                                iconColor: DS.accentEmphasis,
                                title: L("Envoi vers kDrive…", "Uploading to kDrive…"),
                                status: L("« \(lot.directoryName) »", "“\(lot.directoryName)”"),
                                counter: "\(uploader.completedCount) / \(max(1, uploader.totalCount))",
                                progress: uploader.progress,
                                stats: progressStats,
                                summary: nil)
                        }
                    }
                    .padding(.horizontal, DS.space(4))
                    .padding(.top, DS.space(2))
                }

                VStack(spacing: DS.space(2)) {
                    if uploader.isUploading {
                        UploadActionButton(title: L("Continuer en arrière-plan", "Continue in background"), systemImage: "icloud.and.arrow.up", prominent: true) { dismiss() }
                        UploadActionButton(title: L("Annuler l'envoi", "Cancel upload"), systemImage: "xmark.circle", destructive: true) { uploader.cancel() }
                    } else {
                        UploadActionButton(title: L("Fermer", "Close"), systemImage: "checkmark", prominent: true) { dismiss() }
                        if deletedCount == 0 && deleteFailures == 0 && !uploader.uploadedFileURLs.isEmpty {
                            UploadActionButton(title: L("Supprimer \(uploader.uploadedFileURLs.count) envoyés du téléphone", "Delete \(uploader.uploadedFileURLs.count) uploaded from device"), systemImage: "trash", destructive: true) {
                                showDeleteConfirm = true
                            }
                            .disabled(isDeleting)
                        }
                        if duplicateDeletedCount == 0 && duplicateDeleteFailures == 0 && !alreadyOnDriveURLs.isEmpty {
                            UploadActionButton(title: L("Supprimer \(alreadyOnDriveURLs.count) doublons du téléphone", "Delete \(alreadyOnDriveURLs.count) duplicates from phone"), systemImage: "trash", destructive: true) {
                                showDuplicateDeleteConfirm = true
                            }
                            .disabled(isDeleting)
                        }
                    }
                }
                .padding(.horizontal, DS.space(4))
                .padding(.bottom, DS.space(3))
            }
            .navigationTitle("Infomaniak kDrive")
            .navigationBarTitleDisplayMode(.inline)
            .tint(DS.accentEmphasis)
        }
        .confirmationDialog(
            L("Supprimer les \(uploader.uploadedFileURLs.count) fichier(s) envoyé(s) du téléphone ?", "Delete the \(uploader.uploadedFileURLs.count) uploaded file(s) from the device?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Supprimer", "Delete"), role: .destructive) { deleteUploadedFiles() }
            Button(L("Annuler", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("Les fichiers envoyés avec succès seront supprimés définitivement du stockage de l'app (pas de corbeille). Ils restent bien sûr sur kDrive. Si aucun média ne reste dans la collection, celle-ci sera aussi supprimée.", "Successfully uploaded files will be permanently removed from the app storage (no trash). They remain on kDrive. If no media remains in the collection, it will also be deleted."))
        }
        .confirmationDialog(
            L("Supprimer les \(alreadyOnDriveURLs.count) média(s) déjà sur le Drive du téléphone ?", "Delete the \(alreadyOnDriveURLs.count) media file(s) already on the Drive from the phone?"),
            isPresented: $showDuplicateDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Supprimer", "Delete"), role: .destructive) { deleteAlreadyOnDriveFiles() }
            Button(L("Annuler", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("Ces médias existent déjà sur le Drive. Les copies locales seront supprimées définitivement (pas de corbeille). Si aucun média ne reste dans la collection, celle-ci sera aussi supprimée.", "These media files already exist on the Drive. Local copies will be permanently removed (no trash). If no media remains in the collection, it will also be deleted."))
        }
        .errorAlert(uploader.finalError)
        .presentationDetents([.large])
        .onAppear { startUploadIfNeeded() }
    }


    private var progressStats: [(label: String, value: String)] {
        var stats: [(label: String, value: String)] = []
        if uploader.totalBytes > 0 {
            stats.append((L("Envoyé", "Sent"), "\(Self.formatBytes(uploader.uploadedBytes)) / \(Self.formatBytes(uploader.totalBytes))"))
            stats.append((L("Débit", "Speed"), "≈ \(Self.formatBytes(Int64(uploader.speedBytesPerSecond)))/s"))
        }
        if uploader.activeUploadCount > 0 {
            stats.append((L("En cours", "Active"), "\(uploader.activeUploadCount) / \(uploader.activeLimit)"))
        }
        if lot.skippedCount > 0 {
            stats.append((L("Déjà sur le Drive", "Already on Drive"), "\(lot.skippedCount)"))
        }
        stats.append((L("API", "API"), rateLimit.apiRateLabel))
        if paceInfoSecondsRemaining > 0 {
            let eta = paceInfoSecondsRemaining >= 60 ? "\(paceInfoSecondsRemaining / 60) min" : "\(paceInfoSecondsRemaining) s"
            stats.append((L("Reste estimé", "Est. remaining"), "≈ \(eta)"))
        } else if rateLimit.nextSlotDelay > 3 {
            stats.append((L("Cadence API", "API pacing"), "\(Int(rateLimit.nextSlotDelay.rounded())) s"))
        }
        if !uploader.lastCompletedFileName.isEmpty {
            stats.append((L("Dernier fichier", "Last file"), uploader.lastCompletedFileName))
        }
        return stats
    }

    private var finishedStats: [(label: String, value: String)] {
        var stats: [(label: String, value: String)] = []
        if lot.skippedCount > 0 {
            stats.append((L("Déjà présents, ignorés", "Already present, skipped"), "\(lot.skippedCount)"))
        }
        if deletedCount > 0 || deleteFailures > 0 {
            stats.append((L("Supprimés du téléphone", "Deleted from phone"), "\(deletedCount)"))
        }
        if duplicateDeletedCount > 0 || duplicateDeleteFailures > 0 {
            stats.append((L("Doublons supprimés", "Duplicates deleted"), "\(duplicateDeletedCount)"))
        }
        return stats
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// Durée restante estimée au plafond API (0 masque la ligne aux petits lots).
    private var paceInfoSecondsRemaining: Int {
        guard KDriveRateLimitCenter.isPacingEnabled() else { return 0 }
        let remaining = uploader.totalCount - uploader.completedCount
        guard remaining > 3 else { return 0 }
        let limit = max(1, KDriveRateLimitCenter.currentPacingLimit())
        return Int(Double(remaining) * 60 / Double(limit))
    }

    private func startUploadIfNeeded() {
        // Livraison en cours ou terminée pour ce lot : on s'attache sans rien
        // redémarrer (réaffichage depuis le bandeau d'état).
        guard uploader.activeLot?.id != lot.id else { return }
        uploader.start(
            lot: lot,
            token: token,
            driveId: driveId
        )
    }

    private func deleteUploadedFiles() {
        guard !isDeleting else { return }
        isDeleting = true
        let urls = uploader.uploadedFileURLs
        Task { @MainActor in
            let (deleted, failures) = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var deleted = 0
                var failures = 0
                for url in urls where fm.fileExists(atPath: url.path) {
                    do {
                        try fm.removeItem(at: url)
                        MediaMetadata.remove(for: url)
                        deleted += 1
                    } catch {
                        failures += 1
                        LogCenter.err(L("kDrive : suppression impossible de \(url.lastPathComponent) : \(error.localizedDescription)", "kDrive: could not delete \(url.lastPathComponent): \(error.localizedDescription)"))
                    }
                }
                return (deleted, failures)
            }.value
            deletedCount = deleted
            deleteFailures = failures
            isDeleting = false
            if deleted > 0 || (failures == 0 && !urls.isEmpty) {
                // La galerie et les compteurs relisent la collection active ;
                // si plus aucun média n'y reste, la collection est retirée.
                NotificationCenter.default.post(name: .rmpFilesDeletedLocally, object: lot.collectionID)
            }
            LogCenter.info(L("\(deleted) fichier(s) envoyé(s) supprimé(s) du téléphone (\(failures) échec(s)).", "\(deleted) uploaded file(s) deleted from the device (\(failures) failure(s))."))
        }
    }

    private func deleteAlreadyOnDriveFiles() {
        guard !isDeleting else { return }
        isDeleting = true
        let urls = alreadyOnDriveURLs
        Task { @MainActor in
            let (deleted, failures) = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var deleted = 0
                var failures = 0
                for url in urls where fm.fileExists(atPath: url.path) {
                    do {
                        try fm.removeItem(at: url)
                        MediaMetadata.remove(for: url)
                        deleted += 1
                    } catch {
                        failures += 1
                    }
                }
                return (deleted, failures)
            }.value
            duplicateDeletedCount = deleted
            duplicateDeleteFailures = failures
            isDeleting = false
            if deleted > 0 || (failures == 0 && !urls.isEmpty) {
                // La galerie et les compteurs relisent la collection active ;
                // si plus aucun média n'y reste, la collection est retirée.
                NotificationCenter.default.post(name: .rmpFilesDeletedLocally, object: lot.collectionID)
            }
            LogCenter.info(L("\(deleted) média(s) déjà sur le Drive supprimé(s) du téléphone (\(failures) échec(s)).", "\(deleted) media file(s) already on the Drive deleted from the device (\(failures) failure(s))."))
        }
    }
}

/// Bandeau d'état : visible tant qu'un envoi kDrive tourne ou jusqu'à fermeture
/// après complétion. Tap = réaffiche la feuille de progression.
struct KDriveUploadBanner: View {
    private var uploader = KDriveContinuousUploadController.shared
    @State private var presented = false
    @State private var dismissed = false

    private var visible: Bool {
        guard uploader.activeLot != nil else { return false }
        return uploader.isUploading || presented || (uploader.finished && !dismissed)
    }

    var body: some View {
        if visible, let lot = uploader.activeLot {
            HStack(spacing: DS.space(2)) {
                Button {
                    presented = true
                } label: {
                    HStack(spacing: DS.space(2)) {
                        Image(systemName: bannerIcon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(bannerColor)
                            .frame(width: 28, height: 28)
                            .background(bannerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusS))
                        Text(bannerText)
                            .font(DS.monoCaption)
                            .foregroundStyle(DS.onSurface)
                            .lineLimit(1)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(DSPressableButtonStyle())
                .accessibilityLabel(bannerAccessibilityLabel)

                if uploader.finished && !uploader.isUploading {
                    Button {
                        dismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.onSurfaceMuted)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Masquer le bandeau kDrive", "Dismiss kDrive banner"))
                }
            }
            .padding(.horizontal, DS.space(3))
            .glassEffect(in: Capsule())
            .overlay(Capsule().strokeBorder(bannerColor.opacity(0.4)))
            .sheet(isPresented: $presented) {
                KDriveContinuousUploadSheet(lot: lot, token: kDriveToken, driveId: kDriveId)
            }
            .onChange(of: uploader.activeLot?.id) { _, _ in
                dismissed = false
            }
        }
    }

    private var bannerIcon: String {
        if uploader.isUploading { return "icloud.and.arrow.up.fill" }
        if uploader.wasCancelled { return "xmark.circle.fill" }
        return uploader.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var bannerColor: Color {
        if uploader.isUploading || uploader.wasCancelled { return DS.accentEmphasis }
        return uploader.failedCount == 0 ? DS.accentEmphasis : DS.error
    }

    private var bannerText: String {
        if uploader.isUploading {
            return L("Envoi kDrive… \(uploader.completedCount)/\(max(1, uploader.totalCount))", "kDrive upload… \(uploader.completedCount)/\(max(1, uploader.totalCount))")
        }
        if uploader.wasCancelled {
            return L("Envoi kDrive annulé (\(uploader.successCount) envoyés)", "kDrive upload cancelled (\(uploader.successCount) sent)")
        }
        if uploader.failedCount > 0 {
            return L("kDrive : \(uploader.successCount) OK, \(uploader.failedCount) échec(s)", "kDrive: \(uploader.successCount) OK, \(uploader.failedCount) failed")
        }
        return L("kDrive terminé (\(uploader.successCount))", "kDrive done (\(uploader.successCount))")
    }

    private var bannerAccessibilityLabel: String {
        if uploader.isUploading {
            return L("Envoi kDrive en cours : \(uploader.completedCount) sur \(max(1, uploader.totalCount)). Touchez pour voir la progression.", "kDrive upload in progress: \(uploader.completedCount) of \(max(1, uploader.totalCount)). Tap to see progress.")
        }
        return L("\(bannerText). Touchez pour ouvrir les actions de nettoyage.", "\(bannerText). Tap to open cleanup actions.")
    }

    @AppStorage("kDriveApiToken") private var kDriveToken = ""
    @AppStorage("kDriveId") private var kDriveId = ""
}

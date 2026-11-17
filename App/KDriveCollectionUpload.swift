import Foundation
import MediaCore
import SwiftUI

/// Action « Envoyer vers kDrive » : elle apparaît à plat dans le menu « … »
/// de la barre de navigation, sans sous-menu imbriqué.
struct KDriveCollectionUploadAction: View {
    let files: [URL]
    let collectionLabel: String

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
                collectionLabel: collectionLabel
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

    @AppStorage("kDriveDirectoryId") private var configuredDirectoryId = "1"
    @AppStorage("kDriveDirectoryName") private var configuredDirectoryName = "Racine (kDrive)"

    @Environment(\.dismiss) private var dismiss
    @State private var uploadDirectoryId: String?
    @State private var uploadDirectoryName = ""
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var pendingFiles: [URL]?
    @State private var skippedCount = 0

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
            if let uploadDirectoryId, let pendingFiles {
                KDriveContinuousUploadSheet(
                    files: pendingFiles,
                    token: token,
                    driveId: driveId,
                    directoryId: uploadDirectoryId,
                    directoryName: uploadDirectoryName,
                    skippedCount: skippedCount
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
                            .foregroundStyle(.secondary)
                        Text(L("Analyse des médias déjà présents…", "Scanning media already present…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .navigationTitle("Infomaniak kDrive")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else if errorMessage != nil {
                NavigationStack {
                    VStack(spacing: 18) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("Réessayer", "Retry")) {
                            prepareCollectionFolder()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        Button(L("Annuler", "Cancel")) { dismiss() }
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
    }

    private func prepareCollectionFolder() {
        guard uploadDirectoryId == nil, pendingFiles == nil, !isPreparing else { return }
        isPreparing = true
        errorMessage = nil

        let parentId = parentDirectoryId
        Task { @MainActor in
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

                uploadDirectoryId = String(folder.id)
                uploadDirectoryName = folder.name

                // Déduplication par nom : on ne ré-uploade jamais un média
                // déjà présent (nom assaini ou repli 422 déterministe).
                let remoteNames = try await service.fetchFileNames(
                    token: token,
                    driveId: driveId,
                    directoryId: String(folder.id)
                )
                let filtered = files.filter { localURL in
                    let candidates = FilenamePolicy.kDriveRemoteCandidateNames(for: localURL.lastPathComponent)
                    return !candidates.contains { candidate in
                        remoteNames.contains { remote in
                            FilenamePolicy.kDriveNameMatch(remote, candidate)
                        }
                    }
                }
                skippedCount = files.count - filtered.count
                LogCenter.kdrive(L("kDrive : \(remoteNames.count) fichier(s) distant(s) analysé(s) — \(skippedCount) ignoré(s), \(filtered.count) à envoyer.", "kDrive: \(remoteNames.count) remote file(s) scanned — \(skippedCount) skipped, \(filtered.count) to upload."))
                if filtered.isEmpty {
                    LogCenter.kdrive(L("kDrive : rien à envoyer, tous les médias sont déjà présents.", "kDrive: nothing to upload, all media already present."))
                }
                pendingFiles = filtered
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
    let fileName: String
    let succeeded: Bool
    let errorMessage: String?
}

/// Session URLSession dédiée aux envois kDrive : elle rapporte les octets
/// réellement transmis (progression pendant l'envoi d'un fichier, pas
/// seulement à sa fin) et coupe les tâches au point mort — sans elle, un
/// envoi qui piétine laisse la fenêtre bloquée à « 0 sur N » sans erreur.
final class KDriveUploadSession: NSObject, URLSessionTaskDelegate {
    static let shared = KDriveUploadSession()

    private let lock = NSLock()
    /// taskIdentifier -> octets envoyés. Les tâches réussies y restent
    /// jusqu'au lot suivant : leurs octets comptent dans la progression.
    private var sent: [Int: Int64] = [:]
    private var lastActivity: [Int: Date] = [:]
    /// Tâches en vol, suivies par le délégué : `URLSession.allTasks` est
    /// un accès asynchrone dans les SDK récents, on s'en passe.
    private var inflight: [Int: URLSessionTask] = [:]

    /// `static let` : initialisation thread-safe, au contraire d'un `lazy var`
    /// accessible depuis plusieurs uploads concurrents. La configuration par
    /// défaut plafonne à 6 connexions par hôte : sans cela, nos 8 flux
    /// parallèles ne serviraient à rien (2 resteraient en file d'attente).
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionPerHost = 16
        return URLSession(configuration: configuration, delegate: KDriveUploadSession.shared, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend totalBytesExpected: Int64) {
        lock.lock()
        sent[task.taskIdentifier] = totalBytesSent
        lastActivity[task.taskIdentifier] = Date()
        inflight[task.taskIdentifier] = task
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        inflight.removeValue(forKey: task.taskIdentifier)
        lastActivity.removeValue(forKey: task.taskIdentifier)
        if error != nil {
            sent.removeValue(forKey: task.taskIdentifier)
        }
        lock.unlock()
    }

    /// Octets transmis du lot en cours (fichiers finis + en cours).
    func sentTotal() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sent.values.reduce(0, +)
    }

    /// Nouveau lot : on repart de zéro.
    func reset() {
        lock.lock()
        sent.removeAll()
        lastActivity.removeAll()
        inflight.removeAll()
        lock.unlock()
    }

    /// Coupe les envois sans progrès depuis `staleSeconds` : l'annulation
    /// fait échouer la requête, qui est relancée automatiquement par le
    /// contrôleur. C'est ce qui débloque les envois morts sans erreur.
    func cancelStalledTasks(olderThan staleSeconds: TimeInterval) {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-staleSeconds)
        let stale = inflight.filter { entry in
            guard let last = lastActivity[entry.key] else { return false }
            return last < cutoff
        }
        lock.unlock()
        for (_, task) in stale {
            let name = Self.fileName(of: task)
            LogCenter.kdrive(L("kDrive : envoi au point mort, annulation pour relance — \(name).", "kDrive: stalled upload, cancelling to retry — \(name)."))
            task.cancel()
        }
    }

    private static func fileName(of task: URLSessionTask) -> String {
        guard let url = task.currentRequest?.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let name = components.queryItems?.first(where: { $0.name == "file_name" })?.value else {
            return "#\(task.taskIdentifier)"
        }
        return name
    }
}

@MainActor
private final class KDriveContinuousUploadController: ObservableObject {
    static let concurrentLimit = 4

    @Published var isUploading = false
    @Published var completedCount = 0
    @Published var totalCount = 0
    @Published var progress = 0.0
    @Published var lastCompletedFileName = ""
    @Published var uploadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var speedBytesPerSecond: Double = 0
    @Published var activeLimit = KDriveContinuousUploadController.concurrentLimit

    private var activeTask: Task<Void, Never>?

    func start(
        files: [URL],
        token: String,
        driveId: String,
        directoryId: String,
        completion: @escaping (_ successCount: Int, _ failedCount: Int, _ errorMessage: String?) -> Void
    ) {
        cancel()
        KDriveUploadSession.shared.reset()
        LogCenter.kdrive(L("Envoi kDrive démarré : \(files.count) fichiers.", "kDrive upload started: \(files.count) files."))
        isUploading = true
        completedCount = 0
        totalCount = files.count
        progress = 0
        lastCompletedFileName = ""
        uploadedBytes = 0
        speedBytesPerSecond = 0
        totalBytes = files.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)?.int64Value ?? 0) }
        // Fichiers volumineux : 8 flux en parallèle — kDrive bride chaque
        // connexion (~100 Ko/s observés), la bande passante passe par le
        // nombre de flux. Petits fichiers : 4 seulement, pour rester loin
        // de la limite API de 60 requêtes/minute.
        let averageBytes = files.isEmpty ? 0 : totalBytes / Int64(files.count)
        activeLimit = averageBytes >= 20_000_000 ? 8 : Self.concurrentLimit

        activeTask = Task {
            // Supervision : progression par octets + vitesse + coupe des
            // envois au point mort. Sans elle, un envoi qui piétine ne produit
            // aucune erreur et la fenêtre reste bloquée à « 0 sur N ».
            let monitor = Task {
                var lastBytes: Int64 = 0
                var lastDate = Date()
                while !Task.isCancelled {
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
                    KDriveUploadSession.shared.cancelStalledTasks(olderThan: 90)
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
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    completed += 1
                    completedCount = completed
                    lastCompletedFileName = outcome.fileName
                    progress = Double(completed) / Double(max(1, files.count))

                    if outcome.succeeded {
                        success += 1
                    } else {
                        failed += 1
                        LogCenter.err(L("kDrive : échec — \(outcome.fileName) : \(outcome.errorMessage ?? "")", "kDrive: failed — \(outcome.fileName): \(outcome.errorMessage ?? "")"))
                        if failedExamples.count < 5 { failedExamples.append(outcome) }
                    }

                    // File glissante : dès qu’une connexion se libère, le fichier
                    // suivant démarre immédiatement. On n’attend jamais la fin
                    // des trois autres uploads du groupe initial.
                    if nextIndex < files.count && !Task.isCancelled {
                        let fileURL = files[nextIndex]
                        nextIndex += 1
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

            if Task.isCancelled {
                LogCenter.kdrive(L("Envoi kDrive annulé.", "kDrive upload cancelled."))
                completion(success, failed, KDriveError.cancelled.localizedDescription)
            } else {
                progress = files.isEmpty ? 0 : 1
                if failed > 0 { LogCenter.err(L("Envoi kDrive : \(success) réussis, \(failed) échoués.", "kDrive upload: \(success) ok, \(failed) failed.")) }
                else { LogCenter.kdrive(L("Envoi kDrive terminé : \(success) fichiers.", "kDrive upload done: \(success) files.")) }
                completion(success, failed, summaryMessage)
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isUploading = false
    }

    nonisolated private static func uploadOutcome(
        fileURL: URL,
        token: String,
        driveId: String,
        directoryId: String
    ) async -> KDriveContinuousUploadOutcome {
        if Task.isCancelled {
            return KDriveContinuousUploadOutcome(
                fileName: fileURL.lastPathComponent,
                succeeded: false,
                errorMessage: KDriveError.cancelled.localizedDescription
            )
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return KDriveContinuousUploadOutcome(
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
                fileName: fileURL.lastPathComponent,
                succeeded: true,
                errorMessage: nil
            )
        } catch {
            // Une erreur réseau (timeout, connexion coupée) mérite une relance
            // : le fichier n'a jamais été écrit côté serveur, réessayer une
            // fois évite un échec définitif sur un incident passager.
            if error is URLError, !Task.isCancelled {
                LogCenter.kdrive(L("kDrive : erreur réseau sur \(fileURL.lastPathComponent), nouvelle tentative…", "kDrive: network error on \(fileURL.lastPathComponent), retrying…"))
                do {
                    try await performUpload(
                        fileURL: fileURL,
                        token: token,
                        driveId: driveId,
                        directoryId: directoryId
                    )
                    return KDriveContinuousUploadOutcome(
                        fileName: fileURL.lastPathComponent,
                        succeeded: true,
                        errorMessage: nil
                    )
                } catch {
                    // On tombe dans le retour d'échec ci-dessous.
                }
            }
            return KDriveContinuousUploadOutcome(
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
        guard fileSize <= 1_000_000_000 else {
            throw KDriveError.uploadFailed(L("Fichier trop volumineux pour l'envoi direct (> 1 Go) : \(originalName)", "File too large for direct upload (> 1 GB): \(originalName)"))
        }
        let safeName = FilenamePolicy.kDriveFileName(originalName)
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

    nonisolated private static func performSingleUpload(
        fileURL: URL,
        remoteFileName: String,
        fileSize: Int64,
        token cleanToken: String,
        driveId cleanDriveId: String,
        directoryId cleanDirectoryId: String
    ) async throws {
        var components = URLComponents(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/upload")
        components?.queryItems = [
            URLQueryItem(name: "directory_id", value: cleanDirectoryId),
            URLQueryItem(name: "file_name", value: remoteFileName),
            URLQueryItem(name: "total_size", value: String(fileSize)),
            URLQueryItem(name: "conflict", value: "version")
        ]
        guard let requestURL = components?.url else {
            throw KDriveError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        // Sans timeout explicite, un upload dont la réponse ne revient jamais
        // laissait la barre de progression bloquée à 0 indéfiniment.
        request.timeoutInterval = 120
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await KDriveUploadSession.session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
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
    let files: [URL]
    let token: String
    let driveId: String
    let directoryId: String
    let directoryName: String
    let skippedCount: Int

    @StateObject private var uploader = KDriveContinuousUploadController()
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var finished = false
    @State private var successCount = 0
    @State private var failedCount = 0
    @State private var finalError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                if finished {
                    Image(systemName: failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(failedCount == 0 ? .green : .orange)

                    Text(failedCount == 0 ? L("Upload terminé", "Upload complete") : L("Upload terminé avec avertissements", "Upload completed with warnings"))
                        .font(.headline)

                    Text(L("\(successCount) média(s) envoyé(s) vers « \(directoryName) ».", "\(successCount) media file(s) uploaded to “\(directoryName)”."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if skippedCount > 0 {
                        Text(L("\(skippedCount) déjà présent(s), ignoré(s).", "\(skippedCount) already present, skipped."))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                } else {
                    ProgressView(value: uploader.progress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal)

                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)

                    Text(L("Envoi vers kDrive…", "Uploading to kDrive…"))
                        .font(.headline)

                    Text(L("\(uploader.completedCount) sur \(max(1, uploader.totalCount)) terminé(s)", "\(uploader.completedCount) of \(max(1, uploader.totalCount)) completed"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if uploader.totalBytes > 0 {
                        Text(L("\(Self.formatBytes(uploader.uploadedBytes)) envoyés sur \(Self.formatBytes(uploader.totalBytes)) — ≈ \(Self.formatBytes(Int64(uploader.speedBytesPerSecond)))/s", "\(Self.formatBytes(uploader.uploadedBytes)) sent of \(Self.formatBytes(uploader.totalBytes)) — ≈ \(Self.formatBytes(Int64(uploader.speedBytesPerSecond)))/s"))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if skippedCount > 0 {
                        Text(L("\(skippedCount) déjà présent(s) sur le Drive, ignoré(s).", "\(skippedCount) already on the Drive, skipped."))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }

                    Text(L("Jusqu’à \(uploader.activeLimit) uploads restent actifs en continu.", "Up to \(uploader.activeLimit) uploads stay active continuously."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if !uploader.lastCompletedFileName.isEmpty {
                        Text(uploader.lastCompletedFileName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal)
                    }
                }

                Spacer()

                Button {
                    if uploader.isUploading {
                        uploader.cancel()
                    }
                    dismiss()
                } label: {
                    Text(finished ? L("Fermer", "Close") : L("Annuler", "Cancel"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(finished ? .orange : .red)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Infomaniak kDrive")
            .navigationBarTitleDisplayMode(.inline)
        }
        .errorAlert(finalError)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(uploader.isUploading)
        .onAppear { startUploadIfNeeded() }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f Go", Double(bytes) / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f Mo", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f Ko", Double(bytes) / 1_000) }
        return "\(bytes) o"
    }

    private func startUploadIfNeeded() {
        guard !started else { return }
        started = true
        guard !files.isEmpty else {
            finished = true
            return
        }

        uploader.start(
            files: files,
            token: token,
            driveId: driveId,
            directoryId: directoryId
        ) { success, failed, error in
            successCount = success
            failedCount = failed
            finalError = error
            finished = true
        }
    }
}

import Foundation
import MediaCore
import SwiftUI

struct KDriveCollectionUploadButton: View {
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
            Image(systemName: "icloud.and.arrow.up")
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

    @Environment(\.dismiss) private var dismiss
    @State private var parentDirectoryId = "1"
    @State private var parentDirectoryName = L("Racine", "Root")
    @State private var uploadDirectoryId: String?
    @State private var uploadDirectoryName = ""
    @State private var isPreparing = false
    @State private var errorMessage: String?

    private var targetFolderName: String {
        // Dossier kDrive = juste le pseudo/sub, première lettre en majuscule
        // (ex. `leboxis` → `Leboxis`). Assaini pour l'API kDrive.
        FilenamePolicy.kDriveFolderName(collectionLabel)
    }

    var body: some View {
        Group {
            if let uploadDirectoryId {
                KDriveContinuousUploadSheet(
                    files: files,
                    token: token,
                    driveId: driveId,
                    directoryId: uploadDirectoryId,
                    directoryName: uploadDirectoryName
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
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .navigationTitle("Infomaniak kDrive")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else if let errorMessage {
                NavigationStack {
                    VStack(spacing: 18) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text(L("Impossible de préparer le dossier", "Could not prepare folder"))
                            .font(.headline)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Spacer()
                        Button(L("Choisir un autre dossier", "Choose another folder")) {
                            self.errorMessage = nil
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
                KDriveFolderPickerView(
                    token: token,
                    driveId: driveId,
                    directoryId: $parentDirectoryId,
                    directoryName: $parentDirectoryName,
                    dismissOnSelection: false,
                    onChoose: { directoryId, _ in
                        prepareCollectionFolder(in: directoryId)
                    }
                )
            }
        }
    }

    private func prepareCollectionFolder(in parentId: String) {
        isPreparing = true
        errorMessage = nil

        Task { @MainActor in
            do {
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
                        // réutilise celui qui vient d’être créé plutôt que d’échouer.
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
                isPreparing = false
            } catch {
                isPreparing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct KDriveContinuousUploadOutcome {
    let fileName: String
    let succeeded: Bool
    let errorMessage: String?
}

@MainActor
private final class KDriveContinuousUploadController: ObservableObject {
    static let concurrentLimit = 4

    @Published var isUploading = false
    @Published var completedCount = 0
    @Published var totalCount = 0
    @Published var progress = 0.0
    @Published var lastCompletedFileName = ""

    private var activeTask: Task<Void, Never>?

    func start(
        files: [URL],
        token: String,
        driveId: String,
        directoryId: String,
        completion: @escaping (_ successCount: Int, _ failedCount: Int, _ errorMessage: String?) -> Void
    ) {
        cancel()
        isUploading = true
        completedCount = 0
        totalCount = files.count
        progress = 0
        lastCompletedFileName = ""

        activeTask = Task {
            var success = 0
            var failed = 0
            var completed = 0
            var failedExamples: [KDriveContinuousUploadOutcome] = []

            await withTaskGroup(of: KDriveContinuousUploadOutcome.self) { group in
                var nextIndex = 0
                let initialCount = min(Self.concurrentLimit, files.count)

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
                completion(success, failed, KDriveError.cancelled.localizedDescription)
            } else {
                progress = files.isEmpty ? 0 : 1
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
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        if httpResponse.statusCode == 401 {
            throw KDriveError.authenticationFailed
        }
        if httpResponse.statusCode == 404 {
            throw KDriveError.uploadFailed(L("Dossier ou Drive introuvable", "Folder or Drive not found"))
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

                    if failedCount > 0 {
                        Text(L("\(failedCount) échec(s).", "\(failedCount) failure(s)."))
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if let finalError {
                        Text(finalError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
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

                    Text(L("Jusqu’à \(KDriveContinuousUploadController.concurrentLimit) uploads restent actifs en continu.", "Up to \(KDriveContinuousUploadController.concurrentLimit) uploads stay active continuously."))
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
        .presentationDetents([.medium])
        .interactiveDismissDisabled(uploader.isUploading)
        .onAppear { startUploadIfNeeded() }
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

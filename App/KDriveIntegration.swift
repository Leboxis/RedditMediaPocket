import Foundation
import MediaCore
import SwiftUI
import UIKit

enum KDriveError: LocalizedError {
    case invalidConfiguration
    case invalidURL
    case authenticationFailed
    case driveNotFound
    case uploadFailed(String)
    case serverError(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return L("Configure le token API et l’ID du Drive dans les Réglages.", "Configure the API token and Drive ID in Settings.")
        case .invalidURL:
            return L("URL de requête kDrive invalide.", "Invalid kDrive request URL.")
        case .authenticationFailed:
            return L("Échec d’authentification : vérifie le token API Infomaniak.", "Authentication failed: check the Infomaniak API token.")
        case .driveNotFound:
            return L("Drive introuvable : vérifie l’ID du kDrive.", "Drive not found: check the kDrive ID.")
        case .uploadFailed(let reason):
            return L("Échec de l’envoi : \(reason)", "Upload failed: \(reason)")
        case .serverError(let code, let message):
            return L("Erreur serveur (\(code)) : \(message)", "Server error (\(code)): \(message)")
        case .cancelled:
            return L("Upload annulé.", "Upload cancelled.")
        }
    }
}

private struct KDriveDriveInfo: Codable {
    let id: Int
    let name: String
}

struct KDriveFolderItem: Identifiable, Codable, Equatable, Hashable {
    let id: Int
    let name: String
    let type: String?

    var isDirectory: Bool {
        type == "dir" || type == "directory" || type == nil
    }
}

private struct KDriveAPIResponse<T: Codable>: Codable {
    let result: String
    let data: T?
    let error: KDriveAPIError?
}

private struct KDriveAPIError: Codable {
    let code: String?
    let description: String?
}

private struct KDriveUploadOutcome {
    let fileName: String
    let succeeded: Bool
    let errorMessage: String?
}

@MainActor
final class KDriveService: ObservableObject {
    static let shared = KDriveService()
    static let concurrentUploadLimit = 4

    @Published var isUploading = false
    @Published var currentProgress = 0.0
    @Published var currentFileIndex = 0
    @Published var totalFilesCount = 0
    @Published var currentFileName = ""
    @Published var lastError: String?

    private var activeTask: Task<Void, Never>?

    private init() {}

    func testConnection(token: String, driveId: String) async throws -> String {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else { throw KDriveError.invalidConfiguration }
        guard let url = URL(string: "https://api.infomaniak.com/2/drive/\(cleanDriveId)") else {
            throw KDriveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }

        if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
        if httpResponse.statusCode == 404 { throw KDriveError.driveNotFound }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let decoded = try? JSONDecoder().decode(KDriveAPIResponse<KDriveDriveInfo>.self, from: data),
               let description = decoded.error?.description {
                throw KDriveError.serverError(httpResponse.statusCode, description)
            }
            throw KDriveError.serverError(httpResponse.statusCode, "HTTP \(httpResponse.statusCode)")
        }

        let decoded = try JSONDecoder().decode(KDriveAPIResponse<KDriveDriveInfo>.self, from: data)
        return decoded.data?.name ?? "kDrive (ID: \(cleanDriveId))"
    }

    func fetchSubdirectories(token: String, driveId: String, directoryId: String = "1") async throws -> [KDriveFolderItem] {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectoryId = trimmedDirectory.isEmpty ? "1" : trimmedDirectory
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else { throw KDriveError.invalidConfiguration }
        guard let url = URL(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/files/\(cleanDirectoryId)/files?type[]=dir&limit=200") else {
            throw KDriveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let decoded = try? JSONDecoder().decode(KDriveAPIResponse<[KDriveFolderItem]>.self, from: data),
               let description = decoded.error?.description {
                throw KDriveError.serverError(httpResponse.statusCode, description)
            }
            throw KDriveError.serverError(httpResponse.statusCode, "HTTP \(httpResponse.statusCode)")
        }

        let decoded = try JSONDecoder().decode(KDriveAPIResponse<[KDriveFolderItem]>.self, from: data)
        return (decoded.data ?? [])
            .filter(\.isDirectory)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createDirectory(token: String, driveId: String, parentDirectoryId: String = "1", folderName: String) async throws -> KDriveFolderItem {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParent = parentDirectoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanParentId = trimmedParent.isEmpty ? "1" : trimmedParent
        let cleanName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty, !cleanName.isEmpty else {
            throw KDriveError.invalidConfiguration
        }
        guard let url = URL(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/files/\(cleanParentId)/directory") else {
            throw KDriveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": cleanName])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let decoded = try? JSONDecoder().decode(KDriveAPIResponse<KDriveFolderItem>.self, from: data),
               let description = decoded.error?.description {
                throw KDriveError.serverError(httpResponse.statusCode, description)
            }
            throw KDriveError.serverError(httpResponse.statusCode, L("Création du dossier impossible", "Could not create folder"))
        }

        let decoded = try JSONDecoder().decode(KDriveAPIResponse<KDriveFolderItem>.self, from: data)
        guard let folder = decoded.data else {
            throw KDriveError.serverError(httpResponse.statusCode, L("Impossible de lire le dossier créé", "Could not read the created folder"))
        }
        return folder
    }

    func uploadFile(fileURL: URL, token: String, driveId: String, directoryId: String) async throws {
        try await Self.performUpload(fileURL: fileURL, token: token, driveId: driveId, directoryId: directoryId)
    }

    nonisolated private static func performUpload(fileURL: URL, token: String, driveId: String, directoryId: String) async throws {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDriveId = driveId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectoryId = trimmedDirectory.isEmpty ? "1" : trimmedDirectory
        guard !cleanToken.isEmpty, !cleanDriveId.isEmpty else { throw KDriveError.invalidConfiguration }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let originalName = fileURL.lastPathComponent
        guard fileSize > 0 else {
            throw KDriveError.uploadFailed(L("Fichier vide (0 octet) : \(originalName)", "Empty file (0 bytes): \(originalName)"))
        }
        // L'upload direct kDrive est limité à 1 Go : au-delà, il faut une
        // session chunkée, non prise en charge par cette version.
        guard fileSize <= 1_000_000_000 else {
            throw KDriveError.uploadFailed(L("Fichier trop volumineux pour l'envoi direct (> 1 Go) : \(originalName)", "File too large for direct upload (> 1 GB): \(originalName)"))
        }
        // Les titres Reddit contiennent souvent `? " * < > | \` : kDrive
        // répond 422 `validation_failed` au lieu d'accepter le nom.
        // On envoie donc un nom assaini, avec une 2e tentative ultra-sûre.
        let safeName = FilenamePolicy.kDriveFileName(originalName)
        do {
            try await Self.performSingleUpload(
                fileURL: fileURL, remoteFileName: safeName, fileSize: fileSize,
                token: cleanToken, driveId: cleanDriveId, directoryId: cleanDirectoryId
            )
        } catch let error as KDriveError {
            if case .serverError(let code, let message) = error, code == 422 {
                let fallback = FilenamePolicy.kDriveFallbackName(for: originalName)
                if fallback != safeName {
                    do {
                        try await Self.performSingleUpload(
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

    nonisolated private static func performSingleUpload(fileURL: URL, remoteFileName: String, fileSize: Int64, token cleanToken: String, driveId cleanDriveId: String, directoryId cleanDirectoryId: String) async throws {
        var components = URLComponents(string: "https://api.infomaniak.com/3/drive/\(cleanDriveId)/upload")
        components?.queryItems = [
            URLQueryItem(name: "directory_id", value: cleanDirectoryId),
            URLQueryItem(name: "file_name", value: remoteFileName),
            URLQueryItem(name: "total_size", value: String(fileSize)),
            URLQueryItem(name: "conflict", value: "version")
        ]
        guard let requestURL = components?.url else { throw KDriveError.invalidURL }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveError.serverError(0, L("Réponse réseau inattendue", "Unexpected network response"))
        }
        if httpResponse.statusCode == 401 { throw KDriveError.authenticationFailed }
        if httpResponse.statusCode == 404 {
            throw KDriveError.uploadFailed(L("Dossier ou Drive introuvable", "Folder or Drive not found"))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw KDriveError.serverError(httpResponse.statusCode, Self.detailedMessage(from: data, statusCode: httpResponse.statusCode, fileName: remoteFileName))
        }
    }

    /// Extrait le détail `error.errors[]` d'Infomaniak au lieu du seul
    /// `error.description` générique (« Validation failed »), en précisant
    /// le fichier concerné pour retrouver les 422 dans un lot de 446.
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

    func uploadBatch(
        files: [URL],
        token: String,
        driveId: String,
        directoryId: String,
        completion: @escaping (_ successCount: Int, _ failedCount: Int, _ errorMessage: String?) -> Void
    ) {
        let configured = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard configured else {
            completion(0, files.count, KDriveError.invalidConfiguration.localizedDescription)
            return
        }

        cancelUpload()
        isUploading = true
        currentProgress = 0
        currentFileIndex = 0
        totalFilesCount = files.count
        currentFileName = ""
        lastError = nil

        activeTask = Task {
            var success = 0
            var failed = 0
            var completed = 0
            var failedExamples: [KDriveUploadOutcome] = []

            let batchSize = Self.concurrentUploadLimit
            var batchStart = 0

            while batchStart < files.count && !Task.isCancelled {
                let batchEnd = min(batchStart + batchSize, files.count)
                let batch = Array(files[batchStart..<batchEnd])

                let outcomes = await withTaskGroup(of: KDriveUploadOutcome.self, returning: [KDriveUploadOutcome].self) { group in
                    for fileURL in batch {
                        group.addTask {
                            if Task.isCancelled {
                                return KDriveUploadOutcome(fileName: fileURL.lastPathComponent, succeeded: false, errorMessage: KDriveError.cancelled.localizedDescription)
                            }
                            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                                return KDriveUploadOutcome(
                                    fileName: fileURL.lastPathComponent,
                                    succeeded: false,
                                    errorMessage: L("Fichier introuvable : \(fileURL.lastPathComponent)", "File not found: \(fileURL.lastPathComponent)")
                                )
                            }
                            do {
                                try await KDriveService.performUpload(
                                    fileURL: fileURL,
                                    token: token,
                                    driveId: driveId,
                                    directoryId: directoryId
                                )
                                return KDriveUploadOutcome(fileName: fileURL.lastPathComponent, succeeded: true, errorMessage: nil)
                            } catch {
                                return KDriveUploadOutcome(fileName: fileURL.lastPathComponent, succeeded: false, errorMessage: error.localizedDescription)
                            }
                        }
                    }

                    var results: [KDriveUploadOutcome] = []
                    for await outcome in group {
                        results.append(outcome)
                    }
                    return results
                }

                if Task.isCancelled { break }

                for outcome in outcomes {
                    completed += 1
                    currentFileIndex = completed
                    currentFileName = outcome.fileName
                    currentProgress = Double(completed) / Double(max(1, files.count))
                    if outcome.succeeded {
                        success += 1
                    } else {
                        failed += 1
                        if failedExamples.count < 5 { failedExamples.append(outcome) }
                    }
                }

                batchStart = batchEnd
            }

            let summaryMessage: String? = {
                guard failed > 0 else { return nil }
                let examples = failedExamples.compactMap { o -> String? in
                    guard let msg = o.errorMessage, !msg.isEmpty else { return o.fileName }
                    return "\(o.fileName) : \(msg)"
                }.joined(separator: "\n")
                let hint = L("Astuce : les noms avec ? \" * < > | \\ / : sont désormais renommés automatiquement à l'envoi. Relance l'upload des fichiers restants après mise à jour.", "Tip: names with ? \" * < > | \\ / : are now renamed automatically on upload. Re-run the upload for the remaining files after updating.")
                return L("\(failed) échec(s) sur \(files.count). Exemples :\n\(examples)\n\(hint)", "\(failed) failure(s) out of \(files.count). Examples:\n\(examples)\n\(hint)")
            }()

            isUploading = false
            activeTask = nil
            lastError = summaryMessage
            if Task.isCancelled {
                completion(success, failed, KDriveError.cancelled.localizedDescription)
            } else {
                currentProgress = files.isEmpty ? 0 : 1
                completion(success, failed, summaryMessage)
            }
        }
    }

    func cancelUpload() {
        activeTask?.cancel()
        activeTask = nil
        isUploading = false
    }
}

struct KDriveUploadButton: View {
    let files: [URL]

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
            if configured { showUpload = true } else { showNotConfigured = true }
        } label: {
            Image(systemName: "icloud.and.arrow.up")
        }
        .disabled(files.isEmpty)
        .accessibilityLabel(L("Envoyer les médias affichés vers kDrive", "Upload displayed media to kDrive"))
        .sheet(isPresented: $showUpload) {
            KDriveUploadFlowSheet(files: files, token: token, driveId: driveId)
        }
        .alert(L("kDrive non configuré", "kDrive is not configured"), isPresented: $showNotConfigured) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(L("Renseigne le token API et l’ID du Drive dans Réglages > Infomaniak kDrive.", "Enter the API token and Drive ID in Settings > Infomaniak kDrive."))
        }
    }
}

private enum KDriveConnectionStatus {
    case success(String)
    case error(String)
}

struct KDriveSettingsSection: View {
    @AppStorage("kDriveApiToken") private var token = ""
    @AppStorage("kDriveId") private var driveId = ""
    @AppStorage("kDriveDirectoryId") private var directoryId = "1"
    @AppStorage("kDriveDirectoryName") private var directoryName = "Racine (kDrive)"

    @State private var showToken = false
    @State private var isTestingConnection = false
    @State private var connectionStatus: KDriveConnectionStatus?
    @State private var showFolderPicker = false

    private var configured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !driveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section {
            HStack {
                Group {
                    if showToken {
                        TextField(L("Token API", "API token"), text: $token)
                    } else {
                        SecureField(L("Token API", "API token"), text: $token)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button { showToken.toggle() } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                Button(L("Coller", "Paste")) {
                    if let value = UIPasteboard.general.string {
                        token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .buttonStyle(.borderless)
            }

            TextField(L("ID du Drive", "Drive ID"), text: $driveId)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button { showFolderPicker = true } label: {
                HStack {
                    Label(directoryName.isEmpty ? L("Racine (kDrive)", "Root (kDrive)") : directoryName, systemImage: "folder.fill")
                    Spacer()
                    Text("ID: \(directoryId)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!configured)

            Button {
                testConnection()
            } label: {
                HStack {
                    if isTestingConnection { ProgressView().controlSize(.small) }
                    Label(L("Tester la connexion", "Test connection"), systemImage: "network")
                }
            }
            .disabled(!configured || isTestingConnection)

            if let status = connectionStatus {
                switch status {
                case .success(let name):
                    Label(L("Connecté : \(name)", "Connected: \(name)"), systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                case .error(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Infomaniak kDrive")
        } footer: {
            Text(L("Le token et l’ID restent enregistrés localement sur cet appareil. Le dossier configuré ici reste disponible comme préférence, mais le dossier d’envoi est choisi à chaque upload.", "The token and ID remain stored locally on this device. The folder configured here remains available as a preference, but the upload destination is chosen for every upload."))
        }
        .sheet(isPresented: $showFolderPicker) {
            KDriveFolderPickerView(
                token: token,
                driveId: driveId,
                directoryId: $directoryId,
                directoryName: $directoryName
            )
        }
        .onChange(of: token) { _ in connectionStatus = nil }
        .onChange(of: driveId) { _ in connectionStatus = nil }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionStatus = nil
        Task {
            do {
                let name = try await KDriveService.shared.testConnection(token: token, driveId: driveId)
                connectionStatus = .success(name)
            } catch {
                connectionStatus = .error(error.localizedDescription)
            }
            isTestingConnection = false
        }
    }
}

private struct KDrivePathNode: Identifiable, Equatable {
    let id: String
    let name: String
}

struct KDriveFolderPickerView: View {
    let token: String
    let driveId: String
    @Binding var directoryId: String
    @Binding var directoryName: String
    let dismissOnSelection: Bool
    let onChoose: ((String, String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var pathStack: [KDrivePathNode] = []
    @State private var folders: [KDriveFolderItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateFolder = false
    @State private var newFolderName = ""

    init(
        token: String,
        driveId: String,
        directoryId: Binding<String>,
        directoryName: Binding<String>,
        dismissOnSelection: Bool = true,
        onChoose: ((String, String) -> Void)? = nil
    ) {
        self.token = token
        self.driveId = driveId
        self._directoryId = directoryId
        self._directoryName = directoryName
        self.dismissOnSelection = dismissOnSelection
        self.onChoose = onChoose
    }

    private var currentFolder: KDrivePathNode {
        pathStack.last ?? KDrivePathNode(id: "1", name: L("Racine", "Root"))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(pathStack.enumerated()), id: \.offset) { index, node in
                                if index > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Button(node.name) { navigateToBreadcrumb(at: index) }
                                    .font(index == pathStack.count - 1 ? .subheadline.bold() : .subheadline)
                            }
                        }
                    }
                }

                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button(L("Réessayer", "Retry")) { loadFolders() }
                    }
                } else {
                    if pathStack.count > 1 {
                        Button { goUpOneLevel() } label: {
                            Label(L("Dossier parent", "Parent folder"), systemImage: "arrow.turn.up.left")
                        }
                    }

                    if folders.isEmpty {
                        Text(L("Aucun sous-dossier ici.", "No subfolders here."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(folders) { folder in
                            Button { enterFolder(folder) } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder.fill")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(dismissOnSelection ? L("Dossier kDrive", "kDrive folder") : L("Choisir le dossier", "Choose folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Annuler", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFolderName = ""
                        showCreateFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel(L("Créer un dossier", "Create folder"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let chosenId = currentFolder.id
                    let chosenName = currentFolder.name
                    directoryId = chosenId
                    directoryName = chosenName
                    onChoose?(chosenId, chosenName)
                    if dismissOnSelection { dismiss() }
                } label: {
                    Text(dismissOnSelection
                         ? L("Choisir « \(currentFolder.name) »", "Choose “\(currentFolder.name)”")
                         : L("Envoyer ici : « \(currentFolder.name) »", "Upload here: “\(currentFolder.name)”"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding()
                .background(.bar)
            }
        }
        .alert(L("Nouveau dossier", "New folder"), isPresented: $showCreateFolder) {
            TextField(L("Nom du dossier", "Folder name"), text: $newFolderName)
            Button(L("Annuler", "Cancel"), role: .cancel) { }
            Button(L("Créer", "Create")) { createNewFolder() }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L("Créer un sous-dossier dans « \(currentFolder.name) ».", "Create a subfolder in “\(currentFolder.name)”."))
        }
        .onAppear {
            if pathStack.isEmpty {
                if dismissOnSelection && directoryId != "1" && !directoryName.isEmpty {
                    pathStack = [
                        KDrivePathNode(id: "1", name: L("Racine", "Root")),
                        KDrivePathNode(id: directoryId, name: directoryName)
                    ]
                } else {
                    pathStack = [KDrivePathNode(id: "1", name: L("Racine", "Root"))]
                }
            }
            loadFolders()
        }
    }

    private func enterFolder(_ folder: KDriveFolderItem) {
        pathStack.append(KDrivePathNode(id: String(folder.id), name: folder.name))
        loadFolders()
    }

    private func goUpOneLevel() {
        guard pathStack.count > 1 else { return }
        pathStack.removeLast()
        loadFolders()
    }

    private func navigateToBreadcrumb(at index: Int) {
        guard index < pathStack.count else { return }
        pathStack = Array(pathStack.prefix(index + 1))
        loadFolders()
    }

    private func loadFolders() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                folders = try await KDriveService.shared.fetchSubdirectories(
                    token: token,
                    driveId: driveId,
                    directoryId: currentFolder.id
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func createNewFolder() {
        let cleanName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let folder = try await KDriveService.shared.createDirectory(
                    token: token,
                    driveId: driveId,
                    parentDirectoryId: currentFolder.id,
                    folderName: cleanName
                )
                pathStack.append(KDrivePathNode(id: String(folder.id), name: folder.name))
                folders = []
                loadFolders()
            } catch {
                errorMessage = L("Échec de création : \(error.localizedDescription)", "Creation failed: \(error.localizedDescription)")
                isLoading = false
            }
        }
    }
}

private struct KDriveUploadFlowSheet: View {
    let files: [URL]
    let token: String
    let driveId: String

    @State private var directoryId = "1"
    @State private var directoryName = L("Racine", "Root")
    @State private var destinationChosen = false

    var body: some View {
        Group {
            if destinationChosen {
                KDriveUploadSheet(
                    files: files,
                    token: token,
                    driveId: driveId,
                    directoryId: directoryId,
                    directoryName: directoryName
                )
            } else {
                KDriveFolderPickerView(
                    token: token,
                    driveId: driveId,
                    directoryId: $directoryId,
                    directoryName: $directoryName,
                    dismissOnSelection: false,
                    onChoose: { _, _ in destinationChosen = true }
                )
            }
        }
    }
}

struct KDriveUploadSheet: View {
    let files: [URL]
    let token: String
    let driveId: String
    let directoryId: String
    let directoryName: String

    @ObservedObject private var service = KDriveService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var finished = false
    @State private var successCount = 0
    @State private var failedCount = 0
    @State private var finalError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
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
                    ProgressView(value: service.currentProgress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal)

                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)

                    Text(L("Envoi vers kDrive…", "Uploading to kDrive…"))
                        .font(.headline)
                    Text(L("\(service.currentFileIndex) sur \(max(1, service.totalFilesCount)) terminé(s)", "\(service.currentFileIndex) of \(max(1, service.totalFilesCount)) completed"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(L("Jusqu’à \(KDriveService.concurrentUploadLimit) fichiers sont envoyés simultanément.", "Up to \(KDriveService.concurrentUploadLimit) files are uploaded simultaneously."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !service.currentFileName.isEmpty {
                        Text(service.currentFileName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal)
                    }
                }

                Spacer()

                Button {
                    if service.isUploading {
                        service.cancelUpload()
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
        .interactiveDismissDisabled(service.isUploading)
        .onAppear { startUploadIfNeeded() }
    }

    private func startUploadIfNeeded() {
        guard !started else { return }
        started = true
        guard !files.isEmpty else {
            finished = true
            return
        }

        service.uploadBatch(files: files, token: token, driveId: driveId, directoryId: directoryId) { success, failed, error in
            successCount = success
            failedCount = failed
            finalError = error
            finished = true
        }
    }
}

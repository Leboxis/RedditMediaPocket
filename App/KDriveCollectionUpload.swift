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
        let trimmed = collectionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Pocket" : trimmed
        // Un slash ne peut pas faire partie d’un nom de dossier. Les variantes
        // Unicode gardent le libellé visuellement identique à la pastille.
        return source
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: "\\", with: "＼")
    }

    var body: some View {
        Group {
            if let uploadDirectoryId {
                KDriveUploadSheet(
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

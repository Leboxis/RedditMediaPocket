import SwiftUI
import MediaCore

private struct Selection: Identifiable {
    let url: URL
    let files: [URL]
    var id: URL { url }
}

/// Onglet **Bibliothèque** : les collections (pastilles) et la galerie des
/// médias téléchargés — recherche, tri, filtre, sélection multiple, aperçu,
/// infos, export, envoi kDrive, suppressions confirmées.
struct LibraryView: View {
    @ObservedObject var model: Downloader
    /// Bascule vers l'onglet Nouveau pour lancer un téléchargement depuis
    /// les sauvegardés ou les comptes suivis.
    let goToDownload: () -> Void
    @State private var selection: Selection?
    @State private var export: ExportSelection?
    @State private var info: MediaInfoSelection?
    @State private var savedPostsPresented = false
    @State private var followingPresented = false
    @State private var collectionPendingDeletion: UserCollection?
    @State private var mediaPendingDeletion: URL?
    @State private var selectingMedia = false
    @State private var selectedMedia: Set<URL> = []
    @State private var bulkDeletePending = false
    @State private var savingToGallery = false
    @State private var gallerySaveMessage: String?
    @FocusState private var editing: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                userChipsRow
                gallerySection
            }
            .background(DS.background)
            .navigationTitle(L("Bibliothèque", "Library"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { savedPostsPresented = true } label: { Image(systemName: "bookmark.fill") }
                        .accessibilityLabel(L("Posts sauvegardés", "Saved posts"))
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { followingPresented = true } label: { Image(systemName: "person.2") }
                        .accessibilityLabel(L("Comptes suivis", "Followed accounts"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { export = ExportSelection(files: model.files) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.files.isEmpty)
                    .accessibilityLabel(L("Exporter les médias affichés", "Export displayed media"))
                }
                // Dernier item de la barre : rangé dans le menu « … » du
                // système, l'envoi vers kDrive y apparaît comme une action à plat.
                ToolbarItem(placement: .navigationBarTrailing) {
                    KDriveCollectionUploadAction(
                        files: model.files,
                        collectionLabel: model.activeCollection.map { ($0.isXFetish || $0.isRedGifs || $0.isTwitter || $0.isTikTok || $0.isInstagram) ? $0.id : $0.name } ?? "Pocket"
                    )
                }
            }
            .sheet(isPresented: $savedPostsPresented) {
                SavedPostsView(model: model) { _ in
                    savedPostsPresented = false
                    goToDownload()
                    model.sourceKind = "saved"
                    model.start()
                }
            }
            .sheet(isPresented: $followingPresented) {
                FollowingView(model: model) { username in
                    followingPresented = false
                    goToDownload()
                    model.download(user: username)
                }
            }
            .fullScreenCover(item: $selection) { item in
                MediaPreview(urls: item.files, selectedURL: item.url)
            }
            .sheet(item: $info) { item in
                MediaInfoView(url: item.url)
            }
            .sheet(item: $export) { item in
                ExportSheet(files: item.files).ignoresSafeArea()
            }
            .confirmationDialog(L("Supprimer les médias téléchargés ?", "Delete downloaded media?"), isPresented: Binding(
                get: { collectionPendingDeletion != nil },
                set: { if !$0 { collectionPendingDeletion = nil } }
            ), titleVisibility: .visible) {
                Button(L("Supprimer", "Delete"), role: .destructive) {
                    guard let collection = collectionPendingDeletion else { return }
                    model.deleteDownloads(for: collection.id)
                    collectionPendingDeletion = nil
                }
                Button(L("Annuler", "Cancel"), role: .cancel) { collectionPendingDeletion = nil }
            } message: {
                Text(L("Tous les médias de \(collectionPendingDeletion?.displayName ?? "cette source") seront définitivement effacés.", "All media from \(collectionPendingDeletion?.displayName ?? "this source") will be permanently deleted."))
            }
            .confirmationDialog(L("Supprimer ce média ?", "Delete this media?"), isPresented: Binding(
                get: { mediaPendingDeletion != nil },
                set: { if !$0 { mediaPendingDeletion = nil } }
            ), titleVisibility: .visible, presenting: mediaPendingDeletion) { url in
                Button(L("Supprimer", "Delete"), role: .destructive) {
                    model.deleteMedia(url)
                    mediaPendingDeletion = nil
                }
                .disabled(model.running)
                Button(L("Annuler", "Cancel"), role: .cancel) { mediaPendingDeletion = nil }
            } message: { url in
                Text(L("\(url.lastPathComponent) sera définitivement supprimé. Les autres médias seront conservés.", "\(url.lastPathComponent) will be permanently deleted. Other media will be kept."))
            }
            .confirmationDialog(L("Supprimer \(selectedMedia.count) média(s) ?", "Delete \(selectedMedia.count) media?"), isPresented: $bulkDeletePending, titleVisibility: .visible) {
                Button(L("Supprimer", "Delete"), role: .destructive) {
                    model.deleteMedia(orderedSelection())
                    exitSelection()
                }
                Button(L("Annuler", "Cancel"), role: .cancel) { }
            } message: {
                Text(L("Ces médias seront définitivement effacés. Les autres seront conservés.", "These media will be permanently deleted. Others will be kept."))
            }
            .errorAlert(gallerySaveMessage) { gallerySaveMessage = nil }
        }
    }

    // MARK: - Collections

    private var userChipsRow: some View {
        Group {
            if !model.collections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.collections.sorted { $0.displayName < $1.displayName }) { collection in
                            userChip(collection)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 10)
                .disabled(model.running)
            }
        }
    }

    private func userChip(_ collection: UserCollection) -> some View {
        let active = model.activeUser == collection.id
        let fresh = model.lastRunCount(for: collection.id)
        return Button { model.selectUser(collection.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: collection.isSaved ? "bookmark.fill" : (collection.isXFetish ? "photo.on.rectangle" : (collection.isRedGifs ? "film" : (collection.isTwitter ? "bird" : (collection.isTikTok ? "music.note" : (collection.isInstagram ? "camera" : (collection.isSubreddit ? "person.3" : "person.crop.circle")))))))
                Text(collection.displayName).lineLimit(1)
                // Ce qui a réellement été ajouté au passage précédent : l'état
                // existait déjà (`lastRun`) mais n'était affiché nulle part.
                if let fresh, fresh > 0, !active {
                    Text("+\(fresh)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DS.accentEmphasis)
                        .monospacedDigit()
                }
                if active { Image(systemName: "checkmark") }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(minHeight: 44)
            .foregroundStyle(active ? DS.onAccent : DS.onSurface)
            .background(active ? DS.accent : DS.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.download(user: collection.id) } label: {
                Label(L("Reprendre le téléchargement", "Resume download"), systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) { collectionPendingDeletion = collection } label: {
                Label(L("Supprimer", "Delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Galerie

    @ViewBuilder private var gallerySection: some View {
        if model.files.isEmpty && model.loadingFiles {
            Spacer()
            ProgressView(L("Chargement de la galerie…", "Loading gallery…"))
            Spacer()
        } else if model.files.isEmpty {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(DS.onSurfaceMuted)
                .accessibilityLabel(L("Galerie vide", "Empty gallery"))
            Text(model.activeCollection.map { L("Aucun média pour \($0.displayName)", "No media for \($0.displayName)") } ?? L("Choisis une source dans l'onglet Nouveau", "Choose a source in the New tab"))
                .font(.footnote).foregroundStyle(DS.onSurfaceMuted).padding(.top, 6)
            Spacer()
        } else {
            galleryToolbar
            if selectingMedia {
                selectionBar
            }
            if model.displayedFiles.isEmpty {
                Spacer()
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 34, weight: .ultraLight)).foregroundStyle(DS.onSurfaceMuted)
                Text(L("Aucun média ne correspond à la recherche.", "No media matches the search."))
                    .font(.footnote).foregroundStyle(DS.onSurfaceMuted).padding(.top, 6)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(model.displayedFiles, id: \.self) { url in
                            thumbnailButton(url)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    /// Une vignette : elle ouvre l'aperçu, ou coche le média quand la
    /// sélection multiple est active.
    private func thumbnailButton(_ url: URL) -> some View {
        let picked = selectedMedia.contains(url)
        return Button {
            if selectingMedia {
                toggleMediaSelection(url)
            } else {
                editing = false
                selection = Selection(url: url, files: model.displayedFiles)
            }
        } label: {
            MediaThumbnail(url: url)
                .overlay(alignment: .topTrailing) {
                    if selectingMedia {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(picked ? DS.accent : Color.white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(isVideo(url) ? L("Ouvrir la vidéo", "Open video") : L("Ouvrir l'image", "Open image"))
        .accessibilityAddTraits(picked && selectingMedia ? .isSelected : [])
        .contextMenu {
            if !selectingMedia {
                Button {
                    selectingMedia = true
                    selectedMedia = [url]
                } label: {
                    Label(L("Sélectionner", "Select"), systemImage: "checkmark.circle")
                }
            }
            Button { info = MediaInfoSelection(url: url) } label: {
                Label(L("Informations du média", "Media information"), systemImage: "info.circle")
            }
            Button(role: .destructive) { mediaPendingDeletion = url } label: {
                Label(L("Supprimer", "Delete"), systemImage: "trash")
            }
            .disabled(model.running)
        }
    }

    /// Barre de la sélection multiple : tout cocher, enregistrer le lot dans
    /// Photos, supprimer le lot, quitter le mode.
    private var selectionBar: some View {
        let allPicked = !model.displayedFiles.isEmpty && selectedMedia.count == model.displayedFiles.count
        return HStack(spacing: 14) {
            Button {
                if allPicked {
                    selectedMedia.removeAll()
                } else {
                    selectedMedia = Set(model.displayedFiles)
                }
            } label: {
                Image(systemName: allPicked ? "checkmark.circle.fill" : "circle.dashed")
            }
            .accessibilityLabel(allPicked ? L("Tout désélectionner", "Deselect all") : L("Tout sélectionner", "Select all"))

            Text(selectedMedia.isEmpty
                 ? L("Sélection", "Selection")
                 : L("\(selectedMedia.count) sélectionné(s)", "\(selectedMedia.count) selected"))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(selectedMedia.isEmpty ? DS.onSurfaceMuted : DS.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { saveSelectionToGallery() } label: {
                if savingToGallery {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .disabled(selectedMedia.isEmpty || savingToGallery)
            .accessibilityLabel(L("Enregistrer la sélection dans Photos", "Save selection to Photos"))

            Button(role: .destructive) { bulkDeletePending = true } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedMedia.isEmpty || model.running)
            .accessibilityLabel(L("Supprimer la sélection", "Delete selection"))

            Button { exitSelection() } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(L("Quitter la sélection", "Exit selection"))
        }
        .font(.system(size: 17, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(DS.surface, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Recherche, tri et filtre rapide de la galerie. Ces réglages ne changent
    /// que l'ordre et la visibilité des fichiers déjà présents, jamais ce qui
    /// est téléchargé.
    private var galleryToolbar: some View {
        GalleryToolbar(model: model)
    }

    /// Ce qui est réellement à l'écran, dans l'ordre de la grille : la
    /// sélection peut survivre à un changement de filtre, on n'agit que sur ce
    /// qui est visible au moment du geste.
    private func orderedSelection() -> [URL] {
        model.displayedFiles.filter { selectedMedia.contains($0) }
    }

    private func toggleMediaSelection(_ url: URL) {
        if selectedMedia.contains(url) {
            selectedMedia.remove(url)
        } else {
            selectedMedia.insert(url)
        }
    }

    private func exitSelection() {
        selectingMedia = false
        selectedMedia.removeAll()
    }

    private func saveSelectionToGallery() {
        let files = orderedSelection()
        guard !files.isEmpty, !savingToGallery else { return }
        savingToGallery = true
        Task { @MainActor in
            defer { savingToGallery = false }
            do {
                try await GallerySave.save(files)
                exitSelection()
            } catch {
                gallerySaveMessage = error.localizedDescription
            }
        }
    }
}

#Preview("Bibliothèque — clair") {
    LibraryView(model: Downloader(), goToDownload: {})
}

#Preview("Bibliothèque — sombre") {
    LibraryView(model: Downloader(), goToDownload: {})
        .preferredColorScheme(.dark)
}

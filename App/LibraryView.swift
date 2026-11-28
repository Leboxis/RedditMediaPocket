import SwiftUI
import MediaCore
import UIKit

private struct Selection: Identifiable {
    let url: URL
    let files: [URL]
    var id: URL { url }
}

/// Onglet **Bibliothèque** : les collections (pastilles) et la galerie des
/// médias téléchargés — recherche, tri, filtre, sélection multiple, aperçu,
/// infos, export, envoi kDrive, suppressions confirmées.
struct LibraryView: View {
    var model: Downloader
    /// Bascule vers l'onglet Nouveau pour lancer un téléchargement depuis
    /// les sauvegardés ou les comptes suivis.
    let goToDownload: () -> Void
    @State private var kDriveFreshness = KDriveFreshnessCenter.shared
    @AppStorage("kDriveApiToken") private var kDriveToken = ""
    @AppStorage("kDriveId") private var kDriveId = ""
    @AppStorage("kDriveDirectoryId") private var kDriveDirectoryId = "1"
    @State private var selection: Selection?
    @State private var export: ExportSelection?
    @State private var info: MediaInfoSelection?
    @State private var savedPostsPresented = false
    @State private var followingPresented = false
    @State private var kDriveStatusPresented = false
    @State private var collectionPendingDeletion: UserCollection?
    @State private var mediaPendingDeletion: URL?
    @State private var selectingMedia = false
    @State private var selectedMedia: Set<URL> = []
    @State private var dragSelection: GalleryDragSelection<URL>?
    @State private var gridWidth: Double = 0
    @State private var bulkDeletePending = false
    @State private var savingToGallery = false
    @State private var gallerySaveMessage: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.gridGap), count: 3)

    private var kDriveConfigured: Bool {
        !kDriveToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !kDriveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var kDriveStatusDotColor: Color? {
        if kDriveFreshness.redCount > 0 { return DS.calmRose }
        if kDriveFreshness.orangeCount > 0 { return DS.calmAmber }
        return nil
    }

    private var visibleSelection: [URL] {
        orderedSelection()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                userChipsRow
                gallerySection
            }
            .background(DS.background)
            .navigationTitle(L("Bibliothèque", "Library"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { savedPostsPresented = true } label: { Image(systemName: "bookmark.fill") }
                        .accessibilityLabel(L("Posts sauvegardés", "Saved posts"))
                    Button { followingPresented = true } label: { Image(systemName: "person.2") }
                        .accessibilityLabel(L("Comptes suivis", "Followed accounts"))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if selectingMedia { exitSelection() } else { selectingMedia = true }
                    } label: {
                        let selectionIcon = selectingMedia ? "checkmark.circle.fill" : "checkmark.circle"
                        Image(systemName: selectionIcon)
                    }
                    .disabled(model.displayedFiles.isEmpty && !selectingMedia)
                    .accessibilityLabel(selectingMedia ? L("Quitter la sélection", "Exit selection") : L("Sélectionner des médias", "Select media"))

                    Button { export = ExportSelection(files: model.files) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.files.isEmpty)
                    .accessibilityLabel(L("Exporter les médias affichés", "Export displayed media"))

                    KDriveCollectionUploadAction(
                        files: model.files,
                        collectionLabel: model.activeCollection?.kDriveLabel ?? "Pocket",
                        collectionID: model.activeCollection?.id
                    )

                    Button {
                        kDriveStatusPresented = true
                    } label: {
                        KDriveStatusIcon(baseSize: 20, statusDotColor: kDriveStatusDotColor)
                    }
                    .accessibilityLabel(L("État kDrive des collections", "kDrive collections status"))
                }
            }
            .onChange(of: model.activeUser) { _, _ in exitSelection() }
            .onChange(of: model.displayedFiles) { _, _ in dragSelection = nil }
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
            .sheet(isPresented: $kDriveStatusPresented) {
                KDriveCollectionsStatusView(model: model) { collection in
                    kDriveStatusPresented = false
                    goToDownload()
                    model.download(user: collection.id)
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
            .confirmationDialog(L("Supprimer \(visibleSelection.count) média(s) ?", "Delete \(visibleSelection.count) media?"), isPresented: $bulkDeletePending, titleVisibility: .visible) {
                Button(L("Supprimer", "Delete"), role: .destructive) {
                    model.deleteMedia(visibleSelection)
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
                    HStack(spacing: DS.space(2)) {
                        ForEach(model.collections, id: \.id) { collection in
                            userChip(collection)
                        }
                    }
                    .padding(.horizontal, DS.space(4))
                }
                .padding(.bottom, DS.space(2))
                .disabled(model.running)
            }
        }
    }

    private func userChip(_ collection: UserCollection) -> some View {
        let active = model.activeUser == collection.id
        let fresh = model.lastRunCount(for: collection.id)
        let driveStatus = kDriveFreshness.status(for: collection.id)
        return Button { model.selectUser(collection.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: collection.icon)
                Text(collection.displayName).lineLimit(1)
                if let driveStatus {
                    if driveStatus.isChecking {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(active ? DS.onAccent : DS.onSurfaceMuted)
                    } else if !driveStatus.isUpToDate {
                        // Calm Tech (Colorimétrie C) : silencieux quand tout est à jour,
                        // point Ambre ou Rose-Corail uniquement en cas d'écart.
                        Circle()
                            .fill(active ? DS.onAccent : driveStatus.tintColor)
                            .frame(width: 6, height: 6)
                    }
                }
                // Ce qui a réellement été ajouté au passage précédent : l'état
                // existait déjà (`lastRun`) mais n'était affiché nulle part.
                if let fresh, fresh > 0, !active {
                    Text("+\(fresh)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DS.calmAmber)
                        .monospacedDigit()
                } else if case .outdated(let newCount, _, _, _) = driveStatus, newCount > 0, !active {
                    Text("+\(newCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DS.calmAmber)
                        .monospacedDigit()
                }
                if active { Image(systemName: "checkmark") }
            }
            .font(DS.caption)
            .padding(.horizontal, DS.space(3)).padding(.vertical, DS.space(2))
            .frame(minHeight: 44)
            .foregroundStyle(active ? DS.onAccent : DS.onSurface)
            .background(active ? DS.accent : DS.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .contextMenu {
            if kDriveConfigured {
                Button {
                    kDriveFreshness.startSingleCheck(
                        collection: collection,
                        model: model,
                        token: kDriveToken,
                        driveId: kDriveId,
                        directoryId: kDriveDirectoryId
                    )
                } label: {
                    Label(L("Vérifier kDrive vs source", "Check kDrive vs source"),
                          systemImage: "arrow.clockwise.icloud")
                }
            }
            Button {
                goToDownload()
                model.download(user: collection.id)
            } label: {
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
            // Skeleton plutôt que spinner : le chargement de la galerie peut
            // dépasser 1 s sur une grosse bibliothèque.
            ScrollView {
                LazyVGrid(columns: columns, spacing: DS.gridGap) {
                    ForEach(0..<12, id: \.self) { _ in
                        DS.surface
                            .aspectRatio(1, contentMode: .fit)
                            .redacted(reason: .placeholder)
                    }
                }
            }
        } else if model.files.isEmpty {
            ContentUnavailableView {
                Label(L("Galerie vide", "Empty gallery"), systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(model.activeCollection.map { L("Aucun média pour \($0.displayName)", "No media for \($0.displayName)") } ?? L("Choisis une source dans l'onglet Nouveau", "Choose a source in the New tab"))
            } actions: {
                Button(L("Choisir une source", "Choose a source")) { goToDownload() }
                    .buttonStyle(DSPrimaryButtonStyle())
            }
        } else {
            galleryToolbar
            if selectingMedia {
                selectionBar
            }
            if model.displayedFiles.isEmpty {
                if model.gallerySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.galleryKindFilter != .all {
                    ContentUnavailableView {
                        Label(L("Aucun résultat pour ce filtre", "No media for this filter"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L("Aucun média de type « \(model.galleryKindFilter.label) » dans cette collection.", "No “\(model.galleryKindFilter.label)” media in this collection."))
                    } actions: {
                        Button(L("Tout afficher", "Show all")) { model.galleryKindFilter = .all }
                            .buttonStyle(DSPrimaryButtonStyle())
                    }
                } else {
                    ContentUnavailableView.search(text: model.gallerySearch)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: DS.gridGap) {
                        ForEach(model.displayedFiles, id: \.self) { url in
                            thumbnailButton(url)
                        }
                    }
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: {
                        gridWidth = $0
                    }
                    .simultaneousGesture(
                        GridHorizontalPanGesture(
                            isEnabled: selectingMedia,
                            onBegan: beginDragSelection,
                            onChanged: updateDragSelection,
                            onEnded: { dragSelection = nil }
                        ),
                        including: selectingMedia ? .all : .subviews
                    )
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
                selection = Selection(url: url, files: model.displayedFiles)
            }
        } label: {
            MediaThumbnail(url: url)
                .overlay(alignment: .topTrailing) {
                    if selectingMedia {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(picked ? DS.accent : DS.onSurface)
                            .shadow(color: DS.shadowColor.opacity(0.5), radius: 2)
                            .padding(DS.space(2))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(selectingMedia
                            ? (isVideo(url) ? L("Sélectionner la vidéo", "Select video") : L("Sélectionner l'image", "Select image"))
                            : (isVideo(url) ? L("Ouvrir la vidéo", "Open video") : L("Ouvrir l'image", "Open image")))
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
        let selectedVisible = visibleSelection
        let allPicked = !model.displayedFiles.isEmpty && selectedVisible.count == model.displayedFiles.count
        return HStack(spacing: DS.space(1)) {
            Button {
                if allPicked {
                    selectedMedia.removeAll()
                } else {
                    selectedMedia = Set(model.displayedFiles)
                }
            } label: {
                Image(systemName: allPicked ? "checkmark.circle.fill" : "circle.dashed")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(allPicked ? L("Tout désélectionner", "Deselect all") : L("Tout sélectionner", "Select all"))

            Text(selectedVisible.isEmpty
                 ? L("Sélection", "Selection")
                 : L("\(selectedVisible.count) sélectionné(s)", "\(selectedVisible.count) selected"))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(selectedVisible.isEmpty ? DS.onSurfaceMuted : DS.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { saveSelectionToGallery() } label: {
                Group {
                    if savingToGallery {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(selectedVisible.isEmpty || savingToGallery)
            .accessibilityLabel(L("Enregistrer la sélection dans Photos", "Save selection to Photos"))

            Button(role: .destructive) { bulkDeletePending = true } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedVisible.isEmpty || model.running)
            .accessibilityLabel(L("Supprimer la sélection", "Delete selection"))

            Button { exitSelection() } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L("Quitter la sélection", "Exit selection"))
        }
        .font(.headline)
        .padding(.horizontal, DS.space(2))
        .background(DS.surfaceElevated, in: Capsule())
        .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space(4))
        .padding(.bottom, DS.space(2))
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
        dragSelection = nil
        selectedMedia.removeAll()
    }

    private func gridIndex(at point: CGPoint, clampToBounds: Bool) -> Int? {
        GalleryDragSelection<URL>.itemIndex(
            x: Double(point.x),
            y: Double(point.y),
            gridWidth: gridWidth,
            columns: columns.count,
            spacing: Double(DS.gridGap),
            count: model.displayedFiles.count,
            clampToBounds: clampToBounds
        )
    }

    private func beginDragSelection(start: CGPoint, current: CGPoint) -> Bool {
        let items = model.displayedFiles
        guard let anchorIndex = gridIndex(at: start, clampToBounds: false),
              var session = GalleryDragSelection(items: items, anchorIndex: anchorIndex, initialSelection: selectedMedia) else {
            dragSelection = nil
            return false
        }
        let targetIndex = gridIndex(at: current, clampToBounds: true) ?? anchorIndex
        session.update(to: targetIndex, items: items, selection: &selectedMedia)
        dragSelection = session
        return true
    }

    private func updateDragSelection(at current: CGPoint) -> Bool {
        guard var session = dragSelection,
              let targetIndex = gridIndex(at: current, clampToBounds: true) else {
            return false
        }
        let changed = session.update(to: targetIndex, items: model.displayedFiles, selection: &selectedMedia)
        dragSelection = session
        return changed
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

/// Reconnaît un glissement horizontal dans `LazyVGrid` sans gêner le défilement
/// vertical du `ScrollView`, l'appui simple ni le menu contextuel des vignettes.
private struct GridHorizontalPanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onBegan: (_ start: CGPoint, _ current: CGPoint) -> Bool
    let onChanged: (_ current: CGPoint) -> Bool
    let onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let current = context.converter.localLocation
        switch recognizer.state {
        case .began:
            let translation = context.converter.localTranslation ?? .zero
            let start = CGPoint(x: current.x - translation.x, y: current.y - translation.y)
            if onBegan(start, current) {
                context.coordinator.feedback.selectionChanged()
            }
        case .changed:
            if onChanged(current) {
                context.coordinator.feedback.selectionChanged()
            }
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let feedback = UISelectionFeedbackGenerator()

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer.isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let horizontal = velocity != .zero
                ? abs(velocity.x) > abs(velocity.y)
                : {
                    let translation = pan.translation(in: pan.view)
                    return abs(translation.x) > abs(translation.y)
                }()
            if horizontal { feedback.prepare() }
            return horizontal
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer.isEnabled else { return false }
            // Laisse défiler verticalement dès qu'un mouvement part haut/bas, mais
            // coupe le pan du ScrollView dès qu'une sélection horizontale s'engage.
            return otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer !== gestureRecognizer
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

#Preview("Bibliothèque — texte accessibility XXL") {
    LibraryView(model: Downloader(), goToDownload: {})
        .dynamicTypeSize(.accessibility3)
}

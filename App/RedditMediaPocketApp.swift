import SwiftUI
import MediaCore

@main @MainActor struct RedditMediaPocketApp: App {
    @UIApplicationDelegateAdaptor(PocketAppDelegate.self) private var appDelegate
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    init() { AppLanguage.initialize(); LegacyBackgroundCleanup.shared.runIfNeeded() }
    var body: some Scene { WindowGroup { ContentView().environment(\.locale, Locale(identifier: language)) } }
}

private struct Selection: Identifiable {
    let url: URL
    let files: [URL]
    var id: URL { url }
}

struct ContentView: View {
    @StateObject private var model = Downloader()
    @ObservedObject private var redditSession = RedditSession.shared
    @ObservedObject private var xSession = XSession.shared
    @ObservedObject private var tikTokSession = TikTokSession.shared
    @ObservedObject private var instagramSession = InstagramSession.shared
    @State private var selection: Selection?
    @State private var export: ExportSelection?
    @State private var info: MediaInfoSelection?
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @State private var settingsPresented = false
    @State private var savedPostsPresented = false
    @State private var followingPresented = false
    @State private var tikTokSavedPresented = false
    @State private var sourceGridPresented = false
    @State private var collectionPendingDeletion: UserCollection?
    @State private var mediaPendingDeletion: URL?
    @State private var filtersPresented = false
    @State private var selectingMedia = false
    @State private var selectedMedia: Set<URL> = []
    @State private var bulkDeletePending = false
    @State private var savingToGallery = false
    @State private var gallerySaveMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var editing: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inputRow
                optionsRow
                sourceHintRow
                userChipsRow
                metricsRow
                transferBarRow
                statusRow
                incompleteBanner
                gallerySection
            }
            // Transition l\u{e9}g\u{e8}re entre les options d'une source et celles d'une
            // autre ; aucune animation si R\u{e9}duire les animations est actif.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.sourceKind)
            .overlay(alignment: .top) {
                KDriveUploadBanner().padding(.top, 8)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.reload() }
                if phase == .background { model.stop() }
            }
            .sheet(isPresented: $settingsPresented) {
                DownloadSettings(model: model)
            }
            .sheet(isPresented: $filtersPresented) {
                DownloadFilterSheet(model: model)
            }
            .sheet(isPresented: $savedPostsPresented) {
                SavedPostsView(model: model) { _ in
                    savedPostsPresented = false
                    model.sourceKind = "saved"
                    model.start()
                }
            }
            .sheet(isPresented: $sourceGridPresented) {
                SourceGridSheet(model: model) {
                    sourceGridPresented = false
                }
            }
            .sheet(isPresented: $tikTokSavedPresented) {
                TikTokSavedPicker(model: model,
                                 onChoose: { choice in
                    tikTokSavedPresented = false
                    model.tikTokSavedChoice = choice
                    model.start()
                }, onAccount: { name in
                    tikTokSavedPresented = false
                    model.sourceKind = "tt"
                    model.username = name
                    model.start()
                })
            }
            .sheet(isPresented: $followingPresented) {
                FollowingView(model: model) { username in
                    followingPresented = false
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
            .alert("Pocket", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .tint(.orange)
            .errorAlert(gallerySaveMessage) { gallerySaveMessage = nil }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            SourceKindButton(kind: SourceKind(rawValue: model.sourceKind) ?? .user) {
                guard !model.running else { return }
                sourceGridPresented = true
            }
            if model.sourceKind == "saved" {
                Spacer()
            } else {
                TextField(model.sourceKind == "r" ? L("sub, ou lien de post", "sub, or post link") :
                          (model.sourceKind == "rg" ? L("pseudo, #tag ou lien", "username, #tag or link") :
                            (model.sourceKind == "x" ? L("nom, lien vidéo/album", "name, video/album link") :
                              (model.sourceKind == "tw" ? L("compte X", "X account") :
                                (model.sourceKind == "tt" ? L("compte TikTok", "TikTok account") :
                                  (model.sourceKind == "ig" ? L("compte Instagram", "Instagram account") : L("pseudo", "username")))))), text: $model.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).focused($editing)
                    .disabled(model.running)
                    .onSubmit { start() }
                    .padding(13)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            Button {
                if model.running { model.stop() } else { start() }
            } label: {
                Image(systemName: model.running ? "stop.fill" : "arrow.down")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.white)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(model.running ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .offset(x: 3, y: -3)
                            .accessibilityLabel(L("Téléchargement", "Download"))
                            .accessibilityValue(model.running ? L("En cours", "In progress") : L("Inactif", "Inactive"))
                    }
            }
            .disabled(cannotStart)
            .accessibilityLabel(model.running ? L("Arrêter", "Stop") : L("Télécharger", "Download"))
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var cannotStart: Bool {
        guard !model.running else { return false }
        if model.sourceKind == "ts" { return !tikTokSession.hasSession || tikTokSession.clearing }
        if model.sourceKind == "saved" { return !redditSession.hasSession || redditSession.clearing }
        if model.username.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        // Les trois sessions sont distinctes : X et TikTok ne se connectent
        // pas avec le compte Reddit.
        if isTwitterInput { return !xSession.hasSession || xSession.clearing }
        if isTikTokInput { return !tikTokSession.hasSession || tikTokSession.clearing }
        return model.needsSession && (!redditSession.hasSession || redditSession.clearing)
    }

    private var isSubredditInput: Bool {
        if let source = model.resolvedSource, case .subreddit = source { return true }
        return false
    }

    private var isXFetishInput: Bool {
        if let source = model.resolvedSource, case .xFetish = source { return true }
        return false
    }

    /// Options de la source sélectionnée : une seule rangée, dont le contenu
    /// ne montre que ce qui concerne la source en cours. Le remplacement
    /// s'anime avec le changement de source (hauteur + opacité, 200 ms), sauf
    /// si Réduire les animations est actif.
    @ViewBuilder private var optionsRow: some View {
        if isSubredditInput {
            Picker(L("Tri du subreddit", "Subreddit sort"), selection: $model.subSort) {
                Text(L("Nouveaux", "New")).tag("new")
                Text(L("Chauds", "Hot")).tag("hot")
                Text(L("Top du mois", "Top this month")).tag("top")
            }
            .pickerStyle(.segmented)
            .disabled(model.running)
            .padding(.horizontal, 16).padding(.bottom, 10)
            .accessibilityLabel(L("Tri du subreddit", "Subreddit sort"))
        } else if isXFetishInput {
            Picker(L("Médias X-Fetish", "X-Fetish media"), selection: $model.xFetishMediaKind) {
                Text(L("Images", "Images")).tag(XFetishMediaKind.images)
                Text(L("Vidéos", "Videos")).tag(XFetishMediaKind.videos)
                Text(L("Les deux", "Both")).tag(XFetishMediaKind.both)
            }
            .pickerStyle(.segmented)
            .disabled(model.running)
            .padding(.horizontal, 16).padding(.bottom, 10)
            .accessibilityLabel(L("Médias X-Fetish", "X-Fetish media"))
        } else if model.sourceKind == "ts" {
            Label(L("Les dossiers de favoris TikTok sont proposés au lancement.", "TikTok favorites folders are offered when starting."),
                  systemImage: "folder.badge.clock")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18).padding(.bottom, 10)
        }
    }

    private var isTwitterInput: Bool {
        if let source = model.resolvedSource, case .twitterUser = source { return true }
        // Le sélecteur reste pertinent tant que le champ X est vide/invalide.
        return model.resolvedSource == nil && model.sourceKind == "tw"
    }

    private var isTikTokInput: Bool {
        if let source = model.resolvedSource, case .tiktokUser = source { return true }
        // Le sélecteur reste pertinent tant que le champ TikTok est vide/invalide.
        return model.resolvedSource == nil && model.sourceKind == "tt"
    }

    @ViewBuilder private var sourceHintRow: some View {
        if isTwitterInput && !xSession.hasSession {
            Label(L("Compte X : connecte-toi à X dans les Réglages. Sans session, X ne publie aucun média.", "X account: sign in to X in Settings. Without a session, X publishes no media."),
                  systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18).padding(.bottom, 10)
        } else if isTikTokInput && !tikTokSession.hasSession {
            Label(L("Compte TikTok : connecte-toi à TikTok dans les Réglages. Sans session, TikTok ne publie aucun média.", "TikTok account: sign in to TikTok in Settings. Without a session, TikTok publishes no media."),
                  systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18).padding(.bottom, 10)
        } else if model.sourceKind == "ts" && !tikTokSession.hasSession {
            Label(L("Sauvegardés TikTok : connecte-toi à TikTok dans les Réglages. Sans session, impossible de lire les publications enregistrées du compte.", "TikTok saved: sign in to TikTok in Settings. Without a session, the account's saved posts cannot be read."),
                  systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18).padding(.bottom, 10)
        } else if !isTwitterInput && !isTikTokInput && model.sourceKind != "ts" && model.needsSession && !redditSession.hasSession {
            Label(L("Sauvegardés : connecte-toi à Reddit dans les Réglages. Le compte sera sélectionné automatiquement.", "Saved: sign in to Reddit in Settings. Your account will be selected automatically."), systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18).padding(.bottom, 10)
        }
    }

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

    private var metricsRow: some View {
        // Les 3 slots sont toujours rendus (opacity) pour ne pas redistribuer
        // les largeurs quand « repérés » apparaît en cours de run.
        let showProgress = model.running || model.discovered > 0
        return HStack(spacing: 0) {
            metric("\(model.files.count)", label: L("médias", "media"))
            metric(model.totalSize, label: "")
            metric("\(model.count)/\(model.discovered)", label: L("repérés", "found"))
                .opacity(showProgress ? 1 : 0)
                .accessibilityHidden(!showProgress)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// Avancé du transfert en cours. X-Fetish seulement : son parcours n'a pas
    /// de curseur ni de total annoncé, la barre porte donc sur l'unité en cours
    /// (un album, une page de vidéos), dont le nombre de médias est connu.
    @ViewBuilder private var transferBarRow: some View {
        if let unit = model.transferUnit, (isXFetishInput || isTwitterInput || isTikTokInput), model.running, unit.total > 0 {
            ProgressView(value: unit.fraction)
                .progressViewStyle(.linear)
                .tint(.orange)
                .padding(.horizontal, 16).padding(.bottom, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isTikTokInput ? L("Téléchargement TikTok", "TikTok download")
                                    : (isTwitterInput ? L("Téléchargement X", "X download") : L("Téléchargement X-Fetish", "X-Fetish download")))
                .accessibilityValue("\(unit.done)/\(unit.total)")
        }
    }

    @ViewBuilder private var statusRow: some View {
        if !model.status.isEmpty {
            Text(model.status)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }

    /// Le parcours n'a pas atteint la fin du contenu : le budget de pages a été
    /// consommé et il reste des pages à voir. Ce n'est pas une erreur — rien
    /// n'est perdu, une relance reprend où le parcours s'était arrêté — mais il
    /// faut le dire assez fort pour qu'on ne croie pas l'archive complète.
    @ViewBuilder private var incompleteBanner: some View {
        if model.scanIncomplete {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                Text(L("Archive incomplète : le parcours a atteint sa limite de pages. Relance pour continuer.",
                       "Incomplete archive: the scan reached its page limit. Relaunch to continue."))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var gallerySection: some View {
        if model.files.isEmpty && model.loadingFiles {
            Spacer()
            ProgressView(L("Chargement de la galerie…", "Loading gallery…"))
            Spacer()
        } else if model.files.isEmpty {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
                .accessibilityLabel(L("Galerie vide", "Empty gallery"))
            Text(model.activeCollection.map { L("Aucun média pour \($0.displayName)", "No media for \($0.displayName)") } ?? L("Choisis une source (u/, r/, RG, ♥, x/, tw/ ou tt/)", "Choose a source (u/, r/, RG, ♥, x/, tw/ or tt/)"))
                .font(.footnote).foregroundStyle(.tertiary).padding(.top, 6)
            Spacer()
        } else {
            galleryToolbar
            if selectingMedia {
                selectionBar
            }
            if model.displayedFiles.isEmpty {
                Spacer()
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.tertiary)
                Text(L("Aucun média ne correspond à la recherche.", "No media matches the search."))
                    .font(.footnote).foregroundStyle(.tertiary).padding(.top, 6)
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
                            .foregroundStyle(picked ? Color.orange : Color.white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(isVideo(url) ? L("Ouvrir la vidéo", "Open video") : L("Ouvrir l’image", "Open image"))
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
                .foregroundStyle(selectedMedia.isEmpty ? Color.secondary : Color.primary)
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
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Recherche, tri et filtre rapide de la galerie. Ces réglages ne changent
    /// que l'ordre et la visibilité des fichiers déjà présents, jamais ce qui
    /// est téléchargé — d'où leur place ici plutôt que dans les Réglages.
    private var galleryToolbar: some View {
        GalleryToolbar(model: model)
    }

    private var toolbarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(L("Réglages", "Settings"))
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button { savedPostsPresented = true } label: { Image(systemName: "bookmark.fill") }
                    .accessibilityLabel(L("Posts sauvegardés", "Saved posts"))
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button { followingPresented = true } label: { Image(systemName: "person.2") }
                    .accessibilityLabel(L("Comptes suivis", "Followed accounts"))
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button { filtersPresented = true } label: {
                    Image(systemName: model.downloadFilter.isActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .disabled(model.running)
                .accessibilityLabel(L("Filtres de téléchargement", "Download filters"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                LogsButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                FailureJournalButton(model: model)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { export = ExportSelection(files: model.files) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.files.isEmpty)
                .accessibilityLabel(L("Exporter les médias affichés", "Export displayed media"))
            }
            // Dernier item de la barre : rangé dans le menu « … » du système,
            // l'envoi vers kDrive y apparaît comme une action à plat.
            ToolbarItem(placement: .navigationBarTrailing) {
                KDriveCollectionUploadAction(
                    files: model.files,
                    collectionLabel: model.activeCollection.map { ($0.isXFetish || $0.isRedGifs || $0.isTwitter || $0.isTikTok || $0.isInstagram) ? $0.id : $0.name } ?? "Pocket"
                )
            }
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(value).fontWeight(.medium).monospacedDigit()
            if !label.isEmpty { Text(label) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity)
    }

    private func userChip(_ collection: UserCollection) -> some View {
        let active = model.activeUser == collection.id
        let fresh = model.lastRunCount(for: collection.id)
        return Button { model.selectUser(collection.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: collection.isSaved ? "bookmark.fill" : (collection.isXFetish ? "photo.on.rectangle" : (collection.isRedGifs ? "film" : (collection.isTwitter ? "bird" : (collection.isTikTok ? "music.note" : (collection.isInstagram ? "camera" : (collection.isSubreddit ? "person.3" : "person.crop.circle")))))))
                Text(collection.displayName).lineLimit(1)
                // Ce qui a été réellement ajouté au passage précédent : l'état
                // existait déjà (`lastRun`) mais n'était affiché nulle part.
                if let fresh, fresh > 0, !active {
                    Text("+\(fresh)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
                if active { Image(systemName: "checkmark") }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(minHeight: 44)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? Color.orange : Color(uiColor: .secondarySystemBackground), in: Capsule())
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

    private func start() {
        guard !model.running else { return }
        editing = false
        // Sauvegardés TikTok : choisir d'abord entre toutes les publications
        // enregistrées et un dossier de favoris du compte connecté.
        if model.sourceKind == "ts" {
            tikTokSavedPresented = true
            return
        }
        model.start()
    }
}

/// Source : face, libellé parlé et session requise — partagés par la
/// pastille et la feuille-grille. Les deux entrées TikTok sont
/// volontairement différenciées : compte public (`tt`, icône note de
/// musique) et sauvegardés du compte connecté (`ts`, icône marque-page),
/// avec des micro-libellés distincts.
private enum SourceSelection {
    static let order: [SourceKind] = [.user, .subreddit, .redGifs, .saved,
                                      .xFetish, .twitter, .tiktok, .tiktokSaved, .instagram]

    static func face(_ kind: SourceKind) -> String {
        switch kind {
        case .user: return "u/"
        case .subreddit: return "r/"
        case .redGifs: return "RG"
        case .saved: return "\u{2665}"
        case .xFetish: return "x/"
        case .twitter: return "tw"
        case .tiktok: return "tt"
        case .tiktokSaved: return "ts"
        case .instagram: return "ig"
        }
    }

    static func icon(_ kind: SourceKind) -> String {
        switch kind {
        case .user: return "person.crop.circle"
        case .subreddit: return "bubble.left.and.bubble.right"
        case .redGifs: return "film"
        case .saved: return "heart.fill"
        case .xFetish: return "flame"
        case .twitter: return "at"
        case .tiktok: return "music.note"
        case .tiktokSaved: return "bookmark.fill"
        case .instagram: return "camera"
        }
    }

    static func spoken(_ kind: SourceKind) -> String {
        switch kind {
        case .user: return L("profil Reddit", "Reddit profile")
        case .subreddit: return "subreddit"
        case .redGifs: return "RedGifs"
        case .saved: return L("sauvegard\u{e9}s Reddit", "Reddit saved")
        case .xFetish: return L("profil X-Fetish", "X-Fetish profile")
        case .twitter: return L("compte X", "X account")
        case .tiktok: return L("compte TikTok", "TikTok account")
        case .tiktokSaved: return L("sauvegard\u{e9}s TikTok \u{2014} compte, collections ou tout le sauvegard\u{e9}", "TikTok saved \u{2014} account, collections or all saved posts")
        case .instagram: return L("compte Instagram", "Instagram account")
        }
    }

    /// Haptique l\u{e9}ger de s\u{e9}lection : signal utile, sans vibration envahissante.
    static func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// Pastille compacte de la source en cours : un appui ouvre la feuille-grille
/// de toutes les sources. Remplace l'ancien bouton \u{e0} cycle, o\u{f9} la bonne
/// source pouvait exiger jusqu'\u{e0} huit appuis.
private struct SourceKindButton: View {
    let kind: SourceKind
    let open: () -> Void

    var body: some View {
        Button {
            SourceSelection.haptic()
            open()
        } label: {
            Text(SourceSelection.face(kind))
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 52, height: 48)
                .foregroundStyle(.orange)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Source : \(SourceSelection.spoken(kind)). Touchez pour choisir parmi toutes les sources.", "Source: \(SourceSelection.spoken(kind)). Tap to choose among all sources."))
    }
}

/// Feuille-grille des sources : neuf choix d\u{e9}couvrables d'un coup d'\u{158}il, un
/// appui pour choisir. Le point orange signale une session manquante pour la
/// source ; les deux entr\u{e9}es TikTok y sont visuellement diff\u{e9}renci\u{e9}es
/// (`tt` compte public, `ts` sauvegard\u{e9}s du compte connect\u{e9}).
private struct SourceGridSheet: View {
    @ObservedObject var model: Downloader
    @ObservedObject private var reddit = RedditSession.shared
    @ObservedObject private var xSession = XSession.shared
    @ObservedObject private var tikTokSession = TikTokSession.shared
    let onPick: () -> Void
    @Environment(\.dismiss) private var dismiss

    private func sessionMissing(_ kind: SourceKind) -> Bool {
        switch kind {
        case .saved: return !reddit.hasSession
        case .twitter: return !xSession.hasSession
        case .tiktok, .tiktokSaved: return !tikTokSession.hasSession
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(L("T\u{e9}l\u{e9}charger depuis\u{2026}", "Download from\u{2026}"))
                    .font(.subheadline.weight(.semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(SourceSelection.order, id: \.rawValue) { kind in
                        SourceGridCard(kind: kind,
                                       isCurrent: model.sourceKind == kind.rawValue,
                                       sessionMissing: sessionMissing(kind)) {
                            SourceSelection.haptic()
                            model.sourceKind = kind.rawValue
                            onPick()
                        }
                    }
                }
                Label(L("Point orange : connexion requise dans les R\u{e9}glages.", "Orange dot: sign-in required in Settings."),
                      systemImage: "circle.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .presentationDetents([.height(420)])
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(L("Fermer", "Close")) { dismiss() }
            }
        }
    }
}

private struct SourceGridCard: View {
    let kind: SourceKind
    let isCurrent: Bool
    let sessionMissing: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: SourceSelection.icon(kind))
                        .font(.system(size: 20, weight: .semibold))
                    if sessionMissing {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                            .offset(x: 4, y: -6)
                            .accessibilityLabel(L("Connexion requise", "Sign-in required"))
                    }
                }
                Text(SourceSelection.face(kind))
                    .font(.system(size: 15, weight: .semibold))
                Text(SourceSelection.spoken(kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 30)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isCurrent ? .orange : .primary)
            .background(isCurrent ? Color.orange.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isCurrent ? .orange : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SourceSelection.spoken(kind))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

private struct DownloadSettings: View {
    @ObservedObject var model: Downloader
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @ObservedObject private var reddit = RedditSession.shared
    @ObservedObject private var xSession = XSession.shared
    @ObservedObject private var tikTokSession = TikTokSession.shared
    @ObservedObject private var instagramSession = InstagramSession.shared
    @State private var loginPresented = false
    @State private var xLoginPresented = false
    @State private var tikTokLoginPresented = false
    @State private var instagramLoginPresented = false
    @State private var confirmDeleteAll = false
    @State private var diagnosticsPresented = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Langue", "Language"), selection: $language) {
                        Text("Français").tag("fr")
                        Text("English").tag("en")
                    }
                    .disabled(model.running)
                } footer: {
                    Text(L("Détectée automatiquement au premier lancement. Modifiable ici.", "Detected automatically on first launch. You can change it here."))
                }
                Section {
                    Stepper(value: $model.concurrentLimit, in: 1...ConcurrentDownloads.maximumLimit) {
                        HStack {
                            Text(L("Téléchargements simultanés", "Concurrent downloads"))
                            Spacer()
                            Text("\(model.concurrentLimit)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(model.running ? L("Appliqué au prochain lancement. En cours : \(model.sessionLimit).", "Applies to the next run. Current: \(model.sessionLimit).") : L("1 à 16. Par défaut : 10 pour toutes les sources. Un nombre élevé peut augmenter les limitations du serveur.", "1 to 16. Defaults: 10 for all sources. Higher values may increase server rate limiting."))
                }
                Section {
                    Picker(L("Morceaux par vidéo", "Parts per video"), selection: $model.xFetishSegments) {
                        ForEach(XFetishRangeDownload.segmentOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityValue("\(model.xFetishSegments)")
                } header: {
                    Text("X-Fetish")
                } footer: {
                    Text(L("Vidéos uniquement. 24 morceaux et 6 téléchargements simultanés par défaut. Repli automatique en connexion unique si nécessaire. Plus de morceaux peut augmenter les refus 403/429.", "Videos only. 24 parts and 6 concurrent downloads by default. Falls back to a single connection when needed. More parts may increase 403/429 refusals."))
                    if model.running {
                        Text(L("Appliqué au prochain lancement. En cours : \(model.sessionSegments).", "Applies to the next run. Current: \(model.sessionSegments)."))
                    }
                }
                Section {
                    RedditSessionIndicator()
                    Button(reddit.hasSession ? L("Session détectée · ouvrir Reddit", "Session detected · open Reddit") : L("Se connecter à Reddit", "Sign in to Reddit")) { loginPresented = true }
                        .disabled(model.running || reddit.clearing)
                    Button(L("Déconnexion", "Sign out"), role: .destructive) { Task { await reddit.logout() } }
                        .disabled(model.running || reddit.clearing)
                } header: {
                    Text("Reddit")
                } footer: {
                    Text(model.running ? L("Arrête les transferts pour modifier la session.", "Stop downloads to change the session.") : L("Session locale. Les limites Reddit restent applicables.", "Local session. Reddit rate limits still apply."))
                }
                Section {
                    XSessionIndicator()
                    Button(xSession.hasSession ? L("Ouvrir X", "Open X") : L("Se connecter à X", "Sign in to X")) { xLoginPresented = true }
                        .disabled(model.running || xSession.clearing)
                    Button(L("Déconnexion", "Sign out"), role: .destructive) { Task { await xSession.logout() } }
                        .disabled(model.running || xSession.clearing)
                } header: {
                    Text("X")
                } footer: {
                    Text(model.running ? L("Arrête les transferts pour modifier la session.", "Stop downloads to change the session.")
                         : L("Session distincte de Reddit, requise par la source tw. X ne publie aucun média sans elle. Ses limites serveur restent applicables.", "A session separate from Reddit, required by the tw source. X publishes no media without it. Its rate limits still apply."))
                }
                Section {
                    TikTokSessionIndicator()
                    Button(tikTokSession.hasSession ? L("Ouvrir TikTok", "Open TikTok") : L("Se connecter à TikTok", "Sign in to TikTok")) { tikTokLoginPresented = true }
                        .disabled(model.running || tikTokSession.clearing)
                    Button(L("Déconnexion", "Sign out"), role: .destructive) { Task { await tikTokSession.logout() } }
                        .disabled(model.running || tikTokSession.clearing)
                } header: {
                    Text("TikTok")
                } footer: {
                    Text(model.running ? L("Arrête les transferts pour modifier la session.", "Stop downloads to change the session.")
                         : L("Session distincte de Reddit et de X, requise par la source tt. TikTok ne publie aucun média sans elle. Ses limites serveur restent applicables.", "A session separate from Reddit and X, required by the tt source. TikTok publishes no media without it. Its rate limits still apply."))
                }
                Section {
                    InstagramSessionIndicator()
                    Button(instagramSession.hasSession ? L("Ouvrir Instagram", "Open Instagram") : L("Se connecter à Instagram", "Sign in to Instagram")) { instagramLoginPresented = true }
                        .disabled(model.running || instagramSession.clearing)
                    Button(L("Déconnexion", "Sign out"), role: .destructive) { Task { await instagramSession.logout() } }
                        .disabled(model.running || instagramSession.clearing)
                } header: {
                    Text("Instagram")
                } footer: {
                    Text(model.running ? L("Arrête les transferts pour modifier la session.", "Stop downloads to change the session.")
                         : L("Session distincte de Reddit, de X et de TikTok. Sans elle, Instagram limite les requêtes anonymes et ne livre que les images des douze dernières publications ; avec elle, les vidéos et l'historique complet sont accessibles. Ses limites serveur restent applicables.", "A session separate from Reddit, X and TikTok. Without it, Instagram rate-limits anonymous requests and only serves the images of the twelve latest posts; with it, videos and the full history are available. Its server limits still apply."))
                }
                KDriveSettingsSection()
                Section {
                    Button(L("Test de santé des sources", "Source health check")) { diagnosticsPresented = true }
                } header: {
                    Text(L("Diagnostic", "Diagnostics"))
                } footer: {
                    Text(L("Interroge chaque source configurée et dit ce qui marche : flux public Reddit, jeton RedGifs, sessions X et TikTok, API Instagram, site X-Fetish.", "Queries each configured source and reports what works: Reddit public feed, RedGifs token, X and TikTok sessions, Instagram API, X-Fetish site."))
                }
                Section {
                    Picker(L("Espace disque maximal", "Maximum disk space"), selection: Binding(
                        get: { StorageQuota.gigabytes(for: model.storageQuota.bytes) },
                        set: { model.storageQuota = StorageQuota(bytes: Int64($0) * StorageQuota.bytesPerGB) }
                    )) {
                        ForEach(StorageQuota.optionsGB, id: \.self) { gb in
                            Text(StorageQuota.label(gb: gb)).tag(gb)
                        }
                    }
                    .disabled(model.running)
                } header: {
                    Text(L("Stockage", "Storage"))
                } footer: {
                    Text(model.running
                         ? L("Appliqué au prochain lancement.", "Applies to the next run.")
                         : L("Le parcours s'arrête proprement quand le plafond est atteint ; les médias déjà téléchargés restent en place. Le plafond porte sur la collection en cours.", "The scan stops cleanly once the limit is reached; media already downloaded stay in place. The limit applies to the current collection."))
                }
                Section {
                    Button(L("Supprimer tous les téléchargements", "Delete all downloads"), role: .destructive) { confirmDeleteAll = true }
                        .disabled(model.running)
                        .foregroundStyle(.red)
                } footer: {
                    Text(L("Efface les médias et les archives de tous les utilisateurs. Irréversible.", "Deletes media and archives for all users. Cannot be undone."))
                }
            }
            .fullScreenCover(isPresented: $loginPresented) { RedditLogin() }
            .fullScreenCover(isPresented: $xLoginPresented) { XLogin() }
            .fullScreenCover(isPresented: $tikTokLoginPresented) { TikTokLogin() }
            .fullScreenCover(isPresented: $instagramLoginPresented) { InstagramLogin() }
            .sheet(isPresented: $diagnosticsPresented) { SourceDiagnosticsView() }
            .confirmationDialog(L("Supprimer tous les téléchargements ?", "Delete all downloads?"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button(L("Tout supprimer", "Delete all"), role: .destructive) { model.deleteAllDownloads() }
                Button(L("Annuler", "Cancel"), role: .cancel) { }
            } message: {
                Text(L("Tous les médias téléchargés seront définitivement effacés.", "All downloaded media will be permanently deleted."))
            }
            .navigationTitle(L("Réglages", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .tint(.orange)
    }
}

/// Choix des sauvegardés TikTok : toutes les publications enregistrées du
/// compte connecté, ou un dossier de favoris détecté sur la page
/// Sauvegardés (`collection_list`, signé par TikTok). La liste peut être
/// vide : TikTok ne la charge pas toujours sans interaction, et le choix
/// « toutes les publications enregistrées » reste proposé — le parcours
/// expliquera en journal ce que la page aura réellement servi.
struct TikTokSavedPicker: View {
    @ObservedObject var model: Downloader
    /// Trois cibles diff\u{e9}renci\u{e9}es, affich\u{e9}es en sections distinctes :
    /// tout le sauvegard\u{e9} du compte connect\u{e9}, un dossier de favoris
    /// (collection), ou un compte TikTok public pr\u{e9}cis.
    let onChoose: (TikTokSavedCollection?) -> Void
    let onAccount: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var accountName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(L("Toutes les publications enregistr\u{e9}es du compte connect\u{e9}", "All saved posts of the signed-in account"),
                          systemImage: "square.grid.2x2")
                        .font(.subheadline)
                    Button {
                        onChoose(nil)
                    } label: {
                        Label(L("Tout t\u{e9}l\u{e9}charger", "Download all"),
                              systemImage: "arrow.down.circle.fill")
                    }
                } header: {
                    Text(L("Sauvegard\u{e9}s globaux", "Global saved posts"))
                }
                Section {
                    if model.tikTokSavedCollections.isEmpty {
                        Label(L("Aucun dossier d\u{e9}t\u{e9}ct\u{e9} pour l\u{2019}instant. TikTok ne les charge pas toujours sans interaction : rel\u{e8}ve la feuille pour r\u{e9}essayer.", "No folder detected so far. TikTok does not always load them without interaction: pull to refresh and retry."),
                              systemImage: "questionmark.folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.tikTokSavedCollections) { folder in
                            Button {
                                onChoose(folder)
                            } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                    Spacer()
                                    Text(verbatim: "\(folder.itemCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(L("Collections (dossiers de favoris)", "Collections (favorites folders)"))
                }
                Section {
                    Label(L("M\u{e9}dias publics d\u{2019}un compte TikTok pr\u{e9}cis, sans lien avec les sauvegard\u{e9}s.", "Public media of a specific TikTok account, unrelated to saved posts."),
                          systemImage: "music.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField(L("compte TikTok", "TikTok account"), text: $accountName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            if let name = try? TikTokAPI.username(accountName), !name.isEmpty {
                                onAccount(name)
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        .disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text(L("Un compte pr\u{e9}cis (comme tt)", "A specific account (like tt)"))
                }
                if let error = model.tikTokSavedListError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(L("TikTok \u{2014} quoi t\u{e9}l\u{e9}charger ?", "TikTok \u{2014} what to download?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Annuler", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Actualiser", "Refresh")) {
                        Task { await model.loadTikTokSavedCollections() }
                    }
                    .disabled(model.tikTokSavedLoading)
                }
            }
            .overlay {
                if model.tikTokSavedLoading {
                    ProgressView(L("Recherche des collections et des sauvegard\u{e9}s\u{2026}", "Looking for collections and saved posts\u{2026}"))
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                await model.loadTikTokSavedCollections()
            }
            .refreshable {
                await model.loadTikTokSavedCollections()
            }
        }
    }
}

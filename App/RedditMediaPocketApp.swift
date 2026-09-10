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
    @State private var selection: Selection?
    @State private var export: ExportSelection?
    @State private var info: MediaInfoSelection?
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @State private var settingsPresented = false
    @State private var followingPresented = false
    @State private var collectionPendingDeletion: UserCollection?
    @State private var mediaPendingDeletion: URL?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var editing: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inputRow
                sortRow
                savedHintRow
                userChipsRow
                metricsRow
                if !model.limitNotice.isEmpty { limitBanner }
                gallerySection
            }
            .navigationTitle("Pocket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.reload() }
                if phase == .background { model.stop() }
            }
            .sheet(isPresented: $settingsPresented) {
                DownloadSettings(model: model)
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
            .alert("Pocket", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .tint(.orange)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            SourceKindToggle(kind: $model.sourceKind)
                .disabled(model.running)
            if model.sourceKind == "saved" {
                Spacer()
            } else {
                TextField(model.sourceKind == "r" ? L("nom du sub", "subreddit name") : L("pseudo", "username"), text: $model.username)
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
            }
            .disabled(cannotStart)
            .accessibilityLabel(model.running ? L("Arrêter", "Stop") : L("Télécharger", "Download"))
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var cannotStart: Bool {
        guard !model.running else { return false }
        if model.sourceKind == "saved" { return !redditSession.hasSession || redditSession.clearing }
        if model.username.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return model.needsSession && !redditSession.hasSession
    }

    private var isSubredditInput: Bool {
        if let source = model.resolvedSource, case .subreddit = source { return true }
        return false
    }

    @ViewBuilder private var sortRow: some View {
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
        }
    }

    @ViewBuilder private var savedHintRow: some View {
        if model.needsSession && !redditSession.hasSession {
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

    private var limitBanner: some View {
        Label(model.limitNotice, systemImage: "clock")
            .font(.caption).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18).padding(.bottom, 10)
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
            Text(model.activeCollection.map { L("Aucun média pour \($0.displayName)", "No media for \($0.displayName)") } ?? L("Choisis une source (u/, r/ ou ♥)", "Choose a source (u/, r/ or ♥)"))
                .font(.footnote).foregroundStyle(.tertiary).padding(.top, 6)
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(model.files, id: \.self) { url in
                        Button { editing = false; selection = Selection(url: url, files: model.files) } label: {
                            MediaThumbnail(url: url)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel(isVideo(url) ? L("Ouvrir la vidéo", "Open video") : L("Ouvrir l’image", "Open image"))
                        .contextMenu {
                            Button { info = MediaInfoSelection(url: url) } label: {
                                Label(L("Informations du média", "Media information"), systemImage: "info.circle")
                            }
                            Button(role: .destructive) { mediaPendingDeletion = url } label: {
                                Label(L("Supprimer", "Delete"), systemImage: "trash")
                            }
                            .disabled(model.running)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var toolbarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Text("Pocket").font(.headline)
                    Circle()
                        .fill(model.running ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(L("Téléchargement", "Download"))
                        .accessibilityValue(model.running ? L("En cours", "In progress") : L("Inactif", "Inactive"))
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(L("Réglages", "Settings"))
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button { followingPresented = true } label: { Image(systemName: "person.2") }
                    .accessibilityLabel(L("Comptes suivis", "Followed accounts"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                KDriveCollectionUploadButton(files: model.files)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { export = ExportSelection(files: model.files) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.files.isEmpty)
                .accessibilityLabel(L("Exporter les médias affichés", "Export displayed media"))
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
        return Button { model.selectUser(collection.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: collection.isSaved ? "bookmark.fill" : (collection.isSubreddit ? "person.3" : "person.crop.circle"))
                Text(collection.displayName).lineLimit(1)
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

    private func start() {
        guard !model.running else { return }
        editing = false
        model.start()
    }
}

/// Bouton commutateur de source : une touche = la pastille pivote (demi-flip),
/// la face suivante apparaît, la pastille se referme. Cycle u/ → r/ → ♥.
private struct SourceKindToggle: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @Binding var kind: String
    @State private var halfFlip = false

    private func next(_ current: String) -> String {
        current == "u" ? "r" : (current == "r" ? "saved" : "u")
    }
    private func face(_ current: String) -> String {
        current == "r" ? "r/" : (current == "saved" ? "♥" : "u/")
    }
    private func spoken(_ current: String) -> String {
        current == "r" ? "subreddit" : (current == "saved" ? L("sauvegardés", "saved") : L("profil", "profile"))
    }

    var body: some View {
        Button {
            guard !halfFlip else { return }
            withAnimation(.easeInOut(duration: 0.16)) { halfFlip = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                kind = next(kind)
                withAnimation(.easeInOut(duration: 0.16)) { halfFlip = false }
            }
        } label: {
            Text(face(kind))
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 52, height: 48)
                .foregroundStyle(.orange)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .rotation3DEffect(.degrees(halfFlip ? 90 : 0), axis: (x: 0, y: 1, z: 0))
        .accessibilityLabel(L("Source : \(spoken(kind)). Touchez pour changer.", "Source: \(spoken(kind)). Tap to change."))
    }
}

private struct DownloadSettings: View {
    @ObservedObject var model: Downloader
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @ObservedObject private var reddit = RedditSession.shared
    @State private var loginPresented = false
    @State private var confirmDeleteAll = false
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
                    Stepper(value: $model.concurrentLimit, in: 1...6) {
                        HStack {
                            Text(L("Téléchargements simultanés", "Concurrent downloads"))
                            Spacer()
                            Text("\(model.concurrentLimit)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(model.running ? L("Appliqué au prochain lancement. En cours : \(model.sessionLimit).", "Applies to the next run. Current: \(model.sessionLimit).") : L("1 à 6. Un nombre élevé peut augmenter les limitations du serveur.", "1 to 6. Higher values may increase server rate limiting."))
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
                KDriveSettingsSection()
                Section {
                    Button(L("Supprimer tous les téléchargements", "Delete all downloads"), role: .destructive) { confirmDeleteAll = true }
                        .disabled(model.running)
                        .foregroundStyle(.red)
                } footer: {
                    Text(L("Efface les médias et les archives de tous les utilisateurs. Irréversible.", "Deletes media and archives for all users. Cannot be undone."))
                }
            }
            .fullScreenCover(isPresented: $loginPresented) { RedditLogin() }
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

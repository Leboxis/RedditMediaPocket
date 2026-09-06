import SwiftUI
import MediaCore

@main struct RedditMediaPocketApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
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
    @State private var settingsPresented = false
    @FocusState private var editing: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sessionButton
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
            .sheet(isPresented: $settingsPresented) {
                DownloadSettings(model: model)
            }
            .fullScreenCover(item: $selection) { item in
                MediaPreview(urls: item.files, selectedURL: item.url)
            }
            .sheet(item: $export) { item in
                ExportSheet(files: item.files).ignoresSafeArea()
            }
            .alert("Téléchargement interrompu", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .tint(.orange)
        }
    }

    private var sessionButton: some View {
        Button { settingsPresented = true } label: { RedditSessionIndicator() }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            SourceKindToggle(kind: $model.sourceKind)
                .disabled(model.running)
            TextField(model.sourceKind == "saved" ? "pseudo du compte" : (model.sourceKind == "r" ? "nom du sub" : "pseudo"), text: $model.username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.go).focused($editing)
                .disabled(model.running)
                .onSubmit { start() }
                .padding(13)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
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
            .accessibilityLabel(model.running ? "Arrêter" : "Télécharger")
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var cannotStart: Bool {
        guard !model.running else { return false }
        if model.username.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return model.needsSession && !redditSession.hasSession
    }

    private var isSubredditInput: Bool {
        if let source = model.resolvedSource, case .subreddit = source { return true }
        return false
    }

    @ViewBuilder private var sortRow: some View {
        if isSubredditInput {
            Picker("Tri du subreddit", selection: $model.subSort) {
                Text("Nouveaux").tag("new")
                Text("Chauds").tag("hot")
                Text("Top du mois").tag("top")
            }
            .pickerStyle(.segmented)
            .disabled(model.running)
            .padding(.horizontal, 16).padding(.bottom, 10)
            .accessibilityLabel("Tri du subreddit")
        }
    }

    @ViewBuilder private var savedHintRow: some View {
        if model.needsSession && !redditSession.hasSession {
            Label("Sauvegardés : connecte-toi à Reddit dans les Réglages, puis saisis le pseudo du compte.", systemImage: "person.crop.circle.badge.questionmark")
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
                        ForEach(model.collections.sorted { $0.archived != $1.archived ? !$0.archived : $0.displayName < $1.displayName }) { collection in
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
            metric("\(model.files.count)", label: "médias")
            metric(model.totalSize, label: "")
            metric("\(model.count)/\(model.discovered)", label: "repérés")
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
        if model.files.isEmpty {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
                .accessibilityLabel("Galerie vide")
            Text(model.activeCollection.map { "Aucun média pour \($0.displayName)" } ?? "Choisis une source (u/, r/ ou ♥)")
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
                        .accessibilityLabel(isVideo(url) ? "Ouvrir la vidéo" : "Ouvrir l’image")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var toolbarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Réglages")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { export = ExportSelection(files: model.files) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.files.isEmpty)
                .accessibilityLabel("Exporter les médias affichés")
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
                Image(systemName: collection.archived ? "archivebox" : (collection.isSaved ? "bookmark.fill" : (collection.isSubreddit ? "person.3" : "person.crop.circle")))
                Text(collection.displayName).lineLimit(1)
                if active { Image(systemName: "checkmark") }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(minHeight: 44)
            .foregroundStyle(active ? Color.white : (collection.archived ? Color.secondary : Color.primary))
            .background(active ? Color.orange : Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if collection.archived {
                Button { model.setArchived(collection.id, false) } label: {
                    Label("Retirer des archives", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button { model.setArchived(collection.id, true) } label: {
                    Label("Archiver", systemImage: "archivebox")
                }
            }
            Button { model.download(user: collection.id) } label: {
                Label("Reprendre le téléchargement", systemImage: "arrow.clockwise")
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
    @Binding var kind: String
    @State private var halfFlip = false

    private func next(_ current: String) -> String {
        current == "u" ? "r" : (current == "r" ? "saved" : "u")
    }
    private func face(_ current: String) -> String {
        current == "r" ? "r/" : (current == "saved" ? "♥" : "u/")
    }
    private func spoken(_ current: String) -> String {
        current == "r" ? "subreddit" : (current == "saved" ? "sauvegardés" : "profil")
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
        .accessibilityLabel("Source : \(spoken(kind)). Touchez pour changer.")
    }
}

private struct DownloadSettings: View {
    @ObservedObject var model: Downloader
    @ObservedObject private var reddit = RedditSession.shared
    @State private var loginPresented = false
    @State private var confirmDeleteAll = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $model.concurrentLimit, in: 1...6) {
                        HStack {
                            Text("Téléchargements simultanés")
                            Spacer()
                            Text("\(model.concurrentLimit)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(model.running ? "Appliqué au prochain lancement. En cours : \(model.sessionLimit)." : "1 à 6. Un nombre élevé peut augmenter les limitations du serveur.")
                }
                Section {
                    RedditSessionIndicator()
                    Button(reddit.hasSession ? "Session détectée · ouvrir Reddit" : "Se connecter à Reddit") { loginPresented = true }
                        .disabled(model.running || reddit.clearing)
                    Button("Déconnexion", role: .destructive) { Task { await reddit.logout() } }
                        .disabled(model.running || reddit.clearing)
                } header: {
                    Text("Reddit")
                } footer: {
                    Text(model.running ? "Arrête les transferts pour modifier la session." : "Session locale. Les limites Reddit restent applicables.")
                }
                Section {
                    Button("Supprimer tous les téléchargements", role: .destructive) { confirmDeleteAll = true }
                        .disabled(model.running)
                        .foregroundStyle(.red)
                } footer: {
                    Text("Efface les médias et les archives de tous les utilisateurs. Irréversible.")
                }
            }
            .fullScreenCover(isPresented: $loginPresented) { RedditLogin() }
            .confirmationDialog("Supprimer tous les téléchargements ?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Tout supprimer", role: .destructive) { model.deleteAllDownloads() }
                Button("Annuler", role: .cancel) { }
            } message: {
                Text("Tous les médias téléchargés seront définitivement effacés.")
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .tint(.orange)
    }
}

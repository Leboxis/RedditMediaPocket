import SwiftUI

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
            HStack(spacing: 4) {
                Text("u/").foregroundStyle(.secondary)
                TextField("Pseudo Reddit", text: $model.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).focused($editing)
                    .disabled(model.running)
                    .onSubmit { start() }
            }
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
            .disabled(!model.running && model.username.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(model.running ? "Arrêter" : "Télécharger")
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var userChipsRow: some View {
        Group {
            if !model.collections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.collections.sorted { $0.archived != $1.archived ? !$0.archived : $0.name < $1.name }) { collection in
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
        HStack(spacing: 0) {
            metric("\(model.files.count)", label: "médias")
            metric(model.totalSize, label: "")
            if model.running || model.discovered > 0 {
                metric("\(model.count)/\(model.discovered)", label: "repérés")
            }
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
            Text(model.activeUser.map { "Aucun média pour u/\($0)" } ?? "Choisis un utilisateur")
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
                .accessibilityLabel("Exporter les médias de l’utilisateur")
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
        let active = model.activeUser == collection.name
        return Button { model.selectUser(collection.name) } label: {
            HStack(spacing: 5) {
                Image(systemName: collection.archived ? "archivebox" : "person.crop.circle")
                Text("u/\(collection.name)").lineLimit(1)
                if active { Image(systemName: "checkmark") }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(active ? Color.white : (collection.archived ? Color.secondary : Color.primary))
            .background(active ? Color.orange : Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if collection.archived {
                Button { model.setArchived(collection.name, false) } label: {
                    Label("Retirer des archives", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button { model.setArchived(collection.name, true) } label: {
                    Label("Archiver", systemImage: "archivebox")
                }
            }
            Button { model.download(user: collection.name) } label: {
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

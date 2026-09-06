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
                Button { settingsPresented = true } label: { RedditSessionIndicator() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.bottom, 12)
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

                HStack(spacing: 0) {
                    metric("\(model.files.count)", label: "Médias")
                    Divider().frame(height: 30)
                    metric(model.totalSize, label: "Au total")
                    if model.running || model.discovered > 0 {
                        Divider().frame(height: 30)
                        metric("\(model.count)/\(model.discovered)", label: "Repérés à recevoir")
                    }
                }
                .padding(.vertical, 14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16).padding(.bottom, 10)

                if model.running || !model.status.isEmpty {
                    HStack(spacing: 6) {
                        if model.running { ProgressView().controlSize(.small) }
                        Text(model.transfers > 0 ? "\(model.transfers)/\(model.sessionLimit) transferts" : (model.active > 0 ? "Préparation…" : model.status))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 10)
                }

                if !model.limitNotice.isEmpty {
                    Label(model.limitNotice, systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 18).padding(.bottom, 10)
                }

                if model.files.isEmpty {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
                        .accessibilityLabel("Galerie vide")
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(model.files, id: \.self) { url in
                                Button { editing = false; selection = Selection(url: url, files: model.files) } label: {
                                    MediaThumbnail(url: url)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isVideo(url) ? "Ouvrir la vidéo" : "Ouvrir l’image")
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("Pocket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Réglages")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { export = ExportSelection(files: model.files) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.files.isEmpty)
                    .accessibilityLabel("Exporter tous les médias")
                }
            }
            .sheet(isPresented: $settingsPresented) {
                DownloadSettings(model: model)
            }
            .fullScreenCover(item: $selection) { item in
                MediaPreview(urls: item.files, selectedURL: item.url)
            }
            .sheet(item: $export) { item in
                ExportSheet(files: item.files).ignoresSafeArea()
            }
            .tint(.orange)
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 4)
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
            }
            .fullScreenCover(isPresented: $loginPresented) { RedditLogin() }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .tint(.orange)
    }
}

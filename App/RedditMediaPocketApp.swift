import SwiftUI

@main struct RedditMediaPocketApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

private struct Selection: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ContentView: View {
    @StateObject private var model = Downloader()
    @State private var selection: Selection?
    @FocusState private var editing: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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

                HStack(spacing: 8) {
                    Text("\(model.files.count)").monospacedDigit()
                    Spacer()
                    if model.running {
                        ProgressView().controlSize(.small)
                        Text(model.active > 0 ? "\(model.active)/3 · \(model.count) reçus" : model.status)
                            .monospacedDigit()
                    } else {
                        Text(model.status).lineLimit(2)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 12)

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
                                Button { selection = Selection(url: url) } label: {
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
            .sheet(item: $selection) { item in
                NavigationStack {
                    MediaPreview(url: item.url)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button { selection = nil } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Fermer")
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                            }
                        }
                }
            }
            .tint(.orange)
        }
    }

    private func start() {
        guard !model.running else { return }
        editing = false
        model.start()
    }
}

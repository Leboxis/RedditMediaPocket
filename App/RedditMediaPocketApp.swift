import SwiftUI

@main struct RedditMediaPocketApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var model = Downloader()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Les médias, dans ta poche", systemImage: "arrow.down.circle.fill")
                        .font(.title2.bold()).foregroundStyle(.orange)
                    Text("Images et vidéos publiques, sans compte Reddit.").foregroundStyle(.secondary)
                    TextField("Pseudo Reddit — sans @", text: $model.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(model.running)
                    if model.running {
                        Button("Arrêter", role: .cancel) { model.stop() }
                        ProgressView()
                    } else {
                        Button("Télécharger les médias accessibles") { model.start() }
                            .disabled(model.username.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("État") { Text(model.status).textSelection(.enabled) }
                Section("À savoir") {
                    Text("Garde l’app ouverte pendant le téléchargement. Un seul transfert à la fois, avec au moins 7 secondes entre les requêtes. Aucun débit ne garantit l’absence de blocage.")
                    Text("Ce prototype lit le RSS public. Galeries Reddit, posts privés ou supprimés et liens externes non reconnus ne sont pas téléchargés. RedGIFs utilise un jeton temporaire anonyme, sans compte.")
                    Text("Les fichiers existants sont conservés à la reprise. Un refus HTTP arrête la session.")
                }.font(.footnote).foregroundStyle(.secondary)
                if !model.files.isEmpty {
                    Section("Fichiers · \(model.files.count)") {
                        ForEach(model.files, id: \.self) { url in
                            ShareLink(item: url) {
                                Label(String(url.lastPathComponent.prefix(16)) + "." + url.pathExtension, systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
                if !model.logs.isEmpty {
                    Section("Journal") {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
                    }
                }
            }
            .navigationTitle("Media Pocket")
            .tint(.orange)
        }
    }
}

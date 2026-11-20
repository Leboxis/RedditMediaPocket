import SwiftUI

/// Vue simple des éléments stockés dans le Worker. Tout appel réseau part de `.task`,
/// jamais du `init` ni du `body`.
struct ItemsListView: View {
    @State private var items: [Item] = []
    @State private var erreur: String?
    @State private var chargement = true
    @State private var clePresentee = false

    private let client: ItemsAPIClientProtocol

    init(client: ItemsAPIClientProtocol = ItemsAPIClient()) {
        self.client = client
    }

    var body: some View {
        NavigationStack {
            Group {
                if chargement {
                    ProgressView(L("Chargement des données…", "Loading data…"))
                } else if let erreur {
                    ContentUnavailableView {
                        Label(L("Erreur", "Error"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(erreur)
                    } actions: {
                        Button(L("Réessayer", "Try Again")) {
                            Task { await charger() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button(L("Saisir la clé API", "Enter API key")) {
                            clePresentee = true
                        }
                    }
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label(L("Aucun élément", "No items"), systemImage: "tray")
                    } description: {
                        Text(L("Les données du Worker apparaîtront ici.", "Worker data will appear here."))
                    }
                } else {
                    List(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.headline)
                            if let type = item.type {
                                Text(type)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let resume = item.resumeDonnees {
                                Text(resume)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle(L("Données Pocket", "Pocket data"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { clePresentee = true } label: {
                        Image(systemName: "key.fill")
                    }
                    .accessibilityLabel(L("Clé API", "API key"))
                }
            }
            .sheet(isPresented: $clePresentee) {
                APIKeySettingsView()
            }
            .task { await charger() }
            .refreshable { await charger() }
        }
    }

    @MainActor
    private func charger() async {
        chargement = true
        erreur = nil
        defer { chargement = false }
        do {
            let page = try await client.list()
            items = page.items
        } catch is CancellationError {
            // Annulation silencieuse : la vue a disparu.
            return
        } catch let apiErreur as APIError {
            if case .transport(let urlErreur) = apiErreur, urlErreur.code == .cancelled {
                return
            }
            erreur = apiErreur.localizedDescription
        } catch {
            erreur = error.localizedDescription
        }
    }
}

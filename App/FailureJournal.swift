import SwiftUI
import MediaCore

/// Un média dont le téléchargement a échoué pendant un parcours : il est
/// resté silencieux (compté « ignoré ») et, marqué vu, n'était jamais
/// réévalué. Le journal le garde en attente jusqu'à un nouveau essai ou un
/// effacement explicite.
struct FailureEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Collection concernée (`u/pseudo`, `r/sub`, …) et son dossier.
    var collectionID: String
    var folderName: String
    /// Nom de fichier prévu au moment de l'échec.
    var filename: String
    /// Adresse directe du média quand elle est connue : c'est elle que le
    /// nouveau essai redemande. `nil` pour un média résolu autrement (GIF
    /// RedGifs, vidéo DASH Reddit) : le nouvel essai passe par la collection.
    var sourceURL: String?
    /// En-têtes exigés par l'hébergeur (Referer, UA navigateur).
    var headers: [String: String]?
    var author: String
    var error: String
    var date = Date()

    /// Clé de dédoublonnage : un média qui échoue deux fois ne crée pas deux
    /// entrées, la seconde remplace la première.
    var dedupKey: String { (sourceURL ?? "") + "|" + filename }
}

/// Journal persistant des échecs de téléchargement. Le fichier survit aux
/// relances de l'app : un échec du lundi reste visible et retentable le
/// vendredi, après que l'hébergeur a réparé son côté.
@MainActor final class FailureJournal: ObservableObject {
    static let shared = FailureJournal()
    @Published private(set) var entries: [FailureEntry] = []

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("RedditMediaPocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("failure-journal.json")
    }

    init() { load() }

    /// Jamais plus de 500 entrées : au-delà, les plus anciennes tombent. Un
    /// média inaccessible depuis longtemps l'est probablement pour de bon.
    private static let cap = 500

    func record(_ entry: FailureEntry) {
        var list = entries.filter { $0.dedupKey != entry.dedupKey }
        list.append(entry)
        if list.count > Self.cap {
            list.removeFirst(list.count - Self.cap)
        }
        entries = list
        save()
    }

    func remove(ids: [UUID]) {
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([FailureEntry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// Bouton de la barre : ouvre le journal des échecs. Le badge montre le
/// nombre d'échecs en attente — invisible, un échec restait muet.
struct FailureJournalButton: View {
    @ObservedObject private var journal = FailureJournal.shared
    @ObservedObject private var model: Downloader
    @State private var presented = false

    init(model: Downloader) {
        self.model = model
    }

    var body: some View {
        Button {
            presented = true
        } label: {
            Image(systemName: "exclamationmark.triangle")
                .overlay(alignment: .topTrailing) {
                    if !journal.entries.isEmpty {
                        Text(String(journal.entries.count))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.onAccent)
                            .padding(DS.space(1))
                            .background(Circle().fill(DS.error))
                            .offset(x: 7, y: -7)
                    }
                }
        }
        .accessibilityLabel(L("Journal des échecs", "Failure journal"))
        .sheet(isPresented: $presented) { FailureJournalView(model: model) }
    }
}

/// Liste des échecs en attente, avec nouveau essai immédiat.
struct FailureJournalView: View {
    @ObservedObject private var journal = FailureJournal.shared
    @ObservedObject private var model: Downloader
    @Environment(\.dismiss) private var dismiss

    init(model: Downloader) {
        self.model = model
    }

    var body: some View {
        NavigationStack {
            Group {
                if journal.entries.isEmpty {
                    ContentUnavailableView(L("Aucun échec en attente", "No pending failures"),
                                           systemImage: "checkmark.circle",
                                           description: Text(L("Les échecs de téléchargement apparaîtront ici, prêts à être retentés.",
                                                              "Download failures will appear here, ready to be retried.")))
                } else {
                    List {
                        ForEach(journal.entries) { entry in
                            FailureRow(entry: entry, model: model)
                        }
                        .onDelete { offsets in
                            journal.remove(ids: offsets.map { journal.entries[$0].id })
                        }
                    }
                }
            }
            .navigationTitle(L("Journal des échecs", "Failure journal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !journal.entries.isEmpty {
                        Button(L("Tout réessayer", "Retry all")) {
                            model.retryFailures(journal.entries)
                        }
                        .disabled(model.running)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Vider", "Clear")) { journal.clear() }
                        .disabled(journal.entries.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("OK", "OK")) { dismiss() }
                }
            }
        }
    }
}

private struct FailureRow: View {
    let entry: FailureEntry
    @ObservedObject private var model: Downloader

    init(entry: FailureEntry, model: Downloader) {
        self.entry = entry
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.filename)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(entry.collectionID)
                .font(.caption)
                .foregroundStyle(DS.onSurfaceMuted)
            HStack {
                Text(entry.error)
                    .font(.caption2)
                    .foregroundStyle(DS.error)
                    .lineLimit(2)
                Spacer()
                if entry.sourceURL != nil {
                    Button(L("Réessayer", "Retry")) {
                        model.retryFailures([entry])
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(model.running)
                } else {
                    Text(L("Nouvel essai par relance de la collection", "Retry by rescanning the collection"))
                        .font(.caption2)
                        .foregroundStyle(DS.onSurfaceMuted)
                }
            }
        }
        .padding(.vertical, DS.space(1))
    }
}

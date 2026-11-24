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
@MainActor @Observable
final class FailureJournal {
    static let shared = FailureJournal()
    private(set) var entries: [FailureEntry] = []

    private static let ioQueue = DispatchQueue(label: "FailureJournal.io", qos: .utility)
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("RedditMediaPocket", isDirectory: true)
        fileURL = folder.appendingPathComponent("failure-journal.json")
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let loaded = try? JSONDecoder().decode([FailureEntry].self, from: data) else { return }
            await MainActor.run {
                let journal = FailureJournal.shared
                if journal.entries.isEmpty {
                    journal.entries = loaded
                } else {
                    let existingKeys = Set(journal.entries.map(\.dedupKey))
                    let merged = loaded.filter { !existingKeys.contains($0.dedupKey) } + journal.entries
                    journal.entries = merged.count > Self.cap ? Array(merged.suffix(Self.cap)) : merged
                }
            }
        }
    }

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
        scheduleSave()
    }

    func remove(ids: [UUID]) {
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        entries = []
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = entries
        let url = fileURL
        Self.ioQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Bouton de la barre : ouvre le journal des échecs. Le badge montre le
/// nombre d'échecs en attente — invisible, un échec restait muet.
struct FailureJournalButton: View {
    private var journal = FailureJournal.shared
    private var model: Downloader
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
                            .font(.caption2.weight(.bold))
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
    private var journal = FailureJournal.shared
    private var model: Downloader
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

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
                        if model.running && !model.status.isEmpty {
                            HStack(spacing: DS.space(2)) {
                                ProgressView().controlSize(.small)
                                Text(model.status)
                                    .font(.caption)
                                    .foregroundStyle(DS.onSurfaceMuted)
                            }
                        }
                        ForEach(journal.entries) { entry in
                            FailureRow(entry: entry, isRunning: model.running) {
                                model.retryFailures([entry])
                            }
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
                    if !journal.entries.isEmpty {
                        Button(L("Vider", "Clear"), role: .destructive) { confirmClear = true }
                            .disabled(model.running)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("OK", "OK")) { dismiss() }
                }
            }
            .confirmationDialog(L("Vider le journal des échecs ?", "Clear failure journal?"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(L("Vider", "Clear"), role: .destructive) { journal.clear() }
                Button(L("Annuler", "Cancel"), role: .cancel) { }
            } message: {
                Text(L("Tous les échecs en attente seront oubliés.", "All pending failures will be discarded."))
            }
        }
        .tint(DS.accentEmphasis)
    }
}

private struct FailureRow: View {
    let entry: FailureEntry
    let isRunning: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space(1)) {
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
                    Button(L("Réessayer", "Retry"), action: onRetry)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(isRunning)
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

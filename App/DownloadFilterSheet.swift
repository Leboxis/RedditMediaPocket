import SwiftUI
import MediaCore

/// Panneau de filtres de téléchargement. Il décide de ce qui est **téléchargé**,
/// pas de ce qui est parcouru : un média écarté reste « vu » et ne sera pas
/// réévalué au lancement suivant, ce que le pied de page rappelle.
///
/// Les réglages sont enregistrés à la fermeture, par collection.
struct DownloadFilterSheet: View {
    @ObservedObject var model: Downloader
    @Environment(\.dismiss) private var dismiss

    @State private var kinds: Set<DownloadFilter.MediaKind> = []
    @State private var useSince = false
    @State private var since = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var minimumMB = 0
    @State private var includes = ""
    @State private var excludes = ""

    private var collectionLabel: String { model.activeCollection?.displayName ?? L("cette source", "this source") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(DownloadFilter.MediaKind.allCases, id: \.self) { kind in
                        Button {
                            toggle(kind)
                        } label: {
                            HStack {
                                Text(label(kind))
                                Spacer()
                                if kinds.contains(kind) {
                                    Image(systemName: "checkmark").foregroundStyle(.orange)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text(L("Types de médias", "Media types"))
                } footer: {
                    Text(L("Aucun type coché signifie « tous ». Le sélecteur Images / Vidéos de X-Fetish reste indépendant.", "No type checked means “all”. The X-Fetish Images / Videos selector stays independent."))
                }

                Section {
                    Toggle(L("Depuis une date", "Since a date"), isOn: $useSince)
                    if useSince {
                        DatePicker(L("Date minimale", "Earliest date"), selection: $since, displayedComponents: .date)
                    }
                } header: {
                    Text(L("Date de publication", "Publication date"))
                } footer: {
                    Text(L("Un post sans date connue passe le filtre.", "A post without a known date passes the filter."))
                }

                Section {
                    Stepper(value: $minimumMB, in: 0...5000, step: 250) {
                        HStack {
                            Text(L("Taille minimale", "Minimum size"))
                            Spacer()
                            Text(minimumMB == 0 ? L("Sans", "None") : "\(minimumMB) Mo").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(L("0 = sans minimum. La taille n’est connue qu’après le transfert pour la plupart des hébergeurs : ce filtre écarte surtout les petits fichiers une fois reçus.", "0 = no minimum. For most hosts the size is only known after transfer: this filter mainly drops small files once received."))
                }

                Section {
                    TextField(L("mots à exiger, séparés par des virgules", "required words, comma separated"), text: $includes, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(L("mots à exclure, séparés par des virgules", "excluded words, comma separated"), text: $excludes, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text(L("Titre du post", "Post title"))
                } footer: {
                    Text(L("Comparaison sans distinction de casse. Tous les mots exigés doivent être présents ; un seul mot exclu suffit à écarter le média.", "Case-insensitive match. Every required word must be present; a single excluded word is enough to drop the media."))
                }

                Section {
                    Button(L("Effacer les filtres", "Clear filters"), role: .destructive) { clear() }
                        .disabled(current.isEmpty)
                } footer: {
                    Text(L("Filtres appliqués à \(collectionLabel) uniquement, et enregistrés pour cette source.", "Filters apply to \(collectionLabel) only, and are saved for this source."))
                }
            }
            .navigationTitle(L("Filtres", "Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { apply(); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Annuler", "Cancel")) { dismiss() }
                }
            }
            .onAppear(perform: load)
            .tint(.orange)
        }
    }

    /// Filtre tel qu'il serait enregistré maintenant.
    private var current: DownloadFilter {
        DownloadFilter(
            kinds: kinds,
            since: useSince ? since : nil,
            minimumBytes: Int64(minimumMB) * 1_000_000,
            includes: DownloadFilter.parseWords(includes),
            excludes: DownloadFilter.parseWords(excludes)
        )
    }

    private func load() {
        let filter = model.downloadFilter
        kinds = filter.kinds
        useSince = filter.since != nil
        if let date = filter.since { since = date }
        minimumMB = Int(filter.minimumBytes / 1_000_000)
        includes = filter.includes.joined(separator: ", ")
        excludes = filter.excludes.joined(separator: ", ")
    }

    private func apply() {
        model.downloadFilter = current
        model.saveActiveFilter()
    }

    private func toggle(_ kind: DownloadFilter.MediaKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    private func clear() {
        kinds = []
        useSince = false
        minimumMB = 0
        includes = ""
        excludes = ""
    }

    private func label(_ kind: DownloadFilter.MediaKind) -> String {
        switch kind {
        case .image: return L("Images", "Images")
        case .video: return L("Vidéos", "Videos")
        case .gif: return L("GIF", "GIF")
        }
    }
}

import SwiftUI
import MediaCore

/// Barre de recherche, tri et filtre de la galerie.
///
/// Vue à part entière plutôt que propriété calculée : son corps n'est
/// réévalué que lorsque `model` publie un changement, au lieu de l'être à
/// chaque réévaluation de `ContentView`.
///
/// Le tri et le filtre utilisent des `Menu` de boutons avec coche, et non des
/// `Picker` imbriqués dans un `Menu` : sur iOS, un `Picker` placé dans un menu
/// se referme parfois sans appliquer le choix.
struct GalleryToolbar: View {
    @ObservedObject var model: Downloader
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                searchField
                sortMenu
                kindMenu
            }
            if model.displayedFiles.count != model.files.count {
                Text(L("\(model.displayedFiles.count) sur \(model.files.count) médias",
                       "\(model.displayedFiles.count) of \(model.files.count) media"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(L("\(model.displayedFiles.count) médias affichés sur \(model.files.count)",
                                          "\(model.displayedFiles.count) of \(model.files.count) media shown"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("Rechercher", "Search"), text: $model.gallerySearch)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.gallerySearch.isEmpty {
                Button {
                    model.gallerySearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Effacer la recherche", "Clear search"))
            }
        }
        .font(.footnote)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(Downloader.GallerySort.allCases, id: \.self) { sort in
                Button {
                    model.gallerySort = sort
                } label: {
                    // Une coche explicite : le libellé seul ne dirait pas
                    // quel ordre est actif dans un menu fermé.
                    if model.gallerySort == sort {
                        Label(sort.label, systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            toolbarIcon("arrow.up.arrow.down", active: model.gallerySort != .newest)
        }
        .accessibilityLabel(L("Trier la galerie", "Sort the gallery"))
        .accessibilityValue(model.gallerySort.label)
    }

    private var kindMenu: some View {
        Menu {
            ForEach(Downloader.GalleryKindFilter.allCases, id: \.self) { kind in
                Button {
                    model.galleryKindFilter = kind
                } label: {
                    if model.galleryKindFilter == kind {
                        Label(kind.label, systemImage: "checkmark")
                    } else {
                        Text(kind.label)
                    }
                }
            }
        } label: {
            toolbarIcon("line.3.horizontal.decrease", active: model.galleryKindFilter != .all)
        }
        .accessibilityLabel(L("Filtrer par type", "Filter by type"))
        .accessibilityValue(model.galleryKindFilter.label)
    }

    /// Icône de barre d'outils, teintée quand un réglage non par défaut est
    /// actif : sans cela, rien n'indiquerait qu'un tri ou un filtre s'applique.
    private func toolbarIcon(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(active ? Color.orange : Color.primary)
            .frame(width: 30, height: 30)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
    }
}

import SwiftUI
import MediaCore
import Combine
import UIKit
import ImageIO

/// Ordre d'affichage des comptes dans l'onglet Suivis.
enum FollowingSortOrder: String, CaseIterable, Identifiable, Sendable {
    case kDriveFirst
    case alphabetical

    static let defaultsKey = "following.sortOrder"
    static let defaultOrder: FollowingSortOrder = .kDriveFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kDriveFirst:
            return L("Présents sur kDrive d'abord", "On kDrive first")
        case .alphabetical:
            return L("Ordre alphabétique (A–Z)", "Alphabetical (A–Z)")
        }
    }

    var systemImage: String {
        switch self {
        case .kDriveFirst:
            return "icloud.fill"
        case .alphabetical:
            return "textformat.abc"
        }
    }

    /// Sépare en une passe les comptes présents sur kDrive et les autres,
    /// chaque groupe trié par ordre alphabétique insensible à la casse.
    static func partition(
        _ names: [String],
        isOnKDrive: (String) -> Bool
    ) -> (onKDrive: [String], others: [String]) {
        var present: [String] = []
        var absent: [String] = []
        present.reserveCapacity(names.count)
        absent.reserveCapacity(names.count)
        for name in names {
            if isOnKDrive(name) {
                present.append(name)
            } else {
                absent.append(name)
            }
        }
        let compare: (String, String) -> Bool = {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        present.sort(by: compare)
        absent.sort(by: compare)
        return (present, absent)
    }

    /// Trie une liste de pseudos selon l'ordre actif.
    /// - En mode `.kDriveFirst`, les comptes présents sur kDrive sont mis en avant,
    ///   chaque groupe étant trié par ordre alphabétique insensible à la casse.
    /// - En mode `.alphabetical`, tous les comptes sont triés de A à Z.
    func sorted(_ names: [String], isOnKDrive: (String) -> Bool) -> [String] {
        switch self {
        case .alphabetical:
            return names.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        case .kDriveFirst:
            let groups = Self.partition(names, isOnKDrive: isOnKDrive)
            return groups.onKDrive + groups.others
        }
    }
}

struct FollowingView: View {
    var model: Downloader
    let onDownloadAll: (String) -> Void

    @State private var session = RedditSession.shared
    @State private var kDriveFreshness = KDriveFreshnessCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var plateforme: PlateformeSuivi = .reddit
    @State private var friends: [String]?
    @State private var xFriends: [String] = []
    @State private var tikTokFriends: [String] = []
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var retryCount = 0
    @State private var kDriveIndex: [String: KDriveFolderItem]?
    @State private var kDriveLoading = false
    @State private var ajoutManuelPresente = false
    @State private var nouveauPseudoManuel = ""
    @State private var erreurAjoutManuel: String?
    @State private var suiviManuelEnEdition: String?
    @State private var pseudoManuelEdite = ""
    @State private var erreurEditionManuelle: String?
    @AppStorage("following.downloadedUsernames") private var downloadedUsernamesData = Data()
    @AppStorage("following.x.downloadedUsernames") private var xDownloadedUsernamesData = Data()
    @AppStorage("following.tiktok.downloadedUsernames") private var tikTokDownloadedUsernamesData = Data()
    /// Dates de téléchargement et d'upload, synchronisées avec le serveur.
    @State private var etats: [String: CompteSuiviEtat] = [:]
    @State private var xEtats: [String: CompteSuiviEtat] = [:]
    @State private var tikTokEtats: [String: CompteSuiviEtat] = [:]
    @AppStorage(FollowingSortOrder.defaultsKey) private var sortOrderRaw = FollowingSortOrder.defaultOrder.rawValue
    @AppStorage("kDriveApiToken") private var kDriveToken = ""
    @AppStorage("kDriveId") private var kDriveId = ""
    @AppStorage("kDriveDirectoryId") private var kDriveDirectoryId = "1"

    private var sortOrder: FollowingSortOrder {
        FollowingSortOrder(rawValue: sortOrderRaw) ?? .defaultOrder
    }

    private var kDriveConfigured: Bool {
        !kDriveToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !kDriveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func downloadedUsernames(pour plateforme: PlateformeSuivi) -> Set<String> {
        let data: Data
        switch plateforme {
        case .reddit: data = downloadedUsernamesData
        case .x: data = xDownloadedUsernamesData
        case .tiktok: data = tikTokDownloadedUsernamesData
        }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    private func toggleDownloaded(_ username: String, plateforme: PlateformeSuivi) {
        let key = username.lowercased()
        var names = downloadedUsernames(pour: plateforme)
        if names.contains(key) {
            names.remove(key)
        } else {
            names.insert(key)
        }
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        switch plateforme {
        case .reddit:
            downloadedUsernamesData = data
            SuiviStore.invaliderCache()
            etats = SuiviStore.charger(plateforme: .reddit)
        case .x:
            xDownloadedUsernamesData = data
            SuiviStore.invaliderCache()
            xEtats = SuiviStore.charger(plateforme: .x)
        case .tiktok:
            tikTokDownloadedUsernamesData = data
            SuiviStore.invaliderCache()
            tikTokEtats = SuiviStore.charger(plateforme: .tiktok)
        }
        // La coche fait partie de l'état synchronisé : on pousse vers Cloudflare.
        NotificationCenter.default.post(name: .pocketDonneesDidChange, object: nil)
    }

    private var hasSyncKey: Bool {
        KeychainStore.get() != nil
    }

    private var nomPlateformeManuelle: String {
        plateforme == .tiktok ? "TikTok" : "X"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DSSegmentedControl(
                    L("Plateforme", "Platform"),
                    selection: $plateforme,
                    options: [
                        (.reddit, "Reddit"),
                        (.x, "X"),
                        (.tiktok, "TikTok")
                    ]
                )
                .padding(.horizontal, DS.space(4))
                .padding(.vertical, DS.space(2))

                switch plateforme {
                case .reddit:
                    redditContent
                case .x:
                    manualPlatformContent(plateforme: .x)
                case .tiktok:
                    manualPlatformContent(plateforme: .tiktok)
                }
            }
            .navigationTitle(L("Suivis", "Following"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if kDriveConfigured {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if kDriveFreshness.isCheckingAll {
                                kDriveFreshness.stopChecking()
                            } else {
                                verifierFraicheurPlateforme()
                            }
                        } label: {
                            if kDriveFreshness.isCheckingAll {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.small)
                                    Text("\(kDriveFreshness.checkedCount)/\(max(1, kDriveFreshness.totalToCheck))")
                                        .font(.caption.monospacedDigit())
                                }
                            } else {
                                KDriveStatusIcon(baseSize: 20)
                            }
                        }
                        .accessibilityLabel(kDriveFreshness.isCheckingAll
                            ? L("Arrêter la vérification kDrive", "Stop kDrive check")
                            : L("Vérifier si kDrive est à jour avec la source", "Check if kDrive is up to date with source"))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker(
                            L("Ordre d'affichage", "Sort order"),
                            selection: Binding(
                                get: { sortOrder },
                                set: { sortOrderRaw = $0.rawValue }
                            )
                        ) {
                            ForEach(FollowingSortOrder.allCases) { option in
                                Label(option.label, systemImage: option.systemImage).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel(L("Ordre d'affichage", "Sort order"))
                    .accessibilityValue(sortOrder.label)

                    if plateforme != .reddit {
                        Button {
                            nouveauPseudoManuel = ""
                            ajoutManuelPresente = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L("Ajouter un compte \(nomPlateformeManuelle)", "Add \(nomPlateformeManuelle) account"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Fermer", "Close")) { dismiss() }
                }
            }
            .alert(
                L("Ajouter un suivi \(nomPlateformeManuelle)", "Add \(nomPlateformeManuelle) follow"),
                isPresented: $ajoutManuelPresente
            ) {
                TextField(
                    plateforme == .tiktok
                        ? L("@pseudo ou lien tiktok.com/@…", "@username or tiktok.com/@… link")
                        : L("@pseudo ou lien x.com/…", "@username or x.com/… link"),
                    text: $nouveauPseudoManuel
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button(L("Ajouter", "Add")) { ajouterSuiviManuel() }
                Button(L("Annuler", "Cancel"), role: .cancel) { nouveauPseudoManuel = "" }
            } message: {
                Text(L("Ajoute un compte \(nomPlateformeManuelle) manuellement pour suivre son statut et le synchroniser.",
                       "Add a \(nomPlateformeManuelle) account manually to track its status and sync it."))
            }
            .alert(
                L("Modifier le suivi \(nomPlateformeManuelle)", "Edit \(nomPlateformeManuelle) follow"),
                isPresented: Binding(
                    get: { suiviManuelEnEdition != nil },
                    set: { presentee in
                        if !presentee {
                            suiviManuelEnEdition = nil
                            pseudoManuelEdite = ""
                        }
                    }
                )
            ) {
                TextField(
                    plateforme == .tiktok
                        ? L("@pseudo ou lien tiktok.com/@…", "@username or tiktok.com/@… link")
                        : L("@pseudo ou lien x.com/…", "@username or x.com/… link"),
                    text: $pseudoManuelEdite
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button(L("Enregistrer", "Save")) { enregistrerEditionManuelle() }
                Button(L("Annuler", "Cancel"), role: .cancel) {
                    suiviManuelEnEdition = nil
                    pseudoManuelEdite = ""
                }
            } message: {
                Text(L("Corrige le pseudo de ce compte \(nomPlateformeManuelle) suivi, son historique est conservé.",
                       "Edit the username of this followed \(nomPlateformeManuelle) account; its history is kept."))
            }
        }
        .tint(DS.accentEmphasis)
        .errorAlert(erreurAjoutManuel ?? erreurEditionManuelle ?? errorMessage) {
            erreurAjoutManuel = nil
            erreurEditionManuelle = nil
        }
        .task {
            if kDriveConfigured, !model.running, kDriveIndex == nil {
                await checkKDrive()
            }
        }
        .task(id: "\(session.hasSession)-\(retryCount)") {
            rechargerStockageLocal()
            let connus = SuiviStore.pseudosConnus(plateforme: .reddit)
            if session.hasSession {
                await load()
            } else {
                errorMessage = nil
                if ((connus.isEmpty && xFriends.isEmpty && tikTokFriends.isEmpty) || retryCount > 0), hasSyncKey {
                    await restaurerDepuisServeur()
                } else {
                    friends = connus
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pocketDonneesRestaurees)) { _ in
            // Une restauration vient d'écrire les suivis et leurs états : on relit tout.
            etats = SuiviStore.charger(plateforme: .reddit)
            xEtats = SuiviStore.charger(plateforme: .x)
            tikTokEtats = SuiviStore.charger(plateforme: .tiktok)
            xFriends = SuiviStore.pseudosConnus(plateforme: .x)
            tikTokFriends = SuiviStore.pseudosConnus(plateforme: .tiktok)
            if !session.hasSession || (friends ?? []).isEmpty {
                friends = SuiviStore.pseudosConnus(plateforme: .reddit)
            }
        }
    }

    @ViewBuilder
    private var redditContent: some View {
        let markedNames = downloadedUsernames(pour: .reddit)
        if let friends, !friends.isEmpty {
            List {
                if !session.hasSession {
                    Section {
                        Label(
                            L("Non connecté à Reddit — liste synchronisée affichée.",
                              "Not signed in to Reddit — showing synced list."),
                            systemImage: "icloud"
                        )
                        .font(.footnote)
                        .foregroundStyle(DS.onSurfaceMuted)
                    }
                }
                if sortOrder == .kDriveFirst {
                    let groups = FollowingSortOrder.partition(friends) { kDriveFolder(pour: $0) != nil }
                    if !groups.onKDrive.isEmpty && !groups.others.isEmpty {
                        Section {
                            ForEach(groups.onKDrive, id: \.self) { name in
                                redditRow(name: name, markedNames: markedNames)
                            }
                        } header: {
                            Text(L("Dans kDrive (\(groups.onKDrive.count))", "On kDrive (\(groups.onKDrive.count))"))
                        }
                        Section {
                            ForEach(groups.others, id: \.self) { name in
                                redditRow(name: name, markedNames: markedNames)
                            }
                        } header: {
                            Text(L("Autres comptes (\(groups.others.count))", "Other accounts (\(groups.others.count))"))
                        }
                    } else {
                        Section {
                            ForEach(groups.onKDrive + groups.others, id: \.self) { name in
                                redditRow(name: name, markedNames: markedNames)
                            }
                        }
                    }
                } else {
                    let sorted = sortOrder.sorted(friends) { _ in false }
                    Section {
                        ForEach(sorted, id: \.self) { name in
                            redditRow(name: name, markedNames: markedNames)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await rafraichir() }
        } else if loading || (session.hasSession && friends == nil && errorMessage == nil) {
            VStack(spacing: 10) {
                ProgressView()
                Text(L("Chargement des suivis…", "Loading followed accounts…"))
                    .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: DS.space(3)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(DS.error)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(DS.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                Button(L("Réessayer", "Retry")) { retryCount += 1 }
                    .buttonStyle(DSPrimaryButtonStyle())
            }
            .padding(DS.space(6))
        } else if !session.hasSession {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle).foregroundStyle(DS.onSurfaceMuted)
                Text(L("Connecte-toi à Reddit dans les Réglages ou restaure tes suivis via la synchronisation Cloudflare.",
                       "Sign in to Reddit in Settings or restore your followed accounts via Cloudflare sync."))
                    .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                if hasSyncKey {
                    Button(L("Synchroniser depuis le serveur", "Sync from server")) {
                        retryCount += 1
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                }
            }
            .padding(DS.space(6))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.2")
                    .font(.largeTitle).foregroundStyle(DS.onSurfaceMuted)
                Text(L("Aucun compte suivi (ou liste privée indisponible).",
                       "No followed accounts (or the list is unavailable)."))
                    .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(DS.space(6))
        }
    }

    @ViewBuilder
    private func manualPlatformContent(plateforme: PlateformeSuivi) -> some View {
        let markedNames = downloadedUsernames(pour: plateforme)
        let liste = plateforme == .tiktok ? tikTokFriends : xFriends
        let etatsPlateforme = plateforme == .tiktok ? tikTokEtats : xEtats
        let nom = plateforme == .tiktok ? "TikTok" : "X"
        let marque: SourceMark = plateforme == .tiktok ? .tiktok : .x
        let prefixe = plateforme == .tiktok ? "tt" : "tw"

        if liste.isEmpty {
            VStack(spacing: 12) {
                SourceMarkView(mark: marque, tint: DS.onSurfaceMuted, size: 36)
                Text(L("Aucun compte \(nom) suivi. Ajoute un nom d'utilisateur manuellement pour suivre son statut et le synchroniser.",
                       "No followed \(nom) accounts. Add a username manually to track its status and sync it."))
                    .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                Button(L("Ajouter un compte \(nom)", "Add \(nom) account")) {
                    nouveauPseudoManuel = ""
                    ajoutManuelPresente = true
                }
                .buttonStyle(DSPrimaryButtonStyle())
                if hasSyncKey {
                    Button(L("Synchroniser depuis le serveur", "Sync from server")) {
                        Task { await restaurerDepuisServeur() }
                    }
                    .font(.footnote)
                }
            }
            .padding(DS.space(6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if sortOrder == .kDriveFirst {
                    let groups = FollowingSortOrder.partition(liste) { kDriveFolder(pour: "\(prefixe)/\($0)") != nil }
                    if !groups.onKDrive.isEmpty && !groups.others.isEmpty {
                        Section {
                            ForEach(groups.onKDrive, id: \.self) { name in
                                manualRow(
                                    name: name,
                                    plateforme: plateforme,
                                    prefixe: prefixe,
                                    marque: marque,
                                    markedNames: markedNames,
                                    etatsPlateforme: etatsPlateforme
                                )
                            }
                        } header: {
                            Text(L("Dans kDrive (\(groups.onKDrive.count))", "On kDrive (\(groups.onKDrive.count))"))
                        }
                        Section {
                            ForEach(groups.others, id: \.self) { name in
                                manualRow(
                                    name: name,
                                    plateforme: plateforme,
                                    prefixe: prefixe,
                                    marque: marque,
                                    markedNames: markedNames,
                                    etatsPlateforme: etatsPlateforme
                                )
                            }
                        } header: {
                            Text(L("Autres comptes (\(groups.others.count))", "Other accounts (\(groups.others.count))"))
                        }
                    } else {
                        Section {
                            ForEach(groups.onKDrive + groups.others, id: \.self) { name in
                                manualRow(
                                    name: name,
                                    plateforme: plateforme,
                                    prefixe: prefixe,
                                    marque: marque,
                                    markedNames: markedNames,
                                    etatsPlateforme: etatsPlateforme
                                )
                            }
                        }
                    }
                } else {
                    let sorted = sortOrder.sorted(liste) { _ in false }
                    Section {
                        ForEach(sorted, id: \.self) { name in
                            manualRow(
                                name: name,
                                plateforme: plateforme,
                                prefixe: prefixe,
                                marque: marque,
                                markedNames: markedNames,
                                etatsPlateforme: etatsPlateforme
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await rafraichir() }
        }
    }

    @ViewBuilder
    private func redditRow(name: String, markedNames: Set<String>) -> some View {
        let isDownloaded = markedNames.contains(name.lowercased())
        let redditTarget = "u/\(name)"
        HStack(spacing: 10) {
            NavigationLink {
                FollowingUserPosts(username: name, model: model, onDownloadAll: onDownloadAll)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3).foregroundStyle(DS.accentEmphasis)
                    statusDetails(
                        displayName: name,
                        etat: etats[name.lowercased()],
                        kDriveFolder: kDriveFolder(pour: name),
                        freshness: kDriveFreshness.status(for: redditTarget)
                    )
                }
            }
            rowActions(
                username: name,
                isDownloaded: isDownloaded,
                plateforme: .reddit,
                downloadTarget: name
            )
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if kDriveConfigured {
                Button {
                    verifierCompte(name, plateforme: .reddit)
                } label: {
                    Label(L("Vérifier kDrive", "Check kDrive"),
                          systemImage: "arrow.clockwise.icloud")
                }
                .tint(DS.accentEmphasis)
            }
        }
    }

    @ViewBuilder
    private func manualRow(
        name: String,
        plateforme: PlateformeSuivi,
        prefixe: String,
        marque: SourceMark,
        markedNames: Set<String>,
        etatsPlateforme: [String: CompteSuiviEtat]
    ) -> some View {
        let isDownloaded = markedNames.contains(name.lowercased())
        let target = "\(prefixe)/\(name)"
        HStack(spacing: 10) {
            SourceMarkView(mark: marque, tint: DS.accentEmphasis, size: 18)
                .frame(width: 24, height: 24)
            statusDetails(
                displayName: "@\(name)",
                etat: etatsPlateforme[name.lowercased()],
                kDriveFolder: kDriveFolder(pour: target),
                freshness: kDriveFreshness.status(for: target)
            )
            Spacer(minLength: 8)
            rowActions(
                username: name,
                isDownloaded: isDownloaded,
                plateforme: plateforme,
                downloadTarget: target
            )
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if kDriveConfigured {
                Button {
                    verifierCompte(name, plateforme: plateforme)
                } label: {
                    Label(L("Vérifier kDrive", "Check kDrive"),
                          systemImage: "arrow.clockwise.icloud")
                }
                .tint(DS.accentEmphasis)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                suiviManuelEnEdition = name
                pseudoManuelEdite = "@\(name)"
                erreurEditionManuelle = nil
            } label: {
                Label(L("Modifier", "Edit"), systemImage: "pencil")
            }
            .tint(DS.accentEmphasis)
            Button(role: .destructive) {
                supprimerSuiviManuel(name, plateforme: plateforme)
            } label: {
                Label(L("Supprimer", "Delete"), systemImage: "trash")
            }
            .tint(DS.error)
        }
    }

    @ViewBuilder
    private func statusDetails(
        displayName: String,
        etat: CompteSuiviEtat?,
        kDriveFolder: KDriveFolderItem?,
        freshness: KDriveFreshnessStatus? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .fontWeight(.medium)
                .lineLimit(1)

            if let dateLine = ligneDatesSobres(etat) {
                Text(dateLine)
                    .font(.caption2)
                    .foregroundStyle(DS.onSurfaceMuted)
                    .lineLimit(1)
            }

            if let freshness {
                HStack(spacing: 5) {
                    if freshness.isChecking {
                        ProgressView()
                            .controlSize(.mini)
                    } else if freshness.isUpToDate {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DS.calmSage)
                    } else {
                        Circle()
                            .fill(freshness.tintColor)
                            .frame(width: 6, height: 6)
                    }
                    KDriveBicolorDetail(status: freshness, font: .caption2)
                }
            } else if let folder = kDriveFolder {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DS.calmSage)
                    Text(kDriveBadgeText(folder))
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(DS.onSurfaceMuted)
            } else if kDriveConfigured, kDriveIndex != nil {
                HStack(spacing: 5) {
                    Circle()
                        .fill(DS.calmRose)
                        .frame(width: 6, height: 6)
                    Text(L("Absent de kDrive", "Not on kDrive"))
                        .lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.calmRose)
            }
        }
    }

    private func ligneDatesSobres(_ etat: CompteSuiviEtat?) -> String? {
        guard let etat else { return nil }
        switch (etat.dernierTelechargement, etat.dernierUpload) {
        case let (dl?, up?):
            return L("Téléch. \(dateCourte(dl)) · Uploadé \(dateCourte(up))",
                     "Down. \(dateCourte(dl)) · Uploaded \(dateCourte(up))")
        case let (dl?, nil):
            return L("Téléchargé le \(dateCourte(dl))", "Downloaded \(dateCourte(dl))")
        case let (nil, up?):
            return L("Uploadé le \(dateCourte(up))", "Uploaded \(dateCourte(up))")
        case (nil, nil):
            return nil
        }
    }

    @ViewBuilder
    private func rowActions(username: String, isDownloaded: Bool, plateforme: PlateformeSuivi, downloadTarget: String) -> some View {
        Button {
            toggleDownloaded(username, plateforme: plateforme)
        } label: {
            Image(systemName: isDownloaded ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isDownloaded ? DS.accentEmphasis : DS.onSurfaceMuted)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L("État de téléchargement de \(username)", "Download status for \(username)"))
        .accessibilityValue(isDownloaded
            ? L("Déjà téléchargé", "Already downloaded")
            : L("Non marqué", "Not marked"))
        .accessibilityHint(isDownloaded
            ? L("Retirer la marque", "Remove the mark")
            : L("Marquer comme déjà téléchargé", "Mark as already downloaded"))
        Button {
            onDownloadAll(downloadTarget)
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(model.running)
        .accessibilityLabel(L("Tout télécharger de \(username)", "Download all from \(username)"))
    }

    private func rechargerStockageLocal() {
        etats = SuiviStore.charger(plateforme: .reddit)
        xEtats = SuiviStore.charger(plateforme: .x)
        tikTokEtats = SuiviStore.charger(plateforme: .tiktok)
        xFriends = SuiviStore.pseudosConnus(plateforme: .x)
        tikTokFriends = SuiviStore.pseudosConnus(plateforme: .tiktok)
        let connusReddit = SuiviStore.pseudosConnus(plateforme: .reddit)
        if !connusReddit.isEmpty {
            friends = connusReddit
        }
    }

    private func ajouterSuiviManuel() {
        erreurAjoutManuel = nil
        do {
            _ = try SuiviStore.ajouterSuiviManuel(nouveauPseudoManuel, plateforme: plateforme)
            rechargerSuivisManuels(plateforme: plateforme)
            nouveauPseudoManuel = ""
        } catch {
            erreurAjoutManuel = error.localizedDescription
        }
    }

    private func enregistrerEditionManuelle() {
        guard let pseudoActuel = suiviManuelEnEdition else { return }
        erreurEditionManuelle = nil
        do {
            _ = try SuiviStore.renommerSuiviManuel(
                pseudoActuel,
                saisie: pseudoManuelEdite,
                plateforme: plateforme
            )
            rechargerSuivisManuels(plateforme: plateforme)
            suiviManuelEnEdition = nil
            pseudoManuelEdite = ""
        } catch {
            // L'alerte d'édition se ferme d'elle-même : le détail sort via errorAlert.
            erreurEditionManuelle = error.localizedDescription
        }
    }

    private func supprimerSuiviManuel(_ pseudo: String, plateforme: PlateformeSuivi) {
        SuiviStore.supprimerSuiviManuel(pseudo, plateforme: plateforme)
        rechargerSuivisManuels(plateforme: plateforme)
    }

    private func rechargerSuivisManuels(plateforme: PlateformeSuivi) {
        if plateforme == .tiktok {
            tikTokFriends = SuiviStore.pseudosConnus(plateforme: .tiktok)
            tikTokEtats = SuiviStore.charger(plateforme: .tiktok)
        } else {
            xFriends = SuiviStore.pseudosConnus(plateforme: .x)
            xEtats = SuiviStore.charger(plateforme: .x)
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        errorMessage = nil
        do {
            let result = try await model.followedUsers()
            try Task.checkCancellation()
            friends = result
            SuiviStore.enregistrerListe(result, plateforme: .reddit)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func restaurerDepuisServeur() async {
        loading = true
        defer { loading = false }
        errorMessage = nil
        await SyncService.shared.restaurer()
        etats = SuiviStore.charger(plateforme: .reddit)
        xEtats = SuiviStore.charger(plateforme: .x)
        tikTokEtats = SuiviStore.charger(plateforme: .tiktok)
        friends = SuiviStore.pseudosConnus(plateforme: .reddit)
        xFriends = SuiviStore.pseudosConnus(plateforme: .x)
        tikTokFriends = SuiviStore.pseudosConnus(plateforme: .tiktok)
    }

    @MainActor private func rafraichir() async {
        if plateforme == .reddit, session.hasSession {
            await load()
        } else {
            await restaurerDepuisServeur()
        }
        if kDriveConfigured, !model.running {
            await checkKDrive()
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Date compacte et lisible (jour, mois, heure) pour les lignes de suivi.
    private func dateCourte(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func kDriveBadgeText(_ folder: KDriveFolderItem) -> String {
        let timestamp = folder.lastModifiedAt ?? folder.updatedAt ?? 0
        guard timestamp > 0 else { return L("Dans kDrive", "On kDrive") }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return L("Importé \(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))",
                 "Imported \(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))")
    }

    private func kDriveFolder(pour target: String) -> KDriveFolderItem? {
        guard let kDriveIndex else {
            return kDriveFreshness.remoteFolder(for: target)
        }
        for candidate in KDriveFreshness.candidateFolderNames(for: target) {
            let key = FilenamePolicy.kDriveNormalizedName(candidate)
            if let folder = kDriveIndex[key] {
                return folder
            }
        }
        return nil
    }

    private func collectionPourSuivi(_ pseudo: String, plateforme: PlateformeSuivi) -> UserCollection {
        switch plateforme {
        case .reddit:
            return UserCollection(name: pseudo)
        case .x:
            return UserCollection(name: pseudo, isTwitter: true)
        case .tiktok:
            return UserCollection(name: pseudo, isTikTok: true)
        }
    }

    private func verifierCompte(_ pseudo: String, plateforme: PlateformeSuivi) {
        let collection = collectionPourSuivi(pseudo, plateforme: plateforme)
        kDriveFreshness.startSingleCheck(
            collection: collection,
            model: model,
            token: kDriveToken,
            driveId: kDriveId,
            directoryId: kDriveDirectoryId
        )
    }

    private func verifierFraicheurPlateforme() {
        let noms: [String]
        switch plateforme {
        case .reddit:
            noms = friends ?? SuiviStore.pseudosConnus(plateforme: .reddit)
        case .x:
            noms = xFriends
        case .tiktok:
            noms = tikTokFriends
        }
        let cibles = noms.map { collectionPourSuivi($0, plateforme: plateforme) }
        guard !cibles.isEmpty else { return }
        kDriveFreshness.checkAll(
            collections: cibles,
            model: model,
            token: kDriveToken,
            driveId: kDriveId,
            directoryId: kDriveDirectoryId
        )
    }

    @MainActor
    private func checkKDrive() async {
        guard kDriveConfigured, !kDriveLoading else { return }
        kDriveLoading = true
        defer { kDriveLoading = false }
        do {
            let existing = try await KDriveService.shared.fetchSubdirectories(
                token: kDriveToken,
                driveId: kDriveId,
                directoryId: kDriveDirectoryId
            )
            try Task.checkCancellation()
            var index: [String: KDriveFolderItem] = [:]
            for item in existing {
                let key = FilenamePolicy.kDriveNormalizedName(item.name)
                if index[key] == nil { index[key] = item }
            }
            kDriveIndex = index
        } catch {
            // Vérification silencieuse : les erreurs kDrive sont déjà journalisées par KDriveService.
        }
    }
}

struct FollowingUserPosts: View {
    let username: String
    var model: Downloader
    let onDownloadAll: (String) -> Void

    @State private var posts: [Post]?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var retryCount = 0

    var body: some View {
        // Keep a concrete container alive while state changes so the loading
        // task and navigation modifiers never depend on an empty Group.
        VStack(spacing: 0) {
            if loading || (posts == nil && errorMessage == nil) {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("Lecture des posts…", "Loading posts…"))
                        .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: DS.space(3)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle).foregroundStyle(DS.error)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(DS.onSurfaceMuted)
                        .multilineTextAlignment(.center)
                    Button(L("Réessayer", "Retry")) { retryCount += 1 }
                        .buttonStyle(DSPrimaryButtonStyle())
                }
                .padding(DS.space(6))
            } else if let posts {
                if posts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.largeTitle).foregroundStyle(DS.onSurfaceMuted)
                        Text(L("Aucun post accessible (flux privé ou vide).",
                               "No accessible posts (private or empty feed)."))
                            .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(DS.space(6))
                } else {
                    List(posts) { post in
                        postRow(post)
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle("u/\(username)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onDownloadAll(username)
                } label: {
                    Image(systemName: "arrow.down.circle.fill").font(.title3)
                }
                .disabled(model.running)
                .accessibilityLabel(L("Tout télécharger", "Download all"))
            }
        }
        .errorAlert(errorMessage)
        .task(id: retryCount) {
            if posts == nil { await load() }
        }
    }

    private func postRow(_ post: Post) -> some View {
        let media = MediaExtractor.extract(post.html)
        let thumbnail = MediaExtractor.previewImage(post.html)
        let gallery = media.isEmpty && GalleryFeed.linked(post.html)
        return VStack(alignment: .leading, spacing: 4) {
            if media.isEmpty {
                if gallery || thumbnail != nil {
                    FollowingMediaCard(mediaList: [], index: 0, gallery: gallery,
                                       feedID: post.id, galleryID: GalleryFeed.linkedID(post.html),
                                       thumbnail: thumbnail, model: model)
                }
            } else {
                ForEach(Array(media.enumerated()), id: \.element) { index, _ in
                    FollowingMediaCard(mediaList: media, index: index, gallery: false,
                                       feedID: post.id, galleryID: nil,
                                       thumbnail: thumbnail, model: model)
                }
            }
            Text(post.title).font(.subheadline.weight(.medium)).lineLimit(2)
            HStack(spacing: 8) {
                if let date = post.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(DS.onSurfaceMuted)
                }
                if media.isEmpty {
                    if gallery {
                        Label(L("Galerie", "Gallery"), systemImage: "photo.stack")
                            .font(.caption2).foregroundStyle(DS.accentEmphasis)
                    } else {
                        Label(thumbnail == nil
                              ? L("Sans média pris en charge", "No supported media")
                              : L("Aperçu uniquement", "Preview only"), systemImage: "slash.circle")
                            .font(.caption2).foregroundStyle(DS.onSurfaceMuted)
                    }
                } else {
                    Label(L("\(media.count) média\(media.count > 1 ? "s" : "")",
                            "\(media.count) media file\(media.count > 1 ? "s" : "")"),
                          systemImage: media.contains(where: mediaIsVideo) ? "video" : "photo")
                        .font(.caption2).foregroundStyle(DS.accentEmphasis)
                }
            }
        }
        .padding(.vertical, DS.space(1))
    }

    private func mediaIsVideo(_ media: Media) -> Bool {
        switch media {
        case .redditVideo, .redgifs: return true
        case .direct(let url): return isVideo(url)
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        errorMessage = nil
        do {
            let result = try await model.previewPosts(username: username)
            try Task.checkCancellation()
            posts = result
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct FollowingPreviewSelection: Identifiable {
    let urls: [URL]
    let selected: URL
    let id = UUID()
}

private struct FollowingMediaCard: View {
    let mediaList: [Media]
    let index: Int
    let gallery: Bool
    let feedID: String
    let galleryID: String?
    let thumbnail: URL?
    var model: Downloader
    @State private var image: UIImage?
    @State private var imageLoaded = false
    @State private var opening = false
    @State private var openRequest = 0
    @State private var errorMessage: String?
    @State private var selection: FollowingPreviewSelection?
    @State private var temporaryURLs: [URL] = []

    private var item: Media? {
        mediaList.indices.contains(index) ? mediaList[index] : nil
    }

    private var imageURL: URL? {
        if case .direct(let url)? = item, !isVideo(url) { return url }
        return thumbnail
    }

    private var video: Bool {
        switch item {
        case .redditVideo?, .redgifs?: return true
        case .direct(let url)?: return isVideo(url)
        case nil: return false
        }
    }

    /// Une couverture de galerie seule devient ouvrable après résolution du
    /// JSON du post ; une vignette sans média reste un affichage passif.
    private var openable: Bool { item != nil || gallery }

    var body: some View {
        VStack(spacing: 6) {
            if openable {
                Button {
                    opening = true
                    openRequest += 1
                } label: {
                    artwork
                }
                .buttonStyle(.plain)
                .disabled(opening)
                .accessibilityLabel(gallery && item == nil
                    ? L("Ouvrir la galerie", "Open gallery")
                    : video ? L("Lire la vidéo", "Play video") : L("Agrandir l’image", "Enlarge image"))
            } else {
                // A display-only thumbnail is not a disabled control: keep its colors.
                artwork
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Aperçu uniquement", "Preview only"))
                    .accessibilityAddTraits(.isImage)
            }
        }
        .errorAlert(errorMessage)
        .task(id: imageURL) {
            image = nil
            imageLoaded = false
            defer { imageLoaded = true }
            guard let imageURL else { return }
            do {
                let decoded = try await model.previewThumbnail(imageURL)
                try Task.checkCancellation()
                image = decoded
            } catch {
                // A missing thumbnail does not prevent opening the original.
            }
        }
        .task(id: openRequest) {
            guard openRequest > 0, opening, openable else { return }
            defer { opening = false }
            errorMessage = nil
            do {
                var list = mediaList
                if list.isEmpty, gallery {
                    list = try await model.previewGalleryMedia(feedID: feedID, galleryID: galleryID)
                }
                guard !list.isEmpty else {
                    throw NetworkError.invalid(L("Aucun média trouvé dans la galerie.", "No media found in the gallery."))
                }
                let slots = try await model.previewMediaList(list)
                // Décision Jev A bug 12 : si annulé entre la fin du téléchargement
                // et l'affichage, on jette tout de suite au lieu de perdre les fichiers.
                if Task.isCancelled {
                    for url in slots.compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
                    throw CancellationError()
                }
                let urls = slots.compactMap { $0 }
                guard !urls.isEmpty else {
                    throw NetworkError.invalid(L("Média indisponible.", "Media unavailable."))
                }
                // Position du média touché parmi les résolus ; un média manquant
                // retombe sur le succès le plus proche avant lui.
                let before = slots.prefix(index).compactMap { $0 }.count
                let selected = (index < slots.count ? slots[index] : nil)
                    ?? urls[min(before, urls.count - 1)]
                temporaryURLs = urls
                selection = FollowingPreviewSelection(urls: urls, selected: selected)
            } catch {
                clearTemporaryFiles()
                if !Task.isCancelled, !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
        .fullScreenCover(item: $selection, onDismiss: clearTemporaryFiles) { preview in
            MediaPreview(urls: preview.urls, selectedURL: preview.selected)
        }
        .onDisappear {
            if selection == nil { clearTemporaryFiles() }
        }
    }

    private var artwork: some View {
        ZStack {
            DS.surface
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if !imageLoaded {
                ProgressView()
            } else {
                Label(L("Aperçu indisponible", "Preview unavailable"), systemImage: video ? "video" : "photo")
                    .font(.caption).foregroundStyle(DS.onSurfaceMuted)
            }
            if opening {
                ProgressView().padding(DS.space(3)).background(.regularMaterial, in: Circle())
            } else if video {
                Image(systemName: "play.circle.fill").font(.largeTitle)
                    .foregroundStyle(DS.onScrim)
                    .padding(DS.space(1))
                    .background(DS.scrim, in: Circle())
            }
        }
        .frame(maxWidth: .infinity).frame(height: 240)
        .clipped().contentShape(Rectangle())
    }

    private func clearTemporaryFiles() {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs = []
    }
}

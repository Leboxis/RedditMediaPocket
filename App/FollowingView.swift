import SwiftUI
import MediaCore
import Combine
import UIKit
import ImageIO

struct FollowingView: View {
    @ObservedObject var model: Downloader
    let onDownloadAll: (String) -> Void

    @ObservedObject private var session = RedditSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var plateforme: PlateformeSuivi = .reddit
    @State private var friends: [String]?
    @State private var xFriends: [String] = []
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var retryCount = 0
    @State private var kDriveFolders: [String: KDriveFolderItem]?
    @State private var kDriveLoading = false
    @State private var kDriveError: String?
    @State private var ajoutXPresente = false
    @State private var nouveauPseudoX = ""
    @State private var erreurAjoutX: String?
    @AppStorage("following.downloadedUsernames") private var downloadedUsernamesData = Data()
    @AppStorage("following.x.downloadedUsernames") private var xDownloadedUsernamesData = Data()
    /// Dates de téléchargement et d'upload, synchronisées avec le serveur.
    @State private var etats: [String: CompteSuiviEtat] = [:]
    @State private var xEtats: [String: CompteSuiviEtat] = [:]
    @AppStorage("kDriveApiToken") private var kDriveToken = ""
    @AppStorage("kDriveId") private var kDriveId = ""
    @AppStorage("kDriveDirectoryId") private var kDriveDirectoryId = "1"

    private var kDriveConfigured: Bool {
        !kDriveToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !kDriveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func downloadedUsernames(pour plateforme: PlateformeSuivi) -> Set<String> {
        let data = plateforme == .reddit ? downloadedUsernamesData : xDownloadedUsernamesData
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
        if plateforme == .reddit {
            downloadedUsernamesData = data
            etats = SuiviStore.charger(plateforme: .reddit)
        } else {
            xDownloadedUsernamesData = data
            xEtats = SuiviStore.charger(plateforme: .x)
        }
        // La coche fait partie de l'état synchronisé : on pousse vers Cloudflare.
        NotificationCenter.default.post(name: .pocketDonneesDidChange, object: nil)
    }

    private var hasSyncKey: Bool {
        KeychainStore.get() != nil
    }

    private var activeListIsEmpty: Bool {
        switch plateforme {
        case .reddit: return (friends ?? []).isEmpty
        case .x: return xFriends.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L("Plateforme", "Platform"), selection: $plateforme) {
                    Text("Reddit").tag(PlateformeSuivi.reddit)
                    Text("X").tag(PlateformeSuivi.x)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DS.space(4))
                .padding(.vertical, DS.space(2))

                switch plateforme {
                case .reddit:
                    redditContent
                case .x:
                    xContent
                }
            }
            .navigationTitle(L("Suivis", "Following"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await checkKDrive() }
                    } label: {
                        if kDriveLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "externaldrive")
                        }
                    }
                    .disabled(!kDriveConfigured || kDriveLoading || model.running || activeListIsEmpty)
                    .accessibilityLabel(L("Vérifier sur kDrive", "Check on kDrive"))
                }
                if plateforme == .x {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            nouveauPseudoX = ""
                            ajoutXPresente = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(L("Ajouter un compte X", "Add X account"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Fermer", "Close")) { dismiss() }
                }
            }
            .alert(L("Ajouter un suivi X", "Add X follow"), isPresented: $ajoutXPresente) {
                TextField(L("@pseudo ou lien x.com/…", "@username or x.com/… link"), text: $nouveauPseudoX)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L("Ajouter", "Add")) { ajouterSuiviX() }
                Button(L("Annuler", "Cancel"), role: .cancel) { nouveauPseudoX = "" }
            } message: {
                Text(L("Ajoute un compte X manuellement pour suivre son statut et le synchroniser.",
                       "Add an X account manually to track its status and sync it."))
            }
        }
        .tint(DS.accentEmphasis)
        .errorAlert(erreurAjoutX ?? kDriveError ?? errorMessage) {
            erreurAjoutX = nil
        }
        .task(id: "\(session.hasSession)-\(retryCount)") {
            rechargerStockageLocal()
            let connus = SuiviStore.pseudosConnus(plateforme: .reddit)
            if session.hasSession {
                await load()
            } else {
                errorMessage = nil
                if (connus.isEmpty && xFriends.isEmpty || retryCount > 0), hasSyncKey {
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
            xFriends = SuiviStore.pseudosConnus(plateforme: .x)
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
                Section {
                    ForEach(friends, id: \.self) { name in
                        let isDownloaded = markedNames.contains(name.lowercased())
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
                                        kDriveFolder: kDriveFolders?[name]
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
                    .font(.system(size: 36)).foregroundStyle(DS.error)
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
                    .font(.system(size: 40)).foregroundStyle(DS.onSurfaceMuted)
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
                    .font(.system(size: 40)).foregroundStyle(DS.onSurfaceMuted)
                Text(L("Aucun compte suivi (ou liste privée indisponible).",
                       "No followed accounts (or the list is unavailable)."))
                    .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(DS.space(6))
        }
    }

    @ViewBuilder
    private var xContent: some View {
        let markedNames = downloadedUsernames(pour: .x)
        if xFriends.isEmpty {
            VStack(spacing: 12) {
                SourceMarkView(mark: .x, tint: DS.onSurfaceMuted, size: 36)
                Text(L("Aucun compte X suivi. Ajoute un nom d'utilisateur manuellement pour suivre son statut et le synchroniser.",
                       "No followed X accounts. Add a username manually to track its status and sync it."))
                    .font(.footnote).foregroundStyle(DS.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                Button(L("Ajouter un compte X", "Add X account")) {
                    nouveauPseudoX = ""
                    ajoutXPresente = true
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
                Section {
                    ForEach(xFriends, id: \.self) { name in
                        let isDownloaded = markedNames.contains(name.lowercased())
                        let target = "tw/\(name)"
                        HStack(spacing: 10) {
                            SourceMarkView(mark: .x, tint: DS.accentEmphasis, size: 18)
                                .frame(width: 24, height: 24)
                            statusDetails(
                                displayName: "@\(name)",
                                etat: xEtats[name.lowercased()],
                                kDriveFolder: kDriveFolders?[target]
                            )
                            Spacer(minLength: 8)
                            rowActions(
                                username: name,
                                isDownloaded: isDownloaded,
                                plateforme: .x,
                                downloadTarget: target
                            )
                        }
                    }
                    .onDelete(perform: supprimerSuivisX)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await restaurerDepuisServeur() }
        }
    }

    @ViewBuilder
    private func statusDetails(displayName: String, etat: CompteSuiviEtat?, kDriveFolder: KDriveFolderItem?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName).fontWeight(.medium).lineLimit(1)
            if let etat {
                if let date = etat.dernierTelechargement {
                    Text(L("Téléchargé le \(dateCourte(date))", "Downloaded \(dateCourte(date))"))
                        .font(.caption2)
                        .foregroundStyle(DS.onSurfaceMuted)
                        .lineLimit(1)
                }
                if let date = etat.dernierUpload {
                    Text(L("Uploadé le \(dateCourte(date))", "Uploaded \(dateCourte(date))"))
                        .font(.caption2)
                        .foregroundStyle(DS.onSurfaceMuted)
                        .lineLimit(1)
                }
            }
            if let folder = kDriveFolder {
                Label(kDriveBadgeText(folder), systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(DS.accentEmphasis)
                    .lineLimit(1)
            }
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
        xFriends = SuiviStore.pseudosConnus(plateforme: .x)
        let connusReddit = SuiviStore.pseudosConnus(plateforme: .reddit)
        if !connusReddit.isEmpty {
            friends = connusReddit
        }
    }

    private func ajouterSuiviX() {
        erreurAjoutX = nil
        do {
            _ = try SuiviStore.ajouterSuiviX(nouveauPseudoX)
            xFriends = SuiviStore.pseudosConnus(plateforme: .x)
            nouveauPseudoX = ""
        } catch {
            erreurAjoutX = error.localizedDescription
        }
    }

    private func supprimerSuivisX(_ offsets: IndexSet) {
        let aSupprimer = offsets.map { xFriends[$0] }
        for pseudo in aSupprimer {
            SuiviStore.supprimerSuiviX(pseudo)
        }
        xFriends = SuiviStore.pseudosConnus(plateforme: .x)
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
        friends = SuiviStore.pseudosConnus(plateforme: .reddit)
        xFriends = SuiviStore.pseudosConnus(plateforme: .x)
    }

    @MainActor private func rafraichir() async {
        if plateforme == .reddit, session.hasSession {
            await load()
        } else {
            await restaurerDepuisServeur()
        }
    }

    /// Date compacte et lisible (jour, mois, heure) pour les lignes de suivi.
    private func dateCourte(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func kDriveBadgeText(_ folder: KDriveFolderItem) -> String {
        let timestamp = folder.lastModifiedAt ?? folder.updatedAt ?? 0
        guard timestamp > 0 else { return L("Dans kDrive", "On kDrive") }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return L("Importé \(formatter.localizedString(for: date, relativeTo: Date()))",
                 "Imported \(formatter.localizedString(for: date, relativeTo: Date()))")
    }

    private func checkKDrive() async {
        let targets: [String]
        switch plateforme {
        case .reddit:
            guard let friends, !friends.isEmpty else { return }
            targets = friends
        case .x:
            guard !xFriends.isEmpty else { return }
            targets = xFriends.map { "tw/\($0)" }
        }
        kDriveLoading = true
        kDriveError = nil
        defer { kDriveLoading = false }
        do {
            let folders = try await KDriveService.shared.folderStatus(
                token: kDriveToken,
                driveId: kDriveId,
                parentDirectoryId: kDriveDirectoryId,
                names: targets
            )
            var merged = kDriveFolders ?? [:]
            for target in targets {
                merged[target] = folders[target]
            }
            kDriveFolders = merged
        } catch {
            kDriveError = error.localizedDescription
        }
    }
}

struct FollowingUserPosts: View {
    let username: String
    @ObservedObject var model: Downloader
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
                        .font(.system(size: 36)).foregroundStyle(DS.error)
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
                            .font(.system(size: 40)).foregroundStyle(DS.onSurfaceMuted)
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
                ForEach(Array(media.enumerated()), id: \.offset) { index, _ in
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
    @ObservedObject var model: Downloader
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
                Image(systemName: "play.circle.fill").font(.system(size: 44))
                    .foregroundStyle(Color.white)
                    .padding(DS.space(1))
                    .background(Color.black.opacity(0.45), in: Circle())
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

import SwiftUI
import MediaCore
import UIKit
import ImageIO
import AVKit

/// Entrée légère du feed : construite de façon synchrone par simple parse
/// local du HTML (aucun accès réseau). L'original est résolu paresseusement
/// par chaque carte à son apparition (décision Jev C : hybride progressif).
struct SavedFeedEntry: Identifiable {
    let id: String
    let post: Post
    let media: Media?
    let thumbnail: URL?
    let isGallery: Bool
    let galleryID: String?
}

private func savedFeedEntries(from posts: [Post]) -> [SavedFeedEntry] {
    var entries: [SavedFeedEntry] = []
    for post in posts {
        let media = MediaExtractor.extract(post.html)
        let thumbnail = MediaExtractor.previewImage(post.html)
        if !media.isEmpty {
            for (index, m) in media.enumerated() {
                entries.append(SavedFeedEntry(id: "\(post.id)-\(index)", post: post, media: m, thumbnail: thumbnail, isGallery: false, galleryID: nil))
            }
        } else if GalleryFeed.linked(post.html) {
            entries.append(SavedFeedEntry(id: "\(post.id)-gallery", post: post, media: nil, thumbnail: thumbnail, isGallery: true, galleryID: GalleryFeed.linkedID(post.html)))
        }
    }
    return entries
}

/// Réserve de fichiers temporaires du feed : les originaux résolus sont
/// conservés pendant toute la durée du feed (retour arrière instantané,
/// sans retéléchargement) et purgés à la fermeture.
@MainActor final class FeedTempBin: ObservableObject {
    private(set) var urls: [URL] = []
    func add(_ urls: [URL]) { self.urls.append(contentsOf: urls) }
    func clear() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
    }
}

/// Vignette d'une entrée : direct non-vidéo sinon aperçu RSS.
private func feedThumbURL(for entry: SavedFeedEntry) -> URL? {
    if case .direct(let url)? = entry.media, !isVideo(url) { return url }
    return entry.thumbnail
}

/// Cache partagé des originaux préchargés (décision Jev B) : les URLs
/// temporaires résolues sont stockées par entry.id pour que FeedCard
/// réutilise le préchargement sans retélécharger. Les tâches en cours
/// sont dédupliquées : préchargement et carte attendent la même tâche.
@MainActor final class FeedPreloadStore: ObservableObject {
    private var cache: [String: [URL]] = [:]
    private var tasks: [String: Task<[URL], Error>] = [:]

    func cached(_ id: String) -> [URL]? { cache[id] }

    func resolve(entry: SavedFeedEntry, model: Downloader, bin: FeedTempBin) async throws -> [URL] {
        if let hit = cache[entry.id] { return hit }
        if let running = tasks[entry.id] { return try await running.value }
        let task = Task<[URL], Error> {
            let list: [Media]
            if let media = entry.media {
                list = [media]
            } else {
                list = try await model.previewGalleryMedia(feedID: entry.post.id, galleryID: entry.galleryID)
            }
            let slots = try await model.previewMediaList(list)
            let urls = slots.compactMap { $0 }
            guard !urls.isEmpty else { throw NetworkError.invalid(L("Média indisponible.", "Media unavailable.")) }
            return urls
        }
        tasks[entry.id] = task
        do {
            let urls = try await task.value
            cache[entry.id] = urls
            bin.add(urls)
            tasks[entry.id] = nil
            return urls
        } catch {
            tasks[entry.id] = nil
            throw error
        }
    }

    /// Précharge les vignettes (cache NSCache) + originaux des entrées
    /// suivantes. Appelé à chaque changement de carte visible.
    func prefetchNext(entries: [SavedFeedEntry], visibleID: SavedFeedEntry.ID?, count: Int, model: Downloader, bin: FeedTempBin) async {
        guard let visibleID, let current = entries.firstIndex(where: { $0.id == visibleID }) else { return }
        for offset in 1...count {
            if Task.isCancelled { return }
            let index = current + offset
            guard entries.indices.contains(index) else { return }
            let entry = entries[index]
            if cache[entry.id] != nil || tasks[entry.id] != nil { continue }
            if let thumbURL = feedThumbURL(for: entry) {
                _ = try? await model.previewImageData(thumbURL)
            }
            if Task.isCancelled { return }
            _ = try? await resolve(entry: entry, model: model, bin: bin)
        }
    }
}

struct SavedPostsView: View {
    @ObservedObject var model: Downloader
    let onDownloadAll: (String) -> Void

    @ObservedObject private var session = RedditSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var posts: [Post]?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var retryCount = 0
    @State private var showFeed = false



    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !session.hasSession {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark.badge.questionmark")
                            .font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text(L("Connecte-toi à Reddit dans les Réglages pour voir tes posts sauvegardés.",
                               "Sign in to Reddit in Settings to see your saved posts."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else if loading || (posts == nil && errorMessage == nil) {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L("Chargement des sauvegardés…", "Loading saved posts…"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36)).foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L("Réessayer", "Retry")) { retryCount += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                } else if let posts {
                    if posts.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bookmark.slash")
                                .font(.system(size: 40)).foregroundStyle(.tertiary)
                            Text(L("Aucun post sauvegardé.",
                                   "No saved posts."))
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                    } else if showFeed {
                        SavedFeedView(posts: posts, model: model)
                    } else {
                        List(posts) { post in
                            SavedPostRow(post: post, model: model)
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle(L("Sauvegardés", "Saved"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Fermer", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showFeed.toggle()
                    } label: {
                        Image(systemName: showFeed ? "square.grid.3x3" : "play.rectangle")
                    }
                    .accessibilityLabel(showFeed
                        ? L("Vue grille", "Grid view")
                        : L("Vue défilement", "Feed view"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onDownloadAll("saved")
                    } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.title3)
                    }
                    .disabled(model.running || !session.hasSession)
                    .accessibilityLabel(L("Tout télécharger", "Download all"))
                }
            }
        }
        .tint(.orange)
        .task(id: "\(session.hasSession)-\(retryCount)") {
            if session.hasSession, posts == nil { await load() }
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        errorMessage = nil
        do {
            let result = try await model.previewSavedPosts()
            try Task.checkCancellation()
            posts = result
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// Feed plein écran à défilement vertical (décision Jev A) : paging natif
/// iOS 17, repli ScrollView vertical simple sur iOS 16. Les entrées sont
/// affichées immédiatement ; chaque carte résout son original en lazy.
struct SavedFeedView: View {
    let posts: [Post]
    @ObservedObject var model: Downloader
    @StateObject private var bin = FeedTempBin()
    @StateObject private var preload = FeedPreloadStore()
    @State private var visibleID: SavedFeedEntry.ID?
    @State private var entries: [SavedFeedEntry] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.white.opacity(0.4))
                    Text(L("Aucun média à afficher dans le feed.", "No media to show in the feed."))
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            } else if #available(iOS 17, *) {
                PagedFeed17(entries: entries, visibleID: $visibleID, model: model, bin: bin, preload: preload)
            } else {
                PagedFeed16(entries: entries, visibleID: $visibleID, model: model, bin: bin, preload: preload)
            }
        }
        .onDisappear { bin.clear() }
        .task(id: posts.count) { entries = savedFeedEntries(from: posts) }
        .task(id: visibleID) {
            await preload.prefetchNext(entries: entries, visibleID: visibleID, count: 5, model: model, bin: bin)
        }
    }
}

@available(iOS 17, *)
private struct PagedFeed17: View {
    let entries: [SavedFeedEntry]
    @Binding var visibleID: SavedFeedEntry.ID?
    @ObservedObject var model: Downloader
    @ObservedObject var bin: FeedTempBin
    @ObservedObject var preload: FeedPreloadStore

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    FeedCard(entry: entry, isActive: entry.id == visibleID, model: model, bin: bin, preload: preload)
                        .containerRelativeFrame(.vertical)
                        .id(entry.id)
                        .scrollTransition(.animated(.smooth), axis: .vertical) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.97)
                                .opacity(phase.isIdentity ? 1 : 0.7)
                                .saturation(phase.isIdentity ? 1 : 0.9)
                        }
                        .onAppear { visibleID = entry.id }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleID)
        .scrollIndicators(.hidden)
        .animation(.smooth(duration: 0.28), value: visibleID)
        .ignoresSafeArea()
    }
}

private struct PagedFeed16: View {
    let entries: [SavedFeedEntry]
    @Binding var visibleID: SavedFeedEntry.ID?
    @ObservedObject var model: Downloader
    @ObservedObject var bin: FeedTempBin
    @ObservedObject var preload: FeedPreloadStore

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        FeedCard(entry: entry, isActive: entry.id == visibleID, model: model, bin: bin, preload: preload)
                            .frame(height: proxy.size.height)
                            .scaleEffect(entry.id == visibleID ? 1 : 0.98)
                            .opacity(entry.id == visibleID ? 1 : 0.85)
                            .animation(.smooth(duration: 0.25), value: visibleID)
                            .onAppear { visibleID = entry.id }
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct FeedCard: View {
    let entry: SavedFeedEntry
    let isActive: Bool
    @ObservedObject var model: Downloader
    @ObservedObject var bin: FeedTempBin
    @ObservedObject var preload: FeedPreloadStore
    @State private var thumb: UIImage?
    @State private var full: UIImage?
    @State private var videoURL: URL?
    @State private var failed = false

    private var thumbURL: URL? { feedThumbURL(for: entry) }

    /// Étape d'affichage : pilote le fondu entre vignette / HD / vidéo.
    private var stageKey: String { "\(thumb != nil)-\(full != nil)-\(videoURL != nil)-\(failed)" }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let videoURL {
                AutoPlayVideo(url: videoURL, active: isActive)
                    .transition(.opacity)
            } else if let full {
                Image(uiImage: full).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else if let thumb {
                ZStack {
                    Image(uiImage: thumb).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 8) {
                        Spacer()
                        ProgressView().tint(.white)
                        Text(L("Chargement HD…", "Loading HD…"))
                            .font(.caption2).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                    }
                }
                .transition(.opacity)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
                    Text(L("Média indisponible", "Media unavailable"))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.post.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(radius: 2)
                if let date = entry.post.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(radius: 1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120),
                alignment: .bottom
            )
            .drawingGroup()
        }
        .clipped()
        .animation(.smooth(duration: 0.25), value: stageKey)
        .task(id: entry.id) { await load() }
    }

    private func load() async {
        if let thumbURL {
            if let data = try? await model.previewImageData(thumbURL),
               !Task.isCancelled,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960
               ] as CFDictionary) {
                thumb = UIImage(cgImage: cg)
            }
        }
        guard !Task.isCancelled else { return }
        do {
            let urls = try await preload.resolve(entry: entry, model: model, bin: bin)
            guard !Task.isCancelled else { return }
            guard let url = urls.first else { failed = true; return }
            let isVid: Bool = {
                if let media = entry.media {
                    switch media {
                    case .redditVideo, .redgifs: return true
                    case .direct(let u): return isVideo(u)
                    }
                }
                return isVideo(url)
            }()
            if isVid {
                videoURL = url
            } else {
                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2048
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: cg)
                }.value
                guard !Task.isCancelled else { return }
                if let image { full = image } else { failed = true }
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct AutoPlayVideo: UIViewControllerRepresentable {
    let url: URL
    let active: Bool

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = context.coordinator.player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspectFill
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.setActive(active)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player.pause()
        controller.player = nil
    }

    final class Coordinator {
        let player: AVPlayer
        private var active = false
        private var observer: NSObjectProtocol?

        init(url: URL) {
            player = AVPlayer(url: url)
            player.actionAtItemEnd = .none
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func setActive(_ value: Bool) {
            guard active != value else { return }
            active = value
            if value {
                player.play()
            } else {
                player.pause()
            }
        }
    }
}

private struct SavedPostRow: View {
    let post: Post
    @ObservedObject var model: Downloader

    var body: some View {
        let media = MediaExtractor.extract(post.html)
        let thumbnail = MediaExtractor.previewImage(post.html)
        let gallery = media.isEmpty && GalleryFeed.linked(post.html)
        return VStack(alignment: .leading, spacing: 4) {
            if media.isEmpty {
                if gallery || thumbnail != nil {
                    SavedMediaCard(mediaList: [], index: 0, gallery: gallery,
                                   feedID: post.id, galleryID: GalleryFeed.linkedID(post.html),
                                   thumbnail: thumbnail, model: model)
                }
            } else {
                ForEach(Array(media.enumerated()), id: \.offset) { index, _ in
                    SavedMediaCard(mediaList: media, index: index, gallery: false,
                                   feedID: post.id, galleryID: nil,
                                   thumbnail: thumbnail, model: model)
                }
            }
            Text(post.title).font(.subheadline.weight(.medium)).lineLimit(2)
            HStack(spacing: 8) {
                if let date = post.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if media.isEmpty {
                    if gallery {
                        Label(L("Galerie", "Gallery"), systemImage: "photo.stack")
                            .font(.caption2).foregroundStyle(.orange)
                    } else {
                        Label(thumbnail == nil
                              ? L("Sans média pris en charge", "No supported media")
                              : L("Aperçu uniquement", "Preview only"), systemImage: "slash.circle")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Label(L("\(media.count) média\(media.count > 1 ? "s" : "")",
                            "\(media.count) media file\(media.count > 1 ? "s" : "")"),
                          systemImage: media.contains(where: mediaIsVideo) ? "video" : "photo")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func mediaIsVideo(_ media: Media) -> Bool {
        switch media {
        case .redditVideo, .redgifs: return true
        case .direct(let url): return isVideo(url)
        }
    }
}

private struct SavedPreviewSelection: Identifiable {
    let urls: [URL]
    let selected: URL
    let id = UUID()
}

private struct SavedMediaCard: View {
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
    @State private var selection: SavedPreviewSelection?
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
                    : video ? L("Lire la vidéo", "Play video") : L("Agrandir l'image", "Enlarge image"))
            } else {
                artwork
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Aperçu uniquement", "Preview only"))
                    .accessibilityAddTraits(.isImage)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: imageURL) {
            image = nil
            imageLoaded = false
            defer { imageLoaded = true }
            guard let imageURL else { return }
            do {
                let data = try await model.previewImageData(imageURL)
                try Task.checkCancellation()
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 960
                   ] as CFDictionary) {
                    image = UIImage(cgImage: thumbnail)
                }
            } catch {
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
                let urls = slots.compactMap { $0 }
                guard !urls.isEmpty else {
                    throw NetworkError.invalid(L("Média indisponible.", "Media unavailable."))
                }
                let before = slots.prefix(index).compactMap { $0 }.count
                let selected = (index < slots.count ? slots[index] : nil)
                    ?? urls[min(before, urls.count - 1)]
                temporaryURLs = urls
                selection = SavedPreviewSelection(urls: urls, selected: selected)
            } catch {
                clearTemporaryFiles()
                if !Task.isCancelled { errorMessage = error.localizedDescription }
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
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if !imageLoaded {
                ProgressView()
            } else {
                Label(L("Aperçu indisponible", "Preview unavailable"), systemImage: video ? "video" : "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if opening {
                ProgressView().padding(12).background(.regularMaterial, in: Circle())
            } else if video {
                Image(systemName: "play.circle.fill").font(.system(size: 44))
                    .foregroundStyle(.white).shadow(radius: 3)
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

import SwiftUI
import MediaCore
import UIKit
import ImageIO
import AVKit

struct SavedFeedItem: Identifiable {
    let id = UUID()
    let post: Post
    let media: Media
    let galleryMedia: [Media]
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

    private var feedItems: [SavedFeedItem] {
        guard let posts else { return [] }
        var items: [SavedFeedItem] = []
        for post in posts {
            let media = MediaExtractor.extract(post.html)
            let gallery = media.isEmpty && GalleryFeed.linked(post.html)
            if !media.isEmpty {
                for m in media {
                    items.append(SavedFeedItem(post: post, media: m, galleryMedia: []))
                }
            } else if gallery {
                items.append(SavedFeedItem(post: post, media: .direct(URL(string: "about:blank")!), galleryMedia: []))
            }
        }
        return items
    }

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
                        SavedFeedView(items: feedItems, posts: posts, model: model)
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

struct SavedFeedView: View {
    let items: [SavedFeedItem]
    let posts: [Post]
    @ObservedObject var model: Downloader
    @State private var resolvedItems: [ResolvedFeedItem] = []
    @State private var resolving = false

    struct ResolvedFeedItem: Identifiable {
        let id = UUID()
        let post: Post
        let url: URL
        let isVideo: Bool
        var temporaryURLs: [URL] = []
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if resolving || resolvedItems.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(L("Préparation des médias…", "Preparing media…"))
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                TabView {
                    ForEach(Array(resolvedItems.enumerated()), id: \.element.id) { index, item in
                        FeedCard(item: item, isActive: true, model: model)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
            }
        }
        .task {
            await resolveAll()
        }
    }

    private func resolveAll() async {
        guard !resolving else { return }
        resolving = true
        defer { resolving = false }
        var resolved: [ResolvedFeedItem] = []
        for post in posts {
            let media = MediaExtractor.extract(post.html)
            let gallery = media.isEmpty && GalleryFeed.linked(post.html)
            var mediaList = media
            if mediaList.isEmpty, gallery {
                mediaList = (try? await model.previewGalleryMedia(
                    feedID: post.id,
                    galleryID: GalleryFeed.linkedID(post.html)
                )) ?? []
            }
            guard !mediaList.isEmpty else { continue }
            let slots = (try? await model.previewMediaList(mediaList)) ?? []
            var tempURLs: [URL] = []
            for slot in slots.compactMap({ $0 }) {
                tempURLs.append(slot)
            }
            for (i, m) in mediaList.enumerated() {
                guard i < slots.count, let url = slots[i] else { continue }
                let vid: Bool
                switch m {
                case .redditVideo, .redgifs: vid = true
                case .direct(let u): vid = isVideo(u)
                }
                resolved.append(ResolvedFeedItem(
                    post: post, url: url, isVideo: vid, temporaryURLs: tempURLs
                ))
            }
        }
        resolvedItems = resolved
    }
}

private struct FeedCard: View {
    let item: SavedFeedView.ResolvedFeedItem
    let isActive: Bool
    @ObservedObject var model: Downloader

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            if item.isVideo {
                AutoPlayVideo(url: item.url, active: isActive)
            } else {
                AsyncImage(url: item.url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                    case .empty:
                        ProgressView().tint(.white)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.post.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(radius: 2)
                if let date = item.post.publishedAt {
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
        }
        .clipped()
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

        init(url: URL) { player = AVPlayer(url: url) }

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

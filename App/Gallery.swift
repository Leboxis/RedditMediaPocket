import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import AVKit
import WebKit

func isVideo(_ url: URL) -> Bool { ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) }

private final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()
    private let cache = NSCache<NSURL, UIImage>()
    private init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func image(for url: URL) async -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let work = Task.detached(priority: .utility) { () -> UIImage? in
            if isVideo(url) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 360, height: 360)
                guard let result = try? await generator.image(at: .zero) else { return nil }
                return UIImage(cgImage: result.image)
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 360,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }
        let image = await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
        if let image, !Task.isCancelled {
            cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}

struct MediaThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        ZStack {
                            if loaded {
                                Image(systemName: isVideo(url) ? "video" : "photo").foregroundStyle(.secondary)
                            } else { ProgressView().controlSize(.small) }
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if isVideo(url) {
                    Image(systemName: "play.fill").font(.caption2)
                        .foregroundStyle(.white).padding(7)
                        .background(.black.opacity(0.45), in: Circle()).padding(7)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: url) {
                image = await Thumbnails.shared.image(for: url)
                loaded = true
            }
    }
}

struct MediaPreview: View {
    let urls: [URL]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss
    init(urls: [URL], selectedURL: URL) {
        self.urls = urls
        _index = State(initialValue: urls.firstIndex(of: selectedURL) ?? 0)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Fermer")
                Button {
                    if index > 0 { index -= 1 }
                } label: { Image(systemName: "chevron.backward").frame(width: 30, height: 44) }
                    .disabled(index == 0)
                    .accessibilityLabel("Média précédent")
                VStack(spacing: 3) {
                    Text(urls[index].lastPathComponent).font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(index + 1) / \(urls.count)").font(.caption).foregroundStyle(.gray).monospacedDigit()
                }.frame(maxWidth: .infinity).multilineTextAlignment(.center)
                Button {
                    if index < urls.count - 1 { index += 1 }
                } label: { Image(systemName: "chevron.forward").frame(width: 30, height: 44) }
                    .disabled(index == urls.count - 1)
                    .accessibilityLabel("Média suivant")
                ShareLink(item: urls[index]) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }.accessibilityLabel("Partager ce média")
            }.padding(.horizontal, 8).padding(.vertical, 4)
            MediaPager(urls: urls, index: $index)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white).tint(.white)
        .preferredColorScheme(.dark)
    }
}

private struct MediaPager: UIViewControllerRepresentable {
    let urls: [URL]
    @Binding var index: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black
        context.coordinator.attach(to: pager)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfNeeded(pager: pager)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MediaPager
        private var position: Int
        private var hosts: [UIHostingController<MediaPage>?]

        init(parent: MediaPager) {
            self.parent = parent
            self.position = min(max(parent.index, 0), max(parent.urls.count - 1, 0))
            self.hosts = Array(repeating: nil, count: parent.urls.count)
        }

        private func host(for slot: Int) -> UIHostingController<MediaPage> {
            if let existing = hosts[slot] { return existing }
            let host = UIHostingController(rootView: MediaPage(url: parent.urls[slot], active: slot == position))
            host.view.backgroundColor = .black
            hosts[slot] = host
            return host
        }

        private func slot(of controller: UIViewController) -> Int? {
            hosts.firstIndex { $0 === controller }
        }

        private func refreshActiveStates() {
            for slot in hosts.indices where hosts[slot] != nil {
                hosts[slot]?.rootView = MediaPage(url: parent.urls[slot], active: slot == position)
            }
        }

        private func trimDistantHosts() {
            for slot in hosts.indices where abs(slot - position) > 1 { hosts[slot] = nil }
        }

        func attach(to pager: UIPageViewController) {
            guard !parent.urls.isEmpty else { return }
            pager.setViewControllers([host(for: position)], direction: .forward, animated: false)
        }

        func syncIfNeeded(pager: UIPageViewController) {
            guard position != parent.index, parent.index >= 0, parent.index < parent.urls.count else { return }
            let direction: UIPageViewController.NavigationDirection = parent.index > position ? .forward : .reverse
            position = parent.index
            pager.setViewControllers([host(for: position)], direction: direction, animated: true)
            refreshActiveStates()
            trimDistantHosts()
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let slot = slot(of: viewController), slot > 0 else { return nil }
            return host(for: slot - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let slot = slot(of: viewController), slot < parent.urls.count - 1 else { return nil }
            return host(for: slot + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first, let slot = slot(of: current) else { return }
            position = slot
            parent.index = slot
            refreshActiveStates()
            trimDistantHosts()
        }
    }
}

struct MediaPage: View {
    let url: URL
    let active: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.black
            if isVideo(url) {
                if let player { VideoLayer(player: player).ignoresSafeArea() }
                else { ProgressView().tint(.white) }
            } else if url.pathExtension.lowercased() == "gif" {
                if active { AnimatedImage(url: url) }
            } else if let image {
                ZoomImage(image: image)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.gray)
            } else { ProgressView().tint(.white) }
        }
        .task(id: url) {
            if isVideo(url) { updatePlayback() }
            else if url.pathExtension.lowercased() != "gif" {
                let value = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 4096
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: cg)
                }.value
                if !Task.isCancelled { image = value; failed = value == nil }
            }
        }
        .onChange(of: active) { _ in updatePlayback() }
        .onDisappear { player?.pause(); player = nil }
    }
    private func updatePlayback() {
        guard isVideo(url) else { return }
        if active {
            if player == nil { player = AVPlayer(url: url) }
            player?.play()
        } else { player?.pause() }
    }
}

private struct VideoLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerContainer {
        let container = PlayerContainer()
        container.playerLayer.player = player
        return container
    }
    func updateUIView(_ view: PlayerContainer, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: PlayerContainer, coordinator: ()) { view.playerLayer.player = nil }
}

private final class PlayerContainer: UIView {
    let playerLayer = AVPlayerLayer()
    override init(frame: CGRect) { super.init(frame: frame); layer.addSublayer(playerLayer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layoutSubviews() { super.layoutSubviews(); playerLayer.frame = bounds }
}

private struct AnimatedImage: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:#000;display:flex;align-items:center;justify-content:center}
        img{max-width:100%;max-height:100%;object-fit:contain}</style></head>
        <body><img src="\(url.lastPathComponent)"></body></html>
        """
        view.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}

private struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ImageScroll {
        let view = ImageScroll(); view.imageView.image = image; return view
    }
    func updateUIView(_ view: ImageScroll, context: Context) { view.imageView.image = image }
}

private final class ImageScroll: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var previousSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; delegate = self
        minimumZoomScale = 1; maximumZoomScale = 4
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        panGestureRecognizer.isEnabled = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize {
            previousSize = bounds.size; setZoomScale(1, animated: false)
            imageView.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer && zoomScale <= minimumZoomScale + .leastNormalMagnitude {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    func scrollViewDidZoom() {
        // At zoom 1 the scroll view must not participate in horizontal panning at all,
        // otherwise its bounce backing board competes with the pager swipe.
        let atMinimum = zoomScale <= minimumZoomScale + .leastNormalMagnitude
        panGestureRecognizer.isEnabled = !atMinimum
        bounces = !atMinimum
        isDirectionalLockEnabled = !atMinimum
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: imageView)
            let width = bounds.width / 3, height = bounds.height / 3
            zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
        }
    }
}

struct ExportSelection: Identifiable {
    let id = UUID()
    let files: [URL]
}

struct ExportSheet: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Share file URLs, never decode the entire gallery into memory.
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

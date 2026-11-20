import MediaCore
import SwiftUI
import UIKit
import AVFoundation
import AVKit
import ImageIO
import WebKit

func isVideo(_ url: URL) -> Bool { ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) }

private actor ThumbnailCoordinator {
    private let maxConcurrent = 6
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    func run(url: URL, decode: @Sendable @escaping () async -> UIImage?) async -> UIImage? {
        if let existing = inflight[url] {
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            await acquire()
            let result = await decode()
            release()
            return result
        }
        inflight[url] = task
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inflight.removeValue(forKey: url)
        return image
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        running += 1
    }

    private func release() {
        running = max(0, running - 1)
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

private final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()
    private let cache = NSCache<NSURL, UIImage>()
    private let coordinator = ThumbnailCoordinator()
    private init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func cached(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let image = await coordinator.run(url: url) {
            if isVideo(url) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 360, height: 360)
                guard let result = try? await generator.image(at: .zero) else { return nil }
                return UIImage(cgImage: result.image)
            }
            return await Task.detached(priority: .utility) { () -> UIImage? in
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 360,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }.value
        }
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
        let displayImage = image ?? Thumbnails.shared.cached(for: url)
        DS.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Group {
                    if let displayImage {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFill()
                    } else if loaded {
                        Image(systemName: isVideo(url) ? "video" : "photo")
                            .foregroundStyle(DS.onSurfaceMuted)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if isVideo(url) {
                    Image(systemName: "play.fill").font(.caption2)
                        .foregroundStyle(DS.onSurface).padding(DS.space(2))
                        .background(DS.background.opacity(0.45), in: Circle()).padding(DS.space(2))
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: url) {
                if displayImage == nil {
                    image = await Thumbnails.shared.image(for: url)
                } else if image == nil {
                    image = displayImage
                }
                loaded = true
            }
    }
}

struct MediaPreview: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    let urls: [URL]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(urls: [URL], selectedURL: URL) {
        self.urls = urls
        _index = State(initialValue: urls.firstIndex(of: selectedURL) ?? 0)
    }
    private var safeIndex: Int {
        guard !urls.isEmpty else { return 0 }
        return min(max(index, 0), urls.count - 1)
    }
    var body: some View {
        Group {
            if urls.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel(L("Fermer", "Close"))
                        Spacer()
                    }
                    .padding(.horizontal, DS.space(2)).padding(.vertical, DS.space(1))
                    Spacer()
                    Text(L("Aucun média", "No media")).foregroundStyle(DS.onSurfaceMuted)
                    Spacer()
                }
            } else {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel(L("Fermer", "Close"))
                Button {
                    if safeIndex > 0 { withAnimation(reduceMotion ? nil : DS.spring) { index = safeIndex - 1 } }
                } label: { Image(systemName: "chevron.backward").frame(width: 44, height: 44) }
                    .disabled(safeIndex == 0)
                    .accessibilityLabel(L("Média précédent", "Previous media"))
                VStack(spacing: 3) {
                    Text(urls[safeIndex].lastPathComponent).font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(safeIndex + 1) / \(urls.count)").font(.caption).foregroundStyle(DS.onSurfaceMuted).monospacedDigit()
                }.frame(maxWidth: .infinity).multilineTextAlignment(.center)
                Button {
                    if safeIndex < urls.count - 1 { withAnimation(reduceMotion ? nil : DS.spring) { index = safeIndex + 1 } }
                } label: { Image(systemName: "chevron.forward").frame(width: 44, height: 44) }
                    .disabled(safeIndex == urls.count - 1)
                    .accessibilityLabel(L("Média suivant", "Next media"))
                ShareLink(item: urls[safeIndex]) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }.accessibilityLabel(L("Partager ce média", "Share this media"))
            }.padding(.horizontal, DS.space(2)).padding(.vertical, DS.space(1))
            MediaPager(urls: urls, index: $index)
        }
            }
        }
        .background(DS.background.ignoresSafeArea())
        .foregroundStyle(DS.onSurface).tint(DS.onSurface)
        .preferredColorScheme(.dark)
    }
}

private struct MediaPager: View {
    let urls: [URL]
    @Binding var index: Int
    @State private var dragOffset: CGFloat = 0
    @State private var isZoomed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedIndex: Int {
        guard !urls.isEmpty else { return 0 }
        return min(max(index, 0), urls.count - 1)
    }

    private var visibleRange: ClosedRange<Int>? {
        guard !urls.isEmpty else { return nil }
        let lower = max(0, clampedIndex - 1)
        let upper = min(urls.count - 1, clampedIndex + 1)
        return lower...upper
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack {
                if let visibleRange {
                    ForEach(visibleRange, id: \.self) { position in
                        let zoomBinding = position == clampedIndex ? $isZoomed : .constant(false)
                        MediaPage(url: urls[position], active: position == clampedIndex, zoomed: zoomBinding)
                            .frame(width: width, height: proxy.size.height)
                            .offset(x: CGFloat(position - clampedIndex) * width + dragOffset)
                    }
                }
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 18, coordinateSpace: .named("mediaPager"))
                    .onChanged { value in
                        guard canPage(value, height: proxy.size.height) else { dragOffset = 0; return }
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        guard canPage(value, height: proxy.size.height) else { dragOffset = 0; return }
                        let limit = max(60, width * 0.2)
                        let dx = value.translation.width
                        let predicted = value.predictedEndTranslation.width
                        var target = clampedIndex
                        if (dx < -limit || predicted < -width * 0.6), clampedIndex < urls.count - 1 { target += 1 }
                        else if (dx > limit || predicted > width * 0.6), clampedIndex > 0 { target -= 1 }
                        withAnimation(reduceMotion ? nil : DS.spring) {
                            index = target
                            dragOffset = 0
                        }
                    },
                including: isZoomed ? .subviews : .all
            )
        }
        .background(DS.background)
        .coordinateSpace(name: "mediaPager")
        .clipped()
        .onChange(of: isZoomed) { _ in dragOffset = 0 }
        .onChange(of: index) { _ in
            isZoomed = false
            dragOffset = 0
        }
        .onChange(of: urls.count) { _ in
            if index >= urls.count { index = max(urls.count - 1, 0) }
        }
        .onAppear {
            if index >= urls.count { index = max(urls.count - 1, 0) }
        }
    }

    private func canPage(_ value: DragGesture.Value, height: CGFloat) -> Bool {
        guard !urls.isEmpty, !isZoomed, abs(value.translation.width) > abs(value.translation.height) else { return false }
        if isVideo(urls[clampedIndex]) {
            // Reserve the native top controls and bottom scrubber. A horizontal
            // swipe in the central picture navigates in either direction.
            return value.startLocation.y > min(80, height * 0.2)
                && value.startLocation.y < height - min(140, height / 3)
        }
        return true
    }
}

struct MediaPage: View {
    let url: URL
    let active: Bool
    @Binding var zoomed: Bool
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            DS.background
            if isVideo(url) {
                LocalVideoPlayer(url: url, active: active).id(url)
            } else if url.pathExtension.lowercased() == "gif" {
                if active { AnimatedImage(url: url) }
            } else if let image {
                ZoomImage(image: image, zoomed: $zoomed)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(DS.onSurfaceMuted)
            } else { ProgressView().tint(DS.onSurface) }
        }
        .task(id: url) {
            if !isVideo(url), url.pathExtension.lowercased() != "gif" {
                let worker = Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard !Task.isCancelled,
                          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2560,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: cg)
                }
                let value = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if !Task.isCancelled { image = value; failed = value == nil }
            }
        }
    }
}

/// Every mounted video page owns a player, including the preloaded neighbours.
/// Activation updates playback directly; no optional-player spinner depends on
/// a SwiftUI task or onChange arriving when a swipe reveals an existing page.
private struct LocalVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let active: Bool

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = context.coordinator.player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.setActive(active)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player.pause()
        coordinator.player.replaceCurrentItem(with: nil)
        controller.player = nil
    }

    final class Coordinator {
        let player: AVPlayer
        private var active: Bool?

        init(url: URL) { player = AVPlayer(url: url) }

        func setActive(_ value: Bool) {
            // Do not undo a user's pause whenever the drag redraws the page.
            guard active != value else { return }
            active = value
            if value { player.play() } else { player.pause() }
        }
    }
}

private struct AnimatedImage: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = UIColor(DS.background); view.scrollView.backgroundColor = UIColor(DS.background)
        view.scrollView.isScrollEnabled = false
        view.scrollView.panGestureRecognizer.isEnabled = false
        view.scrollView.bounces = false
        let escapedName = url.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
            .replacingOccurrences(of: "\"", with: "%22")
            ?? ""
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:transparent;display:flex;align-items:center;justify-content:center}
        img{max-width:100%;max-height:100%;object-fit:contain}</style></head>
        <body><img src="\(escapedName)"></body></html>
        """
        view.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}

private struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool
    func makeUIView(context: Context) -> ImageScroll {
        let view = ImageScroll()
        view.imageView.image = image
        view.onZoomChange = { [zoomed = $zoomed] value in
            DispatchQueue.main.async { zoomed.wrappedValue = value }
        }
        return view
    }
    func updateUIView(_ view: ImageScroll, context: Context) { view.imageView.image = image }
}

private final class ImageScroll: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onZoomChange: ((Bool) -> Void)?
    private var previousSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(DS.background); delegate = self
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
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let atMinimum = zoomScale <= minimumZoomScale + .leastNormalMagnitude
        panGestureRecognizer.isEnabled = !atMinimum
        bounces = !atMinimum
        isDirectionalLockEnabled = !atMinimum
        onZoomChange?(!atMinimum)
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

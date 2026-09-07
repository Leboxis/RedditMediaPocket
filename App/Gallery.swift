import MediaCore
import SwiftUI
import UIKit
import AVFoundation
import AVKit
import ImageIO
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
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
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
                    .accessibilityLabel(L("Fermer", "Close"))
                Button {
                    if index > 0 { withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { index -= 1 } }
                } label: { Image(systemName: "chevron.backward").frame(width: 44, height: 44) }
                    .disabled(index == 0)
                    .accessibilityLabel(L("Média précédent", "Previous media"))
                VStack(spacing: 3) {
                    Text(urls[index].lastPathComponent).font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(index + 1) / \(urls.count)").font(.caption).foregroundStyle(.gray).monospacedDigit()
                }.frame(maxWidth: .infinity).multilineTextAlignment(.center)
                Button {
                    if index < urls.count - 1 { withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { index += 1 } }
                } label: { Image(systemName: "chevron.forward").frame(width: 44, height: 44) }
                    .disabled(index == urls.count - 1)
                    .accessibilityLabel(L("Média suivant", "Next media"))
                ShareLink(item: urls[index]) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }.accessibilityLabel(L("Partager ce média", "Share this media"))
            }.padding(.horizontal, 8).padding(.vertical, 4)
            MediaPager(urls: urls, index: $index)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white).tint(.white)
        .preferredColorScheme(.dark)
    }
}

private struct MediaPager: View {
    let urls: [URL]
    @Binding var index: Int
    @State private var dragOffset: CGFloat = 0
    @State private var zoomed: [Bool]

    init(urls: [URL], index: Binding<Int>) {
        self.urls = urls
        self._index = index
        self._zoomed = State(initialValue: Array(repeating: false, count: urls.count))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            HStack(spacing: 0) {
                ForEach(urls.indices, id: \.self) { position in
                    Group {
                        if abs(position - index) <= 1 {
                            MediaPage(url: urls[position], active: position == index, zoomed: $zoomed[position])
                        } else {
                            Color.black
                        }
                    }
                    .frame(width: width, height: proxy.size.height)
                }
            }
            .frame(width: width * CGFloat(max(urls.count, 1)), alignment: .leading)
            .offset(x: -CGFloat(index) * width + dragOffset)
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
                        var target = index
                        if (dx < -limit || predicted < -width * 0.6), index < urls.count - 1 { target += 1 }
                        else if (dx > limit || predicted > width * 0.6), index > 0 { target -= 1 }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            index = target
                            dragOffset = 0
                        }
                    },
                including: zoomed[index] ? .subviews : .all
            )
        }
        .background(Color.black)
        .coordinateSpace(name: "mediaPager")
        .clipped()
        .onChange(of: zoomed[index]) { _ in dragOffset = 0 }
        .onChange(of: index) { _ in dragOffset = 0 }
    }

    private func canPage(_ value: DragGesture.Value, height: CGFloat) -> Bool {
        guard !zoomed[index], abs(value.translation.width) > abs(value.translation.height) else { return false }
        if isVideo(urls[index]) {
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
            Color.black
            if isVideo(url) {
                LocalVideoPlayer(url: url, active: active).id(url)
            } else if url.pathExtension.lowercased() == "gif" {
                if active { AnimatedImage(url: url) }
            } else if let image {
                ZoomImage(image: image, zoomed: $zoomed)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.gray)
            } else { ProgressView().tint(.white) }
        }
        .task(id: url) {
            if !isVideo(url), url.pathExtension.lowercased() != "gif" {
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
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.panGestureRecognizer.isEnabled = false
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

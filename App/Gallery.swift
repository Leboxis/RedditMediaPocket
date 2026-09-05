import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import QuickLook

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
            }
            .overlay(alignment: .bottomTrailing) {
                if isVideo(url) {
                    Image(systemName: "play.fill").font(.caption2)
                        .foregroundStyle(.white).padding(7)
                        .background(.black.opacity(0.45), in: Circle()).padding(7)
                }
            }
            .clipped()
            .task(id: url) {
                image = await Thumbnails.shared.image(for: url)
                loaded = true
            }
    }
}

// Native preview provides full-resolution images, zoom, animated GIFs and video controls.
struct MediaPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

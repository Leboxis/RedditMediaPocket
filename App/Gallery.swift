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

// Quick Look owns navigation and sharing, so the shared item follows every swipe.
struct MediaPreview: UIViewControllerRepresentable {
    let urls: [URL]
    let selectedURL: URL
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(urls: urls, close: { dismiss() }) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.currentPreviewItemIndex = urls.firstIndex(of: selectedURL) ?? 0
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.close))
        return UINavigationController(rootViewController: controller)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        let onClose: () -> Void
        init(urls: [URL], close: @escaping () -> Void) { self.urls = urls; self.onClose = close }
        @objc func close() { onClose() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { urls[index] as NSURL }
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

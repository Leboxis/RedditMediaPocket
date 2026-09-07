import SwiftUI
import AVFoundation
import ImageIO
import MediaCore

struct MediaInfoSelection: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct MediaDetails {
    var bytes: Int64?
    var resolution: String?
    var frameRate: Float?
    var bitRate: Float?
    var duration: Double?
    var dates: MediaMetadata?

    static func load(_ url: URL) async -> MediaDetails {
        var details = MediaDetails()
        details.bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        details.dates = MediaMetadata.read(for: url)
        if isVideo(url) {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds >= 0 {
                details.duration = duration.seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                if let size = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let display = CGRect(origin: .zero, size: size).applying(transform)
                    let width = abs(display.width), height = abs(display.height)
                    if width.isFinite, height.isFinite, width > 0, height > 0 {
                        details.resolution = "\(Int(width.rounded())) × \(Int(height.rounded())) px"
                    }
                }
                if let fps = try? await track.load(.nominalFrameRate), fps.isFinite, fps > 0 { details.frameRate = fps }
                if let rate = try? await track.load(.estimatedDataRate), rate.isFinite, rate > 0 { details.bitRate = rate }
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            details.resolution = "\(width.intValue) × \(height.intValue) px"
        }
        return details
    }
}

struct MediaInfoView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var details: MediaDetails?
    private var unavailable: String { L("Indisponible", "Unavailable") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(isVideo(url) ? L("Vidéo", "Video") : L("Image", "Image"), systemImage: isVideo(url) ? "film" : "photo")
                        .font(.title3.weight(.semibold)).foregroundStyle(.orange)
                    Text(url.lastPathComponent)
                        .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } header: { Text(L("Nom complet", "Full filename")) }
                if let details {
                    Section {
                        row(L("Poids", "File size"), details.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? unavailable)
                        row(L("Format", "Format"), url.pathExtension.uppercased())
                        row(L("Résolution", "Resolution"), details.resolution ?? unavailable)
                        if isVideo(url) {
                            row(L("Durée", "Duration"), details.duration.map { String(format: "%.1f s", locale: locale, $0) } ?? unavailable)
                        }
                    } header: { Text(L("Fichier", "File")) }
                    if isVideo(url) {
                        Section {
                            row(L("Fréquence d’images", "Frame rate"), details.frameRate.map { String(format: "%.2f fps", locale: locale, $0) } ?? unavailable)
                            row(L("Débit estimé", "Estimated bit rate"), details.bitRate.map { String(format: "%.2f Mb/s", locale: locale, $0 / 1_000_000) } ?? unavailable)
                        } header: { Text(L("Qualité vidéo", "Video quality")) }
                    }
                    Section {
                        row(L("Téléchargement", "Downloaded"), date(details.dates?.downloadedAt))
                        row(L("Publication du post", "Post published"), date(details.dates?.postDate))
                    } header: { Text(L("Dates", "Dates")) } footer: {
                        Text(L("Les dates non enregistrées ou absentes du flux Reddit sont indisponibles.", "Dates that were not recorded or are missing from the Reddit feed are unavailable."))
                    }
                } else {
                    ProgressView(L("Lecture des informations…", "Loading information…"))
                }
            }
            .navigationTitle(L("Informations du média", "Media information"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Fermer", "Close")) { dismiss() } }
            }
            .task(id: url) {
                let result = await MediaDetails.load(url)
                guard !Task.isCancelled else { return }
                details = result
            }
        }
        .tint(.orange)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func date(_ value: Date?) -> String {
        guard let value else { return unavailable }
        return value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}

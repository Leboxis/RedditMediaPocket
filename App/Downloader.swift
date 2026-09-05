import Foundation
import Combine
import AVFoundation
import CryptoKit
import MediaCore

@MainActor final class Downloader: ObservableObject {
    @Published var username = UserDefaults.standard.string(forKey: "lastUsername") ?? ""
    @Published var running = false
    @Published var status = ""
    @Published var files: [URL] = []
    @Published var count = 0
    @Published var active = 0
    @Published var limitNotice = ""
    private var limitedServices: [String: Date] = [:]
    private var skipped = 0
    private let network = Network()
    private var task: Task<Void, Never>?
    private var tokenTask: Task<String, Error>?
    private var token: String?
    private var tokenDate = Date.distantPast
    private let fm = FileManager.default
    private var root: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init() { loadGallery() }

    private func loadGallery() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let media = entries.compactMap { $0 as? URL }.filter {
            ["jpg", "jpeg", "png", "gif", "webp", "mp4", "mov"].contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        files = media.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    func stop() { task?.cancel(); tokenTask?.cancel() }
    func start() {
        guard !running else { return }
        running = true; count = 0; status = ""; limitNotice = ""; skipped = 0; limitedServices = [:]
        task = Task {
            defer { running = false; active = 0; task = nil }
            do { try await run() }
            catch {
                tokenTask?.cancel(); tokenTask = nil; token = nil
                status = Task.isCancelled || error is CancellationError ? "Arrêté" : error.localizedDescription
            }
        }
    }

    private struct Download: Sendable {
        let media: Media
        let destination: URL
    }

    private func run() async throws {
        let name = try MediaExtractor.username(username)
        UserDefaults.standard.set(name, forKey: "lastUsername")
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var after: String?
        var visited = Set<String>()
        var seenMedia = Set<Media>()
        for _ in 1...100 {
            try Task.checkCancellation()
            status = "Recherche…"
            var components = URLComponents(string: "https://www.reddit.com/user/\(name)/submitted.rss")!
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let after { components.queryItems?.append(URLQueryItem(name: "after", value: after)) }
            let posts = try FeedParser.parse(try await network.data(components.url!))
            let fresh = posts.filter { visited.insert($0.id).inserted }
            if fresh.isEmpty { break }
            var downloads: [Download] = []
            for post in fresh {
                for item in MediaExtractor.extract(post.html) where seenMedia.insert(item).inserted {
                    let digest = SHA256.hash(data: Data(item.key.utf8)).map { String(format: "%02x", $0) }.joined()
                    let ext: String
                    if case .direct(let url) = item { ext = url.pathExtension.lowercased() } else { ext = "mp4" }
                    let destination = folder.appendingPathComponent(digest).appendingPathExtension(ext)
                    if !fm.fileExists(atPath: destination.path) { downloads.append(Download(media: item, destination: destination)) }
                }
            }
            status = ""
            try await ConcurrentDownloads.run(downloads, limit: 3) { item in
                try await self.saveUnlessLimited(item)
            }
            guard let last = posts.last?.id, last.hasPrefix("t3_") else { break }
            after = last
        }
        status = skipped > 0 ? "\(count) reçus · \(skipped) à reprendre" : (count == 0 ? "Aucun nouveau média accessible" : "\(count) téléchargés")
    }

    private func saveUnlessLimited(_ item: Download) async throws {
        do { try await save(item) }
        catch NetworkError.limited(let service, let until) {
            try Task.checkCancellation()
            skipped += 1
            limitedServices[service] = max(limitedServices[service] ?? .distantPast, until)
            limitNotice = limitedServices.sorted { $0.key < $1.key }.map {
                "\($0.key) · \($0.value.formatted(date: .numeric, time: .shortened))"
            }.joined(separator: " — ")
            // Keep processing the other services. Blocked requests fail locally without contacting them.
        }
    }

    private func save(_ item: Download) async throws {
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        let temporary = try await resolveAndDownload(item.media)
        defer { try? fm.removeItem(at: temporary) }
        try Task.checkCancellation()
        try fm.moveItem(at: temporary, to: item.destination)
        files.insert(item.destination, at: 0)
        count += 1
    }

    private func redgifsToken() async throws -> String {
        if let token, Date().timeIntervalSince(tokenDate) < 1800 { return token }
        if let tokenTask { return try await tokenTask.value }
        let request = Task { @MainActor in
            struct Auth: Decodable { let token: String }
            let data = try await network.data(URL(string: "https://api.redgifs.com/v2/auth/temporary")!)
            return try JSONDecoder().decode(Auth.self, from: data).token
        }
        tokenTask = request
        defer { tokenTask = nil }
        let result = try await request.value
        token = result; tokenDate = Date()
        return result
    }
    private func resolveAndDownload(_ media: Media) async throws -> URL {
        switch media {
        case .direct(let url): return try await network.download(url)
        case .redgifs(let id):
            let bearer = try await redgifsToken()
            struct Response: Decodable { struct Gif: Decodable { struct URLs: Decodable { let hd: URL?; let sd: URL? }; let urls: URLs }; let gif: Gif }
            let data = try await network.data(URL(string: "https://api.redgifs.com/v2/gifs/\(id)")!, bearer: bearer)
            let urls = try JSONDecoder().decode(Response.self, from: data).gif.urls
            guard let url = urls.hd ?? urls.sd, let host = url.host, host == "redgifs.com" || host.hasSuffix(".redgifs.com") else { throw NetworkError.invalid("Média RedGIFs indisponible.") }
            return try await network.download(url)
        case .redditVideo(let base):
            let manifest = base.appendingPathComponent("DASHPlaylist.mpd")
            let tracks = try DASHParser.parse(try await network.data(manifest), relativeTo: manifest)
            guard tracks.video.host == base.host, tracks.audio == nil || tracks.audio?.host == base.host else { throw NetworkError.invalid("Manifest vidéo inattendu.") }
            let video = try await network.download(tracks.video)
            guard let audioURL = tracks.audio else { return video }
            defer { try? fm.removeItem(at: video) }
            let audio = try await network.download(audioURL)
            defer { try? fm.removeItem(at: audio) }
            return try await merge(video: video, audio: audio)
        }
    }
    private func merge(video: URL, audio: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let sourceV = try await v.loadTracks(withMediaType: .video).first,
              let sourceA = try await a.loadTracks(withMediaType: .audio).first,
              let targetV = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let targetA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NetworkError.invalid("Pistes vidéo/audio illisibles.") }
        let durationV = try await v.load(.duration), durationA = try await a.load(.duration)
        try targetV.insertTimeRange(CMTimeRange(start: .zero, duration: durationV), of: sourceV, at: .zero)
        try targetA.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(durationV, durationA)), of: sourceA, at: .zero)
        targetV.preferredTransform = try await sourceV.load(.preferredTransform)
        let output = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw NetworkError.invalid("Assemblage vidéo indisponible.") }
        export.outputURL = output; export.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in export.exportAsynchronously { continuation.resume() } }
        guard export.status == .completed else { try? fm.removeItem(at: output); throw export.error ?? NetworkError.invalid("Échec de l’assemblage vidéo.") }
        if Task.isCancelled { try? fm.removeItem(at: output); throw CancellationError() }
        return output
    }
}

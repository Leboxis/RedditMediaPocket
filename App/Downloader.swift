import Foundation
import Combine
import AVFoundation
import CryptoKit
import MediaCore

@MainActor final class Downloader: ObservableObject {
    @Published var username = ""
    @Published var running = false
    @Published var status = "Saisis un pseudo pour lire ses publications publiques."
    @Published var logs: [String] = []
    @Published var files: [URL] = []
    @Published var count = 0
    private let network = Network()
    private var task: Task<Void, Never>?
    private var token: String?
    private var tokenDate = Date.distantPast
    private let fm = FileManager.default
    private var root: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    func stop() { task?.cancel() }
    func start() {
        guard !running else { return }
        running = true; logs = []; files = []; count = 0
        task = Task {
            defer { running = false; task = nil }
            do { try await run() }
            catch is CancellationError { status = "Arrêté. Relance pour reprendre les fichiers manquants." }
            catch {
                if Task.isCancelled { status = "Téléchargement arrêté." }
                else { status = error.localizedDescription; log(status) }
            }
        }
    }
    private func log(_ line: String) { logs.insert(line, at: 0); if logs.count > 100 { logs.removeLast() } }
    private func run() async throws {
        let name = try MediaExtractor.username(username)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var after: String?
        var visited = Set<String>()
        var seenMedia = Set<Media>()
        var scanned = 0, unsupported = 0
        for page in 1...100 {
            try Task.checkCancellation()
            status = "Lecture du flux public — page \(page)…"
            var components = URLComponents(string: "https://www.reddit.com/user/\(name)/submitted.rss")!
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let after { components.queryItems?.append(URLQueryItem(name: "after", value: after)) }
            let posts = try FeedParser.parse(try await network.data(components.url!))
            if posts.isEmpty { break }
            let fresh = posts.filter { visited.insert($0.id).inserted }
            if fresh.isEmpty { log("Le flux ne donne plus de nouvelles publications. Pagination interrompue."); break }
            for post in fresh {
                try Task.checkCancellation()
                scanned += 1
                let media = MediaExtractor.extract(post.html)
                if media.isEmpty { unsupported += 1; log("Sans média direct pris en charge : \(post.title)"); continue }
                for item in media where seenMedia.insert(item).inserted {
                    let digest = SHA256.hash(data: Data(item.key.utf8)).map { String(format: "%02x", $0) }.joined()
                    let ext: String
                    if case .direct(let url) = item { ext = url.pathExtension.lowercased() } else { ext = "mp4" }
                    let destination = folder.appendingPathComponent(digest).appendingPathExtension(ext)
                    if fm.fileExists(atPath: destination.path) { continue }
                    status = "Téléchargement : \(post.title)"
                    let temporary = try await resolveAndDownload(item)
                    defer { try? fm.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    try fm.moveItem(at: temporary, to: destination)
                    files.append(destination); count += 1
                    log("Enregistré : \(post.title)")
                }
            }
            // Atom IDs normally contain t3_<id>; never invent a cursor if the format differs.
            guard let last = posts.last?.id, last.hasPrefix("t3_") else { log("Curseur RSS indisponible."); break }
            after = last
            if page == 100 { log("Limite de 100 pages atteinte pour cette session.") }
        }
        status = "Flux parcouru : \(scanned) posts, \(count) nouveaux fichiers, \(unsupported) posts sans média pris en charge. Historique complet non garanti."
    }
    private func resolveAndDownload(_ media: Media) async throws -> URL {
        switch media {
        case .direct(let url): return try await network.download(url)
        case .redgifs(let id):
            if token == nil || Date().timeIntervalSince(tokenDate) > 1800 {
                struct Auth: Decodable { let token: String }
                let data = try await network.data(URL(string: "https://api.redgifs.com/v2/auth/temporary")!)
                token = try JSONDecoder().decode(Auth.self, from: data).token; tokenDate = Date()
            }
            struct Response: Decodable { struct Gif: Decodable { struct URLs: Decodable { let hd: URL?; let sd: URL? }; let urls: URLs }; let gif: Gif }
            let data = try await network.data(URL(string: "https://api.redgifs.com/v2/gifs/\(id)")!, bearer: token)
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

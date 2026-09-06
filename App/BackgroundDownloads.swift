import Foundation
import UIKit
import CryptoKit

/// Only public media requests use this session. Private feeds and authentication
/// stay in Network's ephemeral session (background redirects are managed by iOS).
@MainActor final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloads()
    static let identifier = (Bundle.main.bundleIdentifier ?? "RedditMediaPocket") + ".media-downloads"
    var completionHandler: (() -> Void)?
    private var waiters: [Int: CheckedContinuation<(URL, URLResponse), Error>] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    func reconnect() { _ = session }

    // Completed orphan transfers survive process termination until the next run
    // requests the same media. They never appear as unvalidated gallery files.
    private static var cache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundMedia", isDirectory: true)
    }

    private func takeCached(_ key: String) -> (URL, URLResponse)? {
        let file = Self.cache.appendingPathComponent(key)
        let metadata = file.appendingPathExtension("response")
        guard let data = try? Data(contentsOf: metadata),
              let response = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HTTPURLResponse.self, from: data),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: file, to: temporary)
            try? FileManager.default.removeItem(at: metadata)
            return (temporary, response)
        } catch { return nil }
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        let key = SHA256.hash(data: Data((request.url?.absoluteString ?? "").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let token = UUID()
        defer { tasks.removeValue(forKey: token) }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            if let cached = takeCached(key) { return cached }
            let existing = await session.allTasks
            try Task.checkCancellation()
            // A completion may have arrived while allTasks was being fetched.
            if let cached = takeCached(key) { return cached }
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                let restored = existing.compactMap { $0 as? URLSessionDownloadTask }.first {
                    $0.taskDescription == key && $0.state != .completed && waiters[$0.taskIdentifier] == nil
                }
                let task = restored ?? session.downloadTask(with: request)
                task.taskDescription = key
                tasks[token] = task
                waiters[task.taskIdentifier] = continuation
                task.resume()
            }
        }, onCancel: {
            Task { @MainActor in
                if let task = self.tasks[token] {
                    task.cancel()
                    self.waiters.removeValue(forKey: task.taskIdentifier)?.resume(throwing: CancellationError())
                }
            }
        })
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        // URLSession deletes location as soon as this delegate returns.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result: Result<URL, Error>
        do { try FileManager.default.moveItem(at: location, to: temporary); result = .success(temporary) }
        catch { result = .failure(error) }
        DispatchQueue.main.async {
            let waiter = self.waiters.removeValue(forKey: downloadTask.taskIdentifier)
            do {
                let file = try result.get()
                guard let response = downloadTask.response else {
                    try? FileManager.default.removeItem(at: file)
                    throw NetworkError.invalid("Réponse de téléchargement absente.")
                }
                if let waiter { waiter.resume(returning: (file, response)); return }
                defer { try? FileManager.default.removeItem(at: file) }
                // Only successful public media can be reused after a relaunch.
                let mime = response.mimeType ?? ""
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      response.url?.scheme == "https",
                      mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/octet-stream",
                      let key = downloadTask.taskDescription, key.count == 64,
                      key.allSatisfy({ $0.isHexDigit }) else { return }
                try FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
                let target = Self.cache.appendingPathComponent(key)
                guard !FileManager.default.fileExists(atPath: target.path) else { return }
                let data = try NSKeyedArchiver.archivedData(withRootObject: http, requiringSecureCoding: true)
                try data.write(to: target.appendingPathExtension("response"), options: .atomic)
                try FileManager.default.moveItem(at: file, to: target)
            } catch { waiter?.resume(throwing: error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let waiter = self.waiters.removeValue(forKey: task.taskIdentifier) {
                waiter.resume(throwing: error ?? NetworkError.invalid("Téléchargement sans fichier."))
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let completion = self.completionHandler
            self.completionHandler = nil
            completion?()
        }
    }
}

final class PocketAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.identifier else { completionHandler(); return }
        BackgroundDownloads.shared.completionHandler = completionHandler
        BackgroundDownloads.shared.reconnect()
    }
}

import Foundation
import UIKit

/// Upgrade-only retirement of the former persistent download session.
/// This class never creates or resumes download tasks.
@MainActor final class LegacyBackgroundCleanup: NSObject, URLSessionDownloadDelegate {
    static let shared = LegacyBackgroundCleanup()
    static let identifier = (Bundle.main.bundleIdentifier ?? "RedditMediaPocket") + ".media-downloads"
    private let migrationKey = "retiredBackgroundMediaSession.v1"
    private var session: URLSession?
    private var completions: [() -> Void] = []

    func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        cancelLegacySession()
    }

    func handleEvents(completion: @escaping () -> Void) {
        completions.append(completion)
        // A late OS event must still be acknowledged even after migration.
        cancelLegacySession()
    }

    private func cancelLegacySession() {
        guard session == nil else { return }
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let legacy = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session = legacy
        legacy.invalidateAndCancel()
    }

    private func finishEvents() {
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0() }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        // Discard late transfer results. URLSession removes this temporary file
        // when the callback returns. Never touch Documents or gallery media.
    }

    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        DispatchQueue.main.async {
            self.session = nil
            defer { self.finishEvents() }
            guard error == nil else { return } // Retry retirement next launch.
            let fm = FileManager.default
            let cache = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BackgroundMedia", isDirectory: true)
            do {
                if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
                UserDefaults.standard.set(true, forKey: self.migrationKey)
            } catch {
                // Leave the marker unset so cache cleanup is retried next launch.
                NSLog("Pocket: nettoyage des anciens transferts différé.")
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.finishEvents() }
    }
}

final class PocketAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == LegacyBackgroundCleanup.identifier else { completionHandler(); return }
        LegacyBackgroundCleanup.shared.handleEvents(completion: completionHandler)
    }
}

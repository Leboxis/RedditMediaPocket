import WebKit
import UIKit
import MediaCore

/// Lecture de la page d'une vidéo TikTok isolée dans une WebView cachée.
///
/// Une URLSession directe reçoit parfois de TikTok un squelette HTML sans le
/// JSON d'hydratation (vérification silencieuse, variante mobile de la page),
/// même avec les cookies de la session : TikTok exige un contexte de
/// navigateur. Ce lecteur charge la page dans une WebView cachée branchée sur
/// la session TikTok (`TikTokSession.shared.store`), comme le fait
/// `TikTokWebPaginator` pour les profils, puis lit le JSON d'hydratation
/// (`__UNIVERSAL_DATA_FOR_REHYDRATION__`, repli `SIGI_STATE`) que la page a
/// réellement servi ; `TikTokWeb.parseVideoDetail` l'interprète.
@MainActor final class TikTokVideoPageReader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var watchdog: Task<Void, Never>?

    /// Charge la page de la vidéo et renvoie le JSON d'hydratation tel que la
    /// page l'a servi. `nil` si la page n'a pas pu être chargée (réseau, garde
    /// de 30 s) ou n'a livré aucun JSON d'hydratation.
    func read(_ url: URL) async -> Data? {
        close()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = TikTokSession.shared.store
        // Viewport d'iPhone réel : TikTok sert sa page mobile à ce format.
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             configuration: configuration)
        view.navigationDelegate = self
        webView = view
        // Attachée hors écran à la fenêtre : une WebView hors hiérarchie est
        // signalée `hidden` à la page et son rendu est suspendu.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first {
            view.frame.origin.x = -view.frame.width
            window.addSubview(view)
        }
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loadContinuation = continuation
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.finishLoad(false)
            }
            view.load(URLRequest(url: url))
        }
        guard loaded else {
            close()
            return nil
        }
        // Laisse TikTok hydrater la page avant la lecture du blob.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let script = """
        (function() {
          var el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__')
                || document.getElementById('SIGI_STATE');
          return el ? (el.textContent || '') : '';
        })()
        """
        let json = await evaluateString(script)
        close()
        guard let json, !json.isEmpty else { return nil }
        return Data(json.utf8)
    }

    func close() {
        watchdog?.cancel()
        watchdog = nil
        loadContinuation = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func finishLoad(_ loaded: Bool) {
        watchdog?.cancel()
        watchdog = nil
        loadContinuation?.resume(returning: loaded)
        loadContinuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad(false) }
    }

    private func evaluateString(_ script: String) async -> String? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript(script) as? String
    }
}

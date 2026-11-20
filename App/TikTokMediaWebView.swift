import UIKit
import WebKit
import MediaCore

/// Téléchargements de médias conduits par une WKWebView dédiée.
///
/// Les nœuds CDN `*-webapp-prime` refusent (HTTP 403) toute requête qui ne
/// vient pas du lecteur du site : URLSession avec les cookies prêtés
/// (`tt_chain_token`, `ttwid`) et l'UA exact de la page reste refusé, et le
/// `fetch` de la page garde `Sec-Fetch-Dest: empty`. Une navigation principale
/// vers l'URL du média, remise à WebKit en téléchargement (`WKDownload`),
/// reproduit « enregistrer la vidéo » depuis Safari : cookies, UA et en-têtes
/// `Sec-Fetch-*` sont exactement ceux du navigateur, par construction.
/// La WebView partage le magasin de cookies de la session TikTok.
@MainActor final class TikTokMediaWebView: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    /// Garde de temps d'un transfert : vidéo longue sur réseau lent, le reste
    /// du lot ne doit pas attendre indéfiniment un média bloqué.
    static var timeoutSeconds: UInt64 { UInt64(TimingPolicy.mediaWebView) }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var timeout: Task<Void, Never>?
    private var destination: URL?
    private var busy = false

    /// Octets du média téléchargés par la pile réseau du navigateur.
    /// `nil` en refus (page HTML de statut), en échec ou après la garde.
    func fetch(_ url: URL, userAgent: String?) async -> Data? {
        guard !busy, TikTokWeb.isMediaHost(url) else { return nil }
        guard let view = makeWebView(userAgent: userAgent) else { return nil }
        busy = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            self.continuation = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
                guard let self else { return }
                self.finish(nil)
            }
            view.load(URLRequest(url: url))
        }
    }

    func close() {
        finish(nil)
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
            view.removeFromSuperview()
        }
        webView = nil
    }

    private func finish(_ data: Data?) {
        timeout?.cancel()
        timeout = nil
        guard let continuation else { busy = false; return }
        self.continuation = nil
        busy = false
        if data != nil, let destination {
            try? FileManager.default.removeItem(at: destination)
        }
        destination = nil
        continuation.resume(returning: data)
    }

    private func makeWebView(userAgent: String?) -> WKWebView? {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = TikTokSession.shared.store
        let view = WKWebView(frame: CGRect(x: -390, y: 0, width: 390, height: 844),
                             configuration: configuration)
        if let userAgent { view.customUserAgent = userAgent }
        view.navigationDelegate = self
        webView = view
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first {
            window.addSubview(view)
        }
        return view
    }

    // MARK: - WKNavigationDelegate

    /// Un refus du CDN se voit au type de réponse : le média arrive en
    /// `video/*|audio/*|image/*`, une page de statut (403, connexion) arrive
    /// en `text/html`. La navigation n'est laissée continuer que dans le
    /// premier cas, remise ensuite à WebKit en téléchargement.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame,
              let http = navigationResponse.response as? HTTPURLResponse else {
            decisionHandler(.allow); return
        }
        let mime = navigationResponse.response.mimeType ?? ""
        let media = (200...299).contains(http.statusCode)
            && (mime.hasPrefix("video/") || mime.hasPrefix("audio/")
                || mime.hasPrefix("image/") || mime == "application/octet-stream")
        guard media else {
            LogCenter.net(L("TikTok : téléchargement navigateur refusé (HTTP \(http.statusCode), \(mime)).",
                            "TikTok: browser download refused (HTTP \(http.statusCode), \(mime))."))
            decisionHandler(.cancel)
            finish(nil)
            return
        }
        decisionHandler(.download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let suffix = suggestedFilename.contains(".")
            ? suggestedFilename.split(separator: ".").last.map(String.init) ?? "mp4"
            : "mp4"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix)
        self.destination = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let data = destination.flatMap { try? Data(contentsOf: $0) }
        finish((data?.isEmpty == false) ? data : nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        LogCenter.err(L("TikTok : téléchargement navigateur interrompu.",
                        "TikTok: browser download interrupted."))
        finish(nil)
    }
}

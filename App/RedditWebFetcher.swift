import WebKit
import UIKit
import MediaCore

/// Dernier recours pour les listings `/r/<sub>/<tri>.json`.
///
/// `URLSession` se voit opposer un HTTP 403 « blocked by network security »
/// sur ces seules adresses, avec la session, les en-têtes du site et les deux
/// hôtes Reddit. Un `fetch` exécuté depuis une vraie WKWebView branchée sur le
/// store de session Reddit porte l'empreinte complète du navigateur (TLS,
/// cookies, en-têtes) : c'est le chemin qu'utilise le site lui-même.
///
/// La WebView charge la page du subreddit avant l'appel, pour que le `fetch`
/// soit same-origin et que les cookies soient attachés par WebKit, pas par
/// l'app. Aucun identifiant n'est lu dans la page : seul le corps JSON remonte.
@MainActor final class RedditWebFetcher: NSObject {
    private static let hookName = "redditListingHook"
    private static let hookScript = """
    (function() {
      function send(payload) {
        try { window.webkit.messageHandlers.redditListingHook.postMessage(payload); } catch (e) {}
      }
      window.__redditFetch = function(url, id) {
        (async function() {
          var status = 0, body = '';
          try {
            var r = await fetch(url, { method: 'GET', credentials: 'include',
                                       headers: { 'Accept': 'application/json, text/plain, */*' } });
            status = r.status;
            body = await r.text();
          } catch (e) {}
          send({ id: id, status: status, body: body });
        })();
      };
    })();
    """

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var loadWatchdog: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<(Int, String)?, Never>] = [:]
    private var fetchWatchdogs: [String: Task<Void, Never>] = [:]

    /// Charge la page du subreddit dans une WebView cachée mais vivante,
    /// branchée sur la session Reddit. `false` si la page ne charge pas.
    func start(subreddit: String) async -> Bool {
        close()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = RedditSession.shared.store
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.hookScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: .page))
        controller.add(self, contentWorld: .page, name: Self.hookName)
        configuration.userContentController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             configuration: configuration)
        view.navigationDelegate = self
        webView = view
        // Hors champ visuel mais attachée à une fenêtre : une WebView hors
        // hiérarchie est vue `hidden` et son chargement est suspendu.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            view.frame.origin.x = -view.frame.width
            window.addSubview(view)
        }
        let loaded = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                loadContinuation = continuation
                loadWatchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.finishLoad(false)
                }
                view.load(URLRequest(url: URL(string: "https://www.reddit.com/r/\(subreddit)/")!))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.webView?.stopLoading()
                self?.finishLoad(false)
            }
        }
        guard loaded else { close(); return false }
        return true
    }

    /// `fetch` du listing depuis la page chargée. `nil` si la page a disparu
    /// ou si le site ne répond pas avant le délai de garde.
    func fetch(_ url: URL) async -> (status: Int, body: String)? {
        guard let webView else { return nil }
        let id = UUID().uuidString
        let literal = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Int, String)?, Never>) in
                pending[id] = continuation
                fetchWatchdogs[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    await self?.finishFetch(id, response: nil)
                }
                webView.evaluateJavaScript("window.__redditFetch && window.__redditFetch('\(literal)', '\(id)')",
                                           completionHandler: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishFetch(id, response: nil)
            }
        }
    }

    func close() {
        loadWatchdog?.cancel(); loadWatchdog = nil
        for task in fetchWatchdogs.values { task.cancel() }
        fetchWatchdogs.removeAll()
        webView?.stopLoading(); webView?.navigationDelegate = nil
        webView?.removeFromSuperview(); webView = nil
        loadContinuation?.resume(returning: false); loadContinuation = nil
        for call in pending.values { call.resume(returning: nil) }
        pending.removeAll()
    }

    private func finishLoad(_ loaded: Bool) {
        loadWatchdog?.cancel(); loadWatchdog = nil
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume(returning: loaded)
    }

    private func finishFetch(_ id: String, response: (Int, String)?) {
        fetchWatchdogs.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: response)
    }
}

extension RedditWebFetcher: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.finishLoad(true) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.finishLoad(false) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.finishLoad(false) }
    }
}

extension RedditWebFetcher: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let id = payload["id"] as? String,
              let status = payload["status"] as? Int else { return }
        let body = payload["body"] as? String ?? ""
        Task { @MainActor [weak self] in
            self?.finishFetch(id, response: (status, body))
        }
    }
}

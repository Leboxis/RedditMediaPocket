import WebKit
import MediaCore

/// Pagination des publications TikTok par le JavaScript de TikTok lui-même.
///
/// L'API `api/post/item_list` exige une signature `X-Bogus`/`X-Gnarly` que seul
/// le JavaScript embarqué de TikTok produit : une requête URLSession même
/// enrichie du contexte web complet se voit refusée (HTTP 400). Ce paginateur
/// charge la page profil dans une WebView cachée branchée sur la session
/// TikTok (`TikTokSession.shared.store`), défile comme un lecteur, et capture
/// les réponses `item_list` que la page signe et charge elle-même, via un
/// crochet posé sur `fetch` et `XMLHttpRequest` avant l'exécution du site.
/// Aucun identifiant n'est lu : seuls les corps JSON des réponses publiques
/// de la liste des publications transitent vers le parcours.
@MainActor final class TikTokWebPaginator: NSObject {
    /// Nom du gestionnaire de messages côté page.
    static let hookName = "tiktokItemListHook"

    /// Crochet posé avant les scripts de TikTok : chaque réponse
    /// `/item_list` est recopiée vers le gestionnaire natif, sans altérer
    /// la requête ni la réponse originales.
    static let hookScript = #"""
    (function() {
      var post = function(url, body) {
        try {
          window.webkit.messageHandlers.tiktokItemListHook.postMessage({ url: url, body: body });
        } catch (e) {}
      };
      var matches = function(url) {
        return typeof url === 'string' && url.indexOf('/item_list') !== -1;
      };
      var origFetch = window.fetch;
      window.fetch = function() {
        var args = arguments;
        var url = (typeof args[0] === 'string') ? args[0] : ((args[0] && args[0].url) || '');
        var promise = origFetch.apply(this, args);
        if (matches(url)) {
          promise.then(function(response) {
            try {
              response.clone().text().then(function(text) { post(url, text); });
            } catch (e) {}
          }).catch(function() {});
        }
        return promise;
      };
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__itemListURL = url;
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        var xhr = this;
        if (matches(xhr.__itemListURL)) {
          xhr.addEventListener('load', function() {
            try { post(xhr.__itemListURL, xhr.responseText); } catch (e) {}
          });
        }
        return origSend.apply(this, arguments);
      };
    })();
    """#

    private var webView: WKWebView?
    private var pending: [String] = []
    private var waiting: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var watchdog: Task<Void, Never>?

    /// Charge la page profil dans la WebView cachée. Retourne false si la
    /// page n'a pas pu être chargée (réseau, garde de 30 s).
    func start(username: String) async -> Bool {
        close()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = TikTokSession.shared.store
        let userController = WKUserContentController()
        userController.addUserScript(WKUserScript(source: Self.hookScript,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false,
                                                  in: .page))
        userController.add(self, contentWorld: .page, name: Self.hookName)
        configuration.userContentController = userController
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 2600),
                             configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loadContinuation = continuation
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.finishLoad(false)
            }
            view.load(URLRequest(url: TikTokAPI.profileURL(username: username)))
        }
        guard loaded else { return false }
        // Laisse TikTok hydrater la page avant le premier défilement.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return true
    }

    /// Corps JSON de la page `item_list` suivante, signée par le JavaScript de
    /// TikTok. `nil` quand la page ne charge plus rien : fin du fil atteinte.
    func nextPage() async -> Data? {
        guard webView != nil else { return nil }
        if !pending.isEmpty { return Data(pending.removeFirst().utf8) }
        let body: String? = await withCheckedContinuation { continuation in
            waiting = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, let waiting = self.waiting else { return }
                self.waiting = nil
                self.timeoutTask = nil
                waiting.resume(returning: nil)
            }
            scroll()
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        return body.flatMap { Data($0.utf8) }
    }

    func close() {
        timeoutTask?.cancel()
        timeoutTask = nil
        watchdog?.cancel()
        watchdog = nil
        if let waiting {
            waiting.resume(returning: nil)
            self.waiting = nil
        }
        if let loadContinuation {
            loadContinuation.resume(returning: false)
            self.loadContinuation = nil
        }
        guard let view = webView else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.hookName, contentWorld: .page)
        webView = nil
    }

    /// Défile en bas de page : TikTok charge alors la page suivante de son
    /// propre geste, avec sa signature.
    private func scroll() {
        webView?.evaluateJavaScript(
            "window.scrollTo(0, document.documentElement.scrollHeight); window.dispatchEvent(new Event('scroll'));",
            completionHandler: nil)
    }

    private func finishLoad(_ ok: Bool) {
        watchdog?.cancel()
        watchdog = nil
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(returning: ok)
    }
}

extension TikTokWebPaginator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(false)
    }
}

extension TikTokWebPaginator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let body = payload["body"] as? String, !body.isEmpty else { return }
        if let waiting {
            waiting.resume(returning: body)
            self.waiting = nil
            timeoutTask?.cancel()
            timeoutTask = nil
        } else {
            pending.append(body)
        }
    }
}

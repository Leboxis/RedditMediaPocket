import WebKit
import UIKit
import MediaCore

/// Pagination des publications TikTok par le JavaScript de TikTok lui-même.
///
/// L'API `api/post/item_list` exige une signature `X-Bogus`/`X-Gnarly` que seul
/// le JavaScript embarqué de TikTok produit : une requête URLSession même
/// enrichie du contexte web complet se voit refusée (HTTP 400, ou 200 avec un
/// corps vide). Ce paginateur charge la page profil dans une WebView cachée
/// branchée sur la session TikTok (`TikTokSession.shared.store`), défile comme
/// un lecteur, et capture les réponses `item_list` que la page signe et
/// charge elle-même, via un crochet posé sur `fetch` et `XMLHttpRequest`
/// avant l'exécution du site. Aucun identifiant n'est lu : seuls les corps
/// JSON des réponses publiques de la liste des publications transitent vers
/// le parcours.
///
/// La WebView fait la taille d'un iPhone : un viewport plus haut que le
/// contenu empêche le déclenchement du défilement infini (la page tient
/// entière à l'écran, TikTok ne charge donc jamais de seconde page).
/// Pour le diagnostic, le crochet confirme son installation, signale chaque
/// route appelée par la page (une fois par chemin), chaque hauteur atteinte
/// en fin de défilement, et le statut et la taille de chaque réponse
/// `item_list` — une réponse vide se voit ainsi, au lieu d'un silence.
@MainActor final class TikTokWebPaginator: NSObject {
    /// Nom du gestionnaire de messages côté page.
    static let hookName = "tiktokItemListHook"

    /// Crochet posé avant les scripts de TikTok : il confirme son injection,
    /// signale chaque route appelée par la page, et recopie chaque réponse
    /// `/item_list` vers le gestionnaire natif sans altérer la requête ni la
    /// réponse originales. Le statut HTTP et le corps (même vide) partent
    /// toujours : une réponse 200 vide est le refus discret de TikTok, la
    /// distinguer d'un échec de capture évite de chercher au mauvais endroit.
    /// Pour XHR, `responseText` lève quand `responseType` vaut `json` : la
    /// lecture retombe alors sur `response` sérialisé.
    static let hookScript = #"""
    (function() {
      // Une WebView jamais attachée à une fenêtre est vue `hidden` par la
      // page, et requestAnimationFrame y est suspendu : TikTok s'en sert
      // pour décider s'il vaut la peine de charger et pour piloter son
      // défilement infini. La page voit donc un lecteur présent et actif.
      try {
        Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; } });
        Object.defineProperty(document, 'hidden', { get: function() { return false; } });
        document.dispatchEvent(new Event('visibilitychange'));
        document.hasFocus = function() { return true; };
        var origRAF = window.requestAnimationFrame;
        window.requestAnimationFrame = function(callback) {
          return setTimeout(function() { callback(Date.now()); }, 16);
        };
      } catch (e) {}
      var handler = function(payload) {
        try {
          window.webkit.messageHandlers.tiktokItemListHook.postMessage(payload);
        } catch (e) {}
      };
      handler({ kind: 'route', url: '/__hook_installed__' });
      var seenRoutes = {};
      var staticExt = /\.(js|css|png|jpe?g|webp|gif|svg|woff2?|ttf|mp4|ico|avif)(\?|$)/;
      var logRoute = function(url) {
        if (typeof url !== 'string' || url.length === 0) return;
        var path = url.replace(/^https?:\/\/[^\/]+/, '').split('?')[0];
        if (path === '/' || staticExt.test(path)) return;
        if (seenRoutes[path]) return;
        seenRoutes[path] = true;
        if (Object.keys(seenRoutes).length > 80) return;
        handler({ kind: 'route', url: path });
      };
      var captureBody = function(url, status, text) {
        handler({ kind: 'body', url: url, status: status, body: text || '' });
      };
      var isItemList = function(url) {
        return typeof url === 'string' && url.indexOf('/item_list') !== -1;
      };
      var origFetch = window.fetch;
      window.fetch = function() {
        var args = arguments;
        var url = (typeof args[0] === 'string') ? args[0] : ((args[0] && args[0].url) || '');
        logRoute(url);
        var promise = origFetch.apply(this, args);
        if (isItemList(url)) {
          promise.then(function(response) {
            var code = response.status;
            try {
              response.clone().text().then(function(text) { captureBody(url, code, text); });
            } catch (e) { captureBody(url, code, ''); }
          }).catch(function() { captureBody(url, 0, ''); });
        }
        return promise;
      };
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__itemListURL = url;
        logRoute(url);
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        var xhr = this;
        if (isItemList(xhr.__itemListURL)) {
          xhr.addEventListener('load', function() {
            var text = '';
            try { text = xhr.responseText; } catch (e) {}
            if (!text) {
              try {
                if (typeof xhr.response === 'string') text = xhr.response;
                else if (xhr.response) text = JSON.stringify(xhr.response);
              } catch (e) {}
            }
            captureBody(xhr.__itemListURL, xhr.status, text);
          });
        }
        return origSend.apply(this, arguments);
      };
    })();
    """#

    /// Défile la fenêtre et tout conteneur défilable en bas de page : TikTok
    /// charge alors la page suivante de son propre geste, avec sa signature.
    /// La hauteur atteinte est signalée à chaque passage : des hauteurs qui
    /// grandissent prouvent que le défilement charge du contenu, une hauteur
    /// figée au viewport prouve le contraire.
    static let scrollScript = #"""
    (function() {
      window.scrollTo(0, document.documentElement.scrollHeight);
      window.dispatchEvent(new Event('scroll'));
      var containers = document.querySelectorAll('div, main, section');
      for (var i = 0; i < containers.length; i++) {
        var el = containers[i];
        if (el.scrollHeight > el.clientHeight + 100) {
          el.scrollTop = el.scrollHeight;
          el.dispatchEvent(new Event('scroll', { bubbles: true }));
        }
      }
      try {
        window.webkit.messageHandlers.tiktokItemListHook.postMessage(
          { kind: 'route', url: '/__scroll_' + document.documentElement.scrollHeight + '__' });
      } catch (e) {}
    })();
    """#

    private var webView: WKWebView?
    private var pending: [String] = []
    private var waiting: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var watchdog: Task<Void, Never>?
    private var loggedRoutes = Set<String>()
    private var itemListResponses = 0
    private var emptyItemListResponses = 0

    /// La page a-t-elle répondu à chaque appel `item_list` par un corps vide ?
    /// Un corps vide (HTTP 200, 0 octet) n'est pas une fin de fil — TikTok
    /// annonce alors `hasMore: false` en JSON — mais un refus discret, typique
    /// d'une vérification (captcha) exigée pour cette session.
    var sawOnlyEmptyItemLists: Bool {
        itemListResponses > 0 && emptyItemListResponses == itemListResponses
    }

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
        // Viewport d'iPhone réel : le contenu déborde, le défilement infini
        // a une raison de se déclencher.
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                             configuration: configuration)
        view.navigationDelegate = self
        webView = view
        // Attachée hors écran à la fenêtre : une WebView hors hiérarchie est
        // signalée `hidden` à la page et son rendu est suspendu. Hors champ
        // visuel (`x: -390`) mais vivante : TikTok y voit un vrai onglet.
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
            view.load(URLRequest(url: TikTokAPI.profileURL(username: username)))
        }
        guard loaded else { return false }
        // Laisse TikTok hydrater la page avant le premier défilement.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return true
    }

    /// Corps JSON de la page `item_list` suivante, signée par le JavaScript de
    /// TikTok. `nil` quand la page ne charge plus rien : fin du fil atteinte.
    /// Pendant l'attente, le défilement est relancé toutes les 4 s : un seul
    /// appel à `scrollTo` ne déclenche pas toujours le chargement paresseux.
    func nextPage() async -> Data? {
        guard webView != nil else { return nil }
        if !pending.isEmpty { return Data(pending.removeFirst().utf8) }
        let body: String? = await withCheckedContinuation { continuation in
            waiting = continuation
            timeoutTask = Task { [weak self] in
                var waited = 0
                while waited < 20 {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if Task.isCancelled { return }
                    guard let self, self.waiting != nil else { return }
                    self.scroll()
                    waited += 4
                }
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
        view.removeFromSuperview()
        webView = nil
    }

    private func scroll() {
        webView?.evaluateJavaScript(Self.scrollScript, completionHandler: nil)
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
        // Diagnostic : la page réellement servie à la WebView cachée.
        webView.evaluateJavaScript("document.title + ' | ' + location.href",
                                   completionHandler: { result, _ in
            if let text = result as? String {
                LogCenter.info(L("TikTok web : page chargée \(text).", "TikTok web: page loaded \(text)."))
            }
        })
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
        guard let payload = message.body as? [String: Any] else { return }
        if payload["kind"] as? String == "route" {
            guard let route = payload["url"] as? String, !route.isEmpty else { return }
            // Les hauteurs de défilement ne sont pas dédupliquées : leur
            // évolution d'un passage à l'autre est justement le diagnostic.
            if route.hasPrefix("/__scroll") || loggedRoutes.insert(route).inserted {
                LogCenter.info(L("TikTok web : route \(route).", "TikTok web: route \(route)."))
            }
            return
        }
        guard let body = payload["body"] as? String else { return }
        let status = payload["status"] as? Int ?? 0
        // Chaque réponse item_list se voit, même vide : un 200 à 0 octet est
        // le refus discret de TikTok, pas un échec de capture.
        itemListResponses += 1
        if body.isEmpty { emptyItemListResponses += 1 }
        LogCenter.info(L("TikTok web : item_list HTTP \(status), \(body.utf8.count) octets.",
                         "TikTok web: item_list HTTP \(status), \(body.utf8.count) bytes."))
        guard !body.isEmpty else { return }
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

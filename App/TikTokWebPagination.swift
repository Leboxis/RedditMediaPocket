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
        return typeof url === 'string'
          && (url.indexOf('/item_list') !== -1 || url.indexOf('/collection_list') !== -1);
      };
      // Ouvre un dossier de favoris de la page Sauvegardés par son nom :
      // imite le clic d'un lecteur, la page signe et charge elle-même le fil
      // `/api/collection/item_list` du dossier.
      window.__tiktokOpenCollection = function(name) {
        var els = document.querySelectorAll('a, button, [role="button"], [data-e2e], div, span');
        var exact = null;
        var loose = null;
        for (var i = 0; i < els.length; i++) {
          var t = (els[i].textContent || '').trim();
          if (t.length === 0 || t.length > 100) continue;
          if (t === name) { exact = els[i]; break; }
          if (!loose && t.indexOf(name) !== -1) loose = els[i];
        }
        var target = exact || loose;
        if (!target) {
          handler({ kind: 'route', url: '/__collection_not_found__' });
          return false;
        }
        target.click();
        handler({ kind: 'route', url: '/__collection_opened__' });
        return true;
      };
      // Rapatriement d'un média depuis le contexte de la page : le CDN refuse
      // les requêtes hors navigateur (403), mais depuis la page le TLS, les
      // cookies et les en-têtes sont ceux du vrai client. Le corps part par
      // morceaux base64 vers le natif, sans altérer la page.
      window.__tiktokDownload = function(url, id) {
        var attempt = function(withCredentials) {
          fetch(url, { method: 'GET', credentials: withCredentials ? 'include' : 'omit' }).then(function(r) {
            if (!r.ok) {
              if (withCredentials) return attempt(false);
              handler({ kind: 'media', id: id, failed: true, status: r.status });
              return;
            }
            return r.arrayBuffer().then(function(buf) {
              var bytes = new Uint8Array(buf);
              var CHUNK = 262144;
              var total = Math.ceil(bytes.length / CHUNK) || 1;
              for (var i = 0; i < total; i++) {
                var slice = bytes.subarray(i * CHUNK, Math.min((i + 1) * CHUNK, bytes.length));
                var str = '';
                for (var j = 0; j < slice.length; j += 8192) {
                  str += String.fromCharCode.apply(null, slice.subarray(j, Math.min(j + 8192, slice.length)));
                }
                handler({ kind: 'media', id: id, seq: i, total: total, data: btoa(str) });
              }
              handler({ kind: 'media', id: id, done: true });
            });
          }).catch(function() {
            if (withCredentials) { attempt(false); return; }
            handler({ kind: 'media', id: id, failed: true, status: 0 });
          });
        };
        attempt(true);
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
    /// Des événements `wheel` accompagnent le `scroll` : certains front-ends
    /// n'écoutent pas l'événement scroll seul. Chaque passage signale un état
    /// du DOM — nombre de publications rendues (`data-e2e="user-post-item"`),
    /// plus grande hauteur de conteneur, hauteur du document, présence du
    /// signataire `bytedAcrawler` — pour voir si la page vit et ce qui bloque.
    static let scrollScript = #"""
    (function() {
      var doc = document.scrollingElement || document.documentElement;
      var wheel = null;
      try { wheel = new WheelEvent('wheel', { deltaY: 600, bubbles: true, cancelable: true }); } catch (e) {}
      window.scrollTo(0, doc.scrollHeight);
      window.dispatchEvent(new Event('scroll'));
      if (wheel) window.dispatchEvent(wheel);
      var maxH = doc.scrollHeight;
      var containers = document.querySelectorAll('div, main, section');
      for (var i = 0; i < containers.length; i++) {
        var el = containers[i];
        if (el.scrollHeight > maxH) maxH = el.scrollHeight;
        if (el.scrollHeight > el.clientHeight + 100) {
          el.scrollTop = el.scrollHeight;
          el.dispatchEvent(new Event('scroll', { bubbles: true }));
          if (wheel) el.dispatchEvent(wheel);
        }
      }
      var posts = document.querySelectorAll('[data-e2e="user-post-item"]').length;
      var signer = (window.bytedAcrawler && window.bytedAcrawler.sign) ? 1 : 0;
      try {
        window.webkit.messageHandlers.tiktokItemListHook.postMessage(
          { kind: 'route', url: '/__dom_' + posts + '_' + maxH + '_' + doc.scrollHeight + '_s' + signer + '__' });
      } catch (e) {}
    })();
    """#

    private var webView: WKWebView?
    /// Corps capturés non encore consommés, avec la route servi : la page
    /// Sauvegardés mélange `collection_list` et `item_list`, chaque consommateur
    /// n'attend que sa route.
    private var pendingBodies: [(url: String, body: String)] = []
    private var waiting: CheckedContinuation<String?, Never>?
    /// Route attendue par le consommateur en attente (ex. `/item_list`).
    private var waitingRoute: String?
    private var timeoutTask: Task<Void, Never>?
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var watchdog: Task<Void, Never>?
    private var loggedRoutes = Set<String>()
    private var itemListResponses = 0
    private var emptyItemListResponses = 0

    /// Transfert d'un média en cours : morceaux base64 reçus par identifiant,
    /// continuation du demandeur et garde de temps.
    private struct MediaTransfer {
        var chunks: [Int: String]
        let continuation: CheckedContinuation<Data?, Never>
        let timeout: Task<Void, Never>
    }

    private var mediaTransfers: [String: MediaTransfer] = [:]

    /// UA réel de la WebView, lu après le chargement de la page. Les URL de
    /// médias d'une réponse `item_list` sont liées au client qui l'a obtenue :
    /// les téléchargements doivent s'identifier avec cet UA exact, pas avec
    /// le spoof iPhone de `TikTokAPI.userAgent`.
    private(set) var pageUserAgent: String?

    /// Pseudo du compte connecté lu dans la page (`/@pseudo`) : sert de nom à
    /// la collection `ts/…`. Par défaut `saved` si la page ne l'expose pas.
    private(set) var pageUsername: String?

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
        await start(url: TikTokAPI.profileURL(username: username))
    }

    /// Charge une page tiktok.com (profil ou Sauvegardés) dans la WebView
    /// cachée, sur la session connectée. Retourne false en échec de
    /// chargement (réseau, garde de 30 s).
    func start(url: URL) async -> Bool {
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
            view.load(URLRequest(url: url))
        }
        guard loaded else { return false }
        // Laisse TikTok hydrater la page avant le premier défilement.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return true
    }

    /// Ouvre un dossier de favoris de la page Sauvegardés en imitant le clic
    /// d'un lecteur. Retourne false si aucun élément portant ce nom n'a été
    /// trouvé : le diagnostic dans le journal dit lequel des deux cas.
    func openCollection(name: String) async -> Bool {
        guard let webView else { return false }
        let literal = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript("window.__tiktokOpenCollection && window.__tiktokOpenCollection('\(literal)')") { result, _ in
                continuation.resume(returning: result as? Bool ?? false)
            }
        }
    }

    /// Corps JSON suivant d'une route signée par le JavaScript de TikTok
    /// (`/item_list` par défaut, `/collection_list` pour les dossiers).
    /// `nil` quand la page ne charge plus rien : fin du fil atteinte.
    /// Pendant l'attente, le défilement est relancé toutes les 4 s : un seul
    /// appel à `scrollTo` ne déclenche pas toujours le chargement paresseux.
    func nextPage(matching route: String = "/item_list") async -> Data? {
        guard webView != nil else { return nil }
        if let index = pendingBodies.firstIndex(where: { $0.url.contains(route) }) {
            let entry = pendingBodies.remove(at: index)
            return Data(entry.body.utf8)
        }
        let body: String? = await withCheckedContinuation { continuation in
            waiting = continuation
            waitingRoute = route
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
        waitingRoute = nil
        return body.flatMap { Data($0.utf8) }
    }

    /// Octets d'un média rapatriés depuis la page TikTok. `nil` en échec ou
    /// après la garde de 120 s : le demandeur retombe alors sur son erreur
    /// directe, le parcours continue sans ce média.
    func fetchMedia(_ url: URL) async -> Data? {
        guard webView != nil else { return nil }
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self, let transfer = self.mediaTransfers[id] else { return }
                self.mediaTransfers[id] = nil
                transfer.continuation.resume(returning: nil)
            }
            mediaTransfers[id] = MediaTransfer(chunks: [:], continuation: continuation, timeout: timeout)
            let literal = url.absoluteString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("window.__tiktokDownload && window.__tiktokDownload('\(literal)', '\(id)')",
                                       completionHandler: nil)
        }
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
        waitingRoute = nil
        pendingBodies.removeAll()
        if let loadContinuation {
            loadContinuation.resume(returning: false)
            self.loadContinuation = nil
        }
        for transfer in mediaTransfers.values {
            transfer.timeout.cancel()
            transfer.continuation.resume(returning: nil)
        }
        mediaTransfers = [:]
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
        webView.evaluateJavaScript("navigator.userAgent",
                                   completionHandler: { [weak self] result, _ in
            self?.pageUserAgent = result as? String
        })
        // Pseudo du compte connecté, premier lien `@pseudo` de la page : il
        // nomme la collection `ts/…`. Vide si la page n'en expose aucun.
        webView.evaluateJavaScript("(function(){var a=document.querySelector('a[href*=\"/@\"]');var m=a?String(a.getAttribute('href')).match(/@([A-Za-z0-9._]{1,24})/):null;return m?m[1]:'';})();",
                                   completionHandler: { [weak self] result, _ in
            if let name = result as? String, !name.isEmpty {
                self?.pageUsername = name
                LogCenter.info(L("TikTok web : compte connecté \(name).", "TikTok web: signed-in account \(name)."))
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
        if payload["kind"] as? String == "media" {
            guard let id = payload["id"] as? String,
                  var transfer = mediaTransfers[id] else { return }
            if payload["failed"] as? Bool == true {
                mediaTransfers[id] = nil
                transfer.timeout.cancel()
                transfer.continuation.resume(returning: nil)
                return
            }
            if let data = payload["data"] as? String, let seq = payload["seq"] as? Int {
                transfer.chunks[seq] = data
                mediaTransfers[id] = transfer
            }
            if payload["done"] as? Bool == true {
                mediaTransfers[id] = nil
                transfer.timeout.cancel()
                let assembled = transfer.chunks.sorted { $0.key < $1.key }
                    .compactMap { Data(base64Encoded: $0.value) }
                    .reduce(Data(), +)
                transfer.continuation.resume(returning: assembled)
            }
            return
        }
        guard let body = payload["body"] as? String else { return }
        let status = payload["status"] as? Int ?? 0
        guard let url = payload["url"] as? String else { return }
        if url.contains("/collection_list") {
            LogCenter.info(L("TikTok web : collection_list HTTP \(status), \(body.utf8.count) octets.",
                             "TikTok web: collection_list HTTP \(status), \(body.utf8.count) bytes."))
            guard !body.isEmpty else { return }
            if let waiting, let route = waitingRoute, url.contains(route) {
                waiting.resume(returning: body)
                self.waiting = nil
                waitingRoute = nil
                timeoutTask?.cancel()
                timeoutTask = nil
            } else {
                pendingBodies.append((url, body))
            }
            return
        }
        // Chaque réponse item_list se voit, même vide : un 200 à 0 octet est
        // le refus discret de TikTok, pas un échec de capture.
        itemListResponses += 1
        if body.isEmpty { emptyItemListResponses += 1 }
        LogCenter.info(L("TikTok web : item_list HTTP \(status), \(body.utf8.count) octets.",
                         "TikTok web: item_list HTTP \(status), \(body.utf8.count) bytes."))
        guard !body.isEmpty else { return }
        if let waiting, let route = waitingRoute, url.contains(route) {
            waiting.resume(returning: body)
            self.waiting = nil
            waitingRoute = nil
            timeoutTask?.cancel()
            timeoutTask = nil
        } else if let waiting, waitingRoute == nil {
            waiting.resume(returning: body)
            self.waiting = nil
            timeoutTask?.cancel()
            timeoutTask = nil
        } else {
            pendingBodies.append((url, body))
        }
    }
}

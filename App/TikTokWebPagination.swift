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
      // Clique le premier élément correspondant à l'un des noms donnés :
      // la page Sauvegardés ne charge parfois `collection_list` qu'après
      // l'ouverture de son onglet (Favorites, Collections…).
      window.__tiktokClickNamed = function(namesJson) {
        var names = [];
        try { names = JSON.parse(namesJson) || []; } catch (e) { return ''; }
        var els = document.querySelectorAll('a, button, [role="button"], [data-e2e], div, span');
        for (var n = 0; n < names.length; n++) {
          var wanted = String(names[n]).toLowerCase();
          for (var i = 0; i < els.length; i++) {
            var t = (els[i].textContent || '').trim();
            if (t.length === 0 || t.length > 60 || t.toLowerCase() !== wanted) continue;
            els[i].click();
            handler({ kind: 'route', url: '/__clicked_' + t.substring(0, 40) + '__' });
            return t;
          }
        }
        handler({ kind: 'route', url: '/__no_named_element__' });
        return '';
      };
      // Rèle le lien de la page Enregistrés : il vit dans le menu du profil
      // sur le site desktop. Le menu est ouvert, puis les ancres contenant
      // `saved`/`bookmarks` sont récoltées avec le pseudo du compte connecté.
      window.__tiktokOpenMenu = function() {
        // Tout lien `@pseudo` du fil ouvre le profil d'un createur : cibler
        // d'abord l'avatar de la barre superieure, seul chemin vers le menu
        // du compte connecte.
        var sels = ['a[data-e2e="profile-icon"]', '[data-e2e="profile-icon"]',
                    '[data-e2e="profile-avatar"]', '[data-e2e="top-avatar"]',
                    'header a[href^="/@"]', 'a[href^="/@"][aria-haspopup]'];
        for (var i = 0; i < sels.length; i++) {
          var els = document.querySelectorAll(sels[i]);
          if (els.length) { els[0].click(); return true; }
        }
        return false;
      };
      window.__tiktokHarvestSaved = function() {
        var links = [];
        var anchors = document.querySelectorAll('a[href]');
        for (var i = 0; i < anchors.length; i++) {
          var h = String(anchors[i].getAttribute('href') || '');
          if ((h.indexOf('/saved') !== -1 || h.indexOf('bookmarks') !== -1 || h.indexOf('favorites') !== -1) && links.indexOf(h) === -1 && links.length < 5) links.push(h);
        }
        var user = '';
        var sels = ['header a[href^="/@"]',
                    '[data-e2e="profile-popup"] a[href^="/@"]',
                    'div[role="menu"] a[href^="/@"]',
                    'div[role="dialog"] a[href^="/@"]'];
        for (var i = 0; i < sels.length; i++) {
          var el = document.querySelector(sels[i]);
          if (el) {
            var m = String(el.getAttribute('href') || '').match(/^\/@([A-Za-z0-9._]{1,24})/);
            if (m) { user = m[1]; break; }
          }
        }
        return JSON.stringify({ user: user, links: links });
      };
      // Pseudo du compte connecté : le chemin `/@pseudo` quand la page y est
      // (un clic avatar y mène), sinon l'ancrage profil de l'en-tête — seul
      // lien `/@` fiable, ceux du fil désignent des créateurs voisins.
      window.__tiktokMe = function() {
        var m = String(location.pathname).match(/^\/@([A-Za-z0-9._]{1,24})\/?$/);
        if (m) return m[1];
        // L'avatar de l'en-tete n'est pas toujours une ancre : le menu ouvert
        // (popup hors `header`) porte le lien profil du compte connecte.
        var sels = ['header a[href^="/@"]',
                    '[data-e2e="profile-popup"] a[href^="/@"]',
                    'div[role="menu"] a[href^="/@"]',
                    'div[role="dialog"] a[href^="/@"]'];
        for (var i = 0; i < sels.length; i++) {
          var el = document.querySelector(sels[i]);
          if (el) {
            var h = String(el.getAttribute('href') || '').match(/^\/@([A-Za-z0-9._]{1,24})/);
            if (h) return h[1];
          }
        }
        return '';
      };
      // JSON d'hydratation de la page courante : sur une page profil chargée
      // entièrement, il porte le `secUid` du compte.
      window.__tiktokProfileJSON = function() {
        var el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
        return el ? (el.textContent || '') : '';
      };
      // Appel API depuis le contexte de la page : cookies, empreinte et
      // msToken du vrai client, et signature X-Bogus du signer que le site
      // expose globalement (shapes essayés dans l'ordre des générations).
      // Le corps — même vide — repart au natif, taggé par l'identifiant.
      window.__tiktokSignedFetch = function(url, id) {
        var handler = function(payload) {
          try { window.webkit.messageHandlers.tiktokItemListHook.postMessage(payload); } catch (e) {}
        };
        (async function() {
          var status = 0;
          var text = '';
          try {
            var target = url;
            try {
              if (target.indexOf('msToken=') === -1) {
                var m = document.cookie.match(/(?:^|;\s*)msToken=([^;]+)/);
                if (m && m[1]) target += (target.indexOf('?') === -1 ? '?' : '&') + 'msToken=' + m[1];
              }
            } catch (e) {}
            try {
              var bogus = null;
              if (window.bytedAcrawler && typeof window.bytedAcrawler.sign === 'function') {
                bogus = window.bytedAcrawler.sign(target);
              }
              if ((!bogus || typeof bogus !== 'string' || bogus.length === 0) &&
                  window.bytedAcrawler && typeof window.bytedAcrawler.frontierSign === 'function') {
                var fs = window.bytedAcrawler.frontierSign(target);
                bogus = (fs && typeof fs === 'object') ? (fs['X-Bogus'] || '') : fs;
              }
              if (bogus && typeof bogus === 'string' && bogus.length > 0) {
                target += '&X-Bogus=' + encodeURIComponent(bogus);
              }
            } catch (e) {}
            var r = await fetch(target, { method: 'GET', credentials: 'include',
                                          headers: { 'Accept': 'application/json, text/plain, */*' } });
            status = r.status;
            text = await r.text();
          } catch (e) {
            handler({ kind: 'api', id: id, status: 0, body: '' });
            return;
          }
          handler({ kind: 'api', id: id, status: status, body: text });
        })();
      };
      // Rapatriement d'un média depuis le contexte de la page : le CDN refuse
      // les requêtes hors navigateur (403), mais depuis la page le TLS, les
      // cookies et les en-têtes sont ceux du vrai client. Le corps part par
      // morceaux base64 vers le natif, sans altérer la page.
      window.__tiktokDownload = function(url, id) {
        // `Range` + `credentials` : les noeuds `*-webapp-prime` refusent la
        // requete media sans segment demande ni cookies `.tiktok.com`
        // (`Sec-Fetch-Dest: empty` sinon, HTTP 403 garanti).
        var attempt = function(withCredentials) {
          fetch(url, { method: 'GET', credentials: withCredentials ? 'include' : 'omit',
                       headers: { 'Range': 'bytes=0-' } }).then(function(r) {
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

    /// Réponse d'un appel API signé par la page.
    struct APIResponse {
        let status: Int
        let body: String
    }

    private struct APICall {
        let continuation: CheckedContinuation<APIResponse?, Never>
        let timeout: Task<Void, Never>
    }

    private var apiCalls: [String: APICall] = [:]

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
    func start(url: URL, desktopUserAgent: Bool = false) async -> Bool {
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
        // La page Sauvegardés ne sert `collection_list` ni `collect/item_list`
        // qu'au client web desktop (`web_pc`) : à un iPhone elle oppose une
        // page muette qui pousse vers l'app. La WebView garde un viewport
        // mobile mais se presente comme le navigateur desktop.
        if desktopUserAgent {
            view.customUserAgent = TikTokAPI.desktopUserAgent
        }
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

    /// Pseudo du compte connecté vu par la page : chemin `/@pseudo` ou
    /// ancrage profil de l'en-tête. `nil` quand la page n'en expose aucun.
    func ownUsername() async -> String? {
        guard let value = await evaluateString("window.__tiktokMe ? window.__tiktokMe() : ''"),
              !value.isEmpty else { return nil }
        return value
    }

    /// JSON d'hydratation de la page courante : sur une page profil chargée
    /// entièrement, il porte le `secUid` du compte (`TikTokWeb.parseProfileData`).
    func profileJSON() async -> String? {
        guard let value = await evaluateString("window.__tiktokProfileJSON ? window.__tiktokProfileJSON() : ''"),
              !value.isEmpty else { return nil }
        return value
    }

    /// Clic sur l'avatar de l'en-tête : le chemin vers le compte connecté.
    func openProfileMenu() async -> Bool {
        guard let webView else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript("window.__tiktokOpenMenu && window.__tiktokOpenMenu()") { result, _ in
                continuation.resume(returning: (result as? Bool) == true)
            }
        }
    }

    /// Appel GET signé par la page : TikTok signe sa propre requête, le corps
    /// remonte intact. `nil` en échec de page, hors délai (25 s) ou corps vide.
    func signedFetch(_ url: URL) async -> APIResponse? {
        guard let webView else { return nil }
        let id = UUID().uuidString
        let literal = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return await withCheckedContinuation { (continuation: CheckedContinuation<APIResponse?, Never>) in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, let call = self.apiCalls[id] else { return }
                self.apiCalls[id] = nil
                call.continuation.resume(returning: nil)
            }
            apiCalls[id] = APICall(continuation: continuation, timeout: timeout)
            webView.evaluateJavaScript("window.__tiktokSignedFetch && window.__tiktokSignedFetch('\(literal)', '\(id)')",
                                       completionHandler: nil)
        }
    }

    private func evaluateString(_ js: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
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

    /// Navigue la WebView vers une autre page tiktok.com dans la même session.
    /// Même garde de 30 s que le chargement initial ; les corps capturés de
    /// la page précédente sont jetés pour ne pas polluer le nouveau fil.
    func navigate(_ url: URL) async -> Bool {
        guard let view = webView else { return false }
        pendingBodies.removeAll()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loadContinuation = continuation
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.finishLoad(false)
            }
            view.load(URLRequest(url: url))
        }
    }

    /// Adresse d'ouverture des Enregistres TikTok : le menu du profil est ouvert,
    /// et le premier lien `saved`/`bookmarks`/`favorites` du DOM sert de cible ;
    /// a defaut, la page profil du compte connecte est construite depuis le
    /// pseudo — l'onglet Favorites y sera clique ensuite.
    func savedPageURL() async -> URL? {
        guard let webView else { return nil }
        var payload: [String: Any]?
        for _ in 0..<3 {
            _ = (await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                webView.evaluateJavaScript("window.__tiktokOpenMenu && window.__tiktokOpenMenu()") { opened, _ in
                    continuation.resume(returning: (opened as? Bool) == true ? "menu" : nil)
                }
            } as String?)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let json: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                webView.evaluateJavaScript("window.__tiktokHarvestSaved && window.__tiktokHarvestSaved()") { result, _ in
                    continuation.resume(returning: result as? String)
                }
            }
            if let json, let data = json.data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                payload = parsed
                if ((parsed["links"] as? [String]) ?? []).isEmpty || ((parsed["user"] as? String) ?? "").isEmpty {
                    // Le menu met parfois un temps a se dessiner : reesayer.
                    continue
                }
                break
            }
        }
        guard let payload,
              let links = payload["links"] as? [String] else {
            LogCenter.info(L("TikTok web : le menu du profil n'a livre aucun lien.", "TikTok web: the profile menu gave up no link."))
            return nil
        }
        if let name = payload["user"] as? String, !name.isEmpty { pageUsername = name }
        for raw in links {
            let absolute = raw.hasPrefix("http") ? raw : "https://www.tiktok.com" + raw
            if let url = URL(string: absolute), url.host?.hasSuffix("tiktok.com") == true {
                LogCenter.info(L("TikTok web : lien Enregistres trouve \(absolute).", "TikTok web: saved link found \(absolute)."))
                return url
            }
        }
        if let name = (payload["user"] as? String), !name.isEmpty,
           let url = URL(string: "https://www.tiktok.com/@\(name)") {
            // Les Enregistres n'ont pas de route directe sur le site desktop :
            // ils vivent dans l'onglet Favorites du profil du compte connecte.
            LogCenter.info(L("TikTok web : profil \(name) ouvert, onglet Favorites a cliquer.", "TikTok web: profile \(name) opened, Favorites tab to click."))
            return url
        }
        LogCenter.info(L("TikTok web : aucun lien Enregistres visible (\(links.count) lien(s) scrute(s)).", "TikTok web: no visible saved link (\(links.count) link(s) scanned)."))
        return nil
    }

    /// Clique le premier élément de la page portant l'un des noms donnés
    /// (insensible à la casse) : sert à ouvrir l'onglet Favorites/Collections
    /// de la page Sauvegardés, qui ne charge pas toujours `collection_list`
    /// de son propre geste. Renvoie le nom cliqué, ou `nil` si rien ne
    /// correspond — le diagnostic dans le journal dit lequel des deux.
    func clickNamed(_ names: [String]) async -> String? {
        guard let webView else { return nil }
        let payload = (try? JSONSerialization.data(withJSONObject: names)) ?? Data()
        let literal = String(decoding: payload, as: UTF8.self)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript("window.__tiktokClickNamed && window.__tiktokClickNamed('\(literal)')") { result, _ in
                let clicked = result as? String
                continuation.resume(returning: (clicked?.isEmpty == false) ? clicked : nil)
            }
        }
    }

    /// Corps JSON suivant d'une route signée par le JavaScript de TikTok
    /// (`/item_list` par défaut, `/collection_list` pour les dossiers).
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
        for call in apiCalls.values {
            call.timeout.cancel()
            call.continuation.resume(returning: nil)
        }
        apiCalls.removeAll()
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
        if payload["kind"] as? String == "api" {
            guard let id = payload["id"] as? String, let call = apiCalls[id] else { return }
            apiCalls[id] = nil
            call.timeout.cancel()
            call.continuation.resume(returning: APIResponse(status: payload["status"] as? Int ?? 0,
                                                            body: payload["body"] as? String ?? ""))
            return
        }
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

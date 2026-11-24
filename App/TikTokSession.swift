import SwiftUI
import WebKit
import Combine
import MediaCore

/// Session TikTok obtenue par WebKit, sur le modèle de `XSession`.
///
/// tiktok.com ne sert les médias d'un profil qu'à un navigateur connecté :
/// l'API interne exige les cookies `sessionid` (connexion) et `ttwid`
/// (appareil), complétés par `msToken` sur les appels paginés. Ce stockage est
/// distinct de ceux de Reddit et de X pour qu'une déconnexion TikTok n'efface
/// aucune autre session, et inversement.
@Observable
@MainActor final class TikTokSession: NSObject, WKHTTPCookieStoreObserver {
    static let shared = TikTokSession()
    /// Profil WebKit persistant exclusivement réservé à TikTok, sans partage
    /// avec Reddit ni X. UUID constant : une même session est retrouvée au
    /// prochain lancement.
    let store = WKWebsiteDataStore(forIdentifier:
        UUID(uuidString: "5B7C1A62-9D4E-4F3A-8B21-6E0D9A47C3F1")!)
    private(set) var hasAPICredentials = false
    private(set) var hasSession = false
    private(set) var apiAccepted = false
    private(set) var apiRejected = false
    private var credentialValues: [String] = []
    private var cachedCookies: [HTTPCookie] = []
    private(set) var clearing = false

    private override init() {
        super.init()
        store.httpCookieStore.add(self)
        Task { await refresh() }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.refresh() }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    /// Les cookies permettent de tenter un appel ; seul un succès API valide
    /// leur acceptation par TikTok. La validation est oubliée quand l'identité
    /// de la session change.
    ///
    /// Seul `sessionid` est comparé. TikTok renouvelle `msToken` tout seul en
    /// cours de session : l'inclure ferait retomber l'indicateur « API
    /// acceptée » au moindre renouvellement de jeton.
    func refresh() async {
        let cookies = await allCookies()
        cachedCookies = cookies
        let identity = cookies.filter { $0.name == "sessionid" }
            .map { "\($0.domain)|\($0.path)|\($0.value)" }.sorted()
        let ready = !clearing && TikTokCookiePolicy.hasLoginCookie(cookies: cookies)
        let apiReady = ready && TikTokCookiePolicy.hasCredentials(cookies: cookies)
        let revoked = identity != credentialValues || !ready
        credentialValues = identity
        // Les propriétés observées sont réaffectées uniquement sur un
        // changement réel : `refresh()` est appelé à chaque écriture de
        // cookie par WebKit, et une réaffectation inutile aurait invalidé
        // les vues pour rien.
        if revoked {
            if apiAccepted { apiAccepted = false }
            if apiRejected { apiRejected = false }
        }
        if hasSession != ready { hasSession = ready }
        if hasAPICredentials != apiReady { hasAPICredentials = apiReady }
    }

    func recordAPIAcceptance(_ accepted: Bool) {
        apiAccepted = accepted
        apiRejected = !accepted
    }

    var statusText: String {
        if apiRejected { return L("Session TikTok refusée · reconnecte-toi", "TikTok session rejected · sign in again") }
        if apiAccepted { return L("Session TikTok acceptée au dernier appel", "TikTok session accepted on last request") }
        if !hasSession { return L("TikTok · connexion requise", "TikTok · sign-in required") }
        if !hasAPICredentials {
            return L("Connexion TikTok détectée · jeton ttwid en attente",
                     "TikTok signed in · waiting for ttwid token")
        }
        return L("Session TikTok détectée · accès API à vérifier",
                 "TikTok session detected · API access unverified")
    }

    /// En-tête `Cookie` pour les requêtes API, les pages tiktok.com et les
    /// CDN de médias (`*.tiktok.com`, inclus par `TikTokCookiePolicy`) : les
    /// nœuds `*-webapp-prime` lient chaque URL au cookie `tt_chain_token` posé
    /// dans ce magasin WebKit ; sans cookie prêté à URLSession, transfert
    /// refusé (HTTP 403).
    func cookieHeader(for url: URL) async -> String? {
        guard !clearing, TikTokCookiePolicy.allows(url) else { return nil }
        if cachedCookies.isEmpty { cachedCookies = await allCookies() }
        guard !clearing else { return nil }
        return TikTokCookiePolicy.header(cookies: cachedCookies, for: url)
    }

    func logout() async {
        clearing = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
        hasSession = false; hasAPICredentials = false
        apiAccepted = false; apiRejected = false
        credentialValues = []; cachedCookies = []; clearing = false
        NotificationCenter.default.post(name: .pocketSessionsDidChange, object: nil)
    }
}

struct TikTokLogin: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @Environment(\.dismiss) private var dismiss
    private var session = TikTokSession.shared
    @State private var errorMessage: String?
    @State private var webRevision = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TikTokWebContent(errorMessage: $errorMessage,
                                 initialURL: TikTokWebNavigation.loginURL)
                    .id(webRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 12) {
                    Button(L("Recharger", "Reload")) {
                        errorMessage = nil
                        webRevision += 1
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.space(3))
                .padding(.vertical, DS.space(2))
                .background(.bar)
            }
            .navigationTitle(session.statusText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await session.refresh(); dismiss() } } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L("Fermer la connexion", "Close sign-in"))
                }
            }
        }
        .errorAlert(errorMessage, onDismiss: { errorMessage = nil })
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct TikTokWebContent: UIViewControllerRepresentable {
    @Binding var errorMessage: String?
    let initialURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(errorMessage: $errorMessage) }

    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = TikTokSession.shared.store
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.keyboardDismissMode = .interactive
        view.load(URLRequest(url: initialURL))
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: controller.view.topAnchor),
            view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: controller.view.keyboardLayoutGuide.topAnchor)
        ])
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        for case let view as WKWebView in controller.view.subviews {
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var errorMessage: String?
        init(errorMessage: Binding<String?>) { _errorMessage = errorMessage }

        /// Les liens target=_blank et window.open ne chargent rien sans WKUIDelegate.
        /// Charge les destinations TikTok autorisées dans la WebView existante.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            guard let url = navigationAction.request.url, TikTokWebNavigation.allowsPopup(url) else {
                blockedNavigation()
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        /// Les redirections TikTok sont permises, ainsi que les fournisseurs
        /// de connexion sociale (Google, Facebook, Apple) ; pas les autres
        /// domaines tiers, qui pourraient recevoir accidentellement des
        /// cookies de session.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url, TikTokWebNavigation.allowsLogin(url) else {
                blockedNavigation()
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame {
                guard let url = navigationResponse.response.url, TikTokWebNavigation.allowsLogin(url) else {
                    blockedNavigation()
                    decisionHandler(.cancel); return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            errorMessage = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in await TikTokSession.shared.refresh() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as? URLError)?.code != .cancelled else { return }
            reportNavigationError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard (error as? URLError)?.code != .cancelled else { return }
            reportNavigationError(error)
        }

        private func blockedNavigation() {
            LogCenter.err(L("Connexion TikTok : navigation vers un domaine externe refusée.",
                            "TikTok sign-in: external-domain navigation blocked."))
            errorMessage = L("Cette connexion autorise uniquement les pages TikTok et celles de ses fournisseurs de connexion (Google, Facebook, Apple). Utilise tes identifiants TikTok dans le formulaire de connexion.",
                             "This sign-in only allows TikTok pages and its sign-in providers (Google, Facebook, Apple). Use your TikTok credentials in the sign-in form.")
        }

        private func reportNavigationError(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
                // WebKitErrorFrameLoadInterruptedByPolicyChange : navigation
                // annulée par une décision de navigation, pas refus de session.
                LogCenter.info(L("Navigation TikTok interrompue par une décision de navigation (WebKit 102).",
                                 "TikTok navigation interrupted by a navigation policy decision (WebKit 102)."))
                return
            }
            // Codes uniquement : ni URL de connexion, ni cookies dans le journal.
            let code = nsError.code
            LogCenter.err(L("Navigation TikTok impossible : erreur \(code).", "TikTok navigation failed: error \(code)."))
            errorMessage = L("La page de connexion TikTok n'a pas pu charger (erreur \(code)). Les cookies présents ne garantissent pas que cette page fonctionne.",
                             "The TikTok sign-in page could not load (error \(code)). Existing cookies do not guarantee that this page works.")
        }
    }
}


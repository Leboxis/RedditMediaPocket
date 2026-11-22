import SwiftUI
import WebKit
import Combine
import MediaCore

/// Session Instagram obtenue par WebKit, sur le modèle de `TikTokSession`.
///
/// Instagram ne sert plus `video_versions` aux clients déconnectés : sans
/// session, `api/graphql` ne rend qu'un quota anonyme (`Rate limit exceeded`,
/// code 1675004), et le repli SEO de la page ne contient que les images. Une
/// session connectée (`sessionid` + `csrftoken`) rend les publications
/// complètes, vidéos comprises. Ce stockage est distinct de ceux de Reddit, de
/// X et de TikTok : une déconnexion Instagram n'efface aucune autre session.
@MainActor final class InstagramSession: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    static let shared = InstagramSession()
    /// Profil WebKit persistant réservé à Instagram. UUID constant : la même
    /// session est retrouvée au prochain lancement.
    let store = WKWebsiteDataStore(forIdentifier:
        UUID(uuidString: "3C9D7E41-2B58-4A6F-9E10-7D4B8A5C2F63")!)
    @Published private(set) var hasAPICredentials = false
    @Published private(set) var hasSession = false
    @Published private(set) var apiAccepted = false
    @Published private(set) var apiRejected = false
    private var credentialValues: [String] = []
    private var cachedCookies: [HTTPCookie] = []
    @Published private(set) var clearing = false

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
    /// leur acceptation par Instagram. La validation est oubliée quand
    /// l'identité de la session change.
    ///
    /// Seul `sessionid` est comparé : Instagram renouvelle `csrftoken` en cours
    /// de session, et l'inclure ferait retomber l'indicateur « API acceptée ».
    func refresh() async {
        let cookies = await allCookies()
        cachedCookies = cookies
        let identity = cookies.filter { $0.name == "sessionid" }
            .map { "\($0.domain)|\($0.path)|\($0.value)" }.sorted()
        let ready = !clearing && InstagramCookiePolicy.hasLoginCookie(cookies: cookies)
        let apiReady = ready && InstagramCookiePolicy.hasCredentials(cookies: cookies)
        let revoked = identity != credentialValues || !ready
        credentialValues = identity
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
        if apiRejected { return L("Session Instagram refusée · reconnecte-toi", "Instagram session rejected · sign in again") }
        if apiAccepted { return L("Session Instagram acceptée au dernier appel", "Instagram session accepted on last request") }
        if !hasSession { return L("Instagram · connexion requise pour les vidéos", "Instagram · sign-in required for videos") }
        if !hasAPICredentials {
            return L("Connexion Instagram détectée · jeton csrftoken en attente",
                     "Instagram signed in · waiting for csrftoken")
        }
        return L("Session Instagram détectée · accès API à vérifier",
                 "Instagram session detected · API access unverified")
    }

    /// En-tête `Cookie` pour la page du profil et l'appel GraphQL. Le CDN de
    /// médias en est exclu par `InstagramCookiePolicy` : ses URL sont signées et
    /// ne recevront jamais le jeton de session.
    func cookieHeader(for url: URL) async -> String? {
        guard !clearing, InstagramCookiePolicy.allows(url) else { return nil }
        if cachedCookies.isEmpty { cachedCookies = await allCookies() }
        guard !clearing else { return nil }
        return InstagramCookiePolicy.header(cookies: cachedCookies, for: url)
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

struct InstagramLogin: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = InstagramSession.shared
    @State private var errorMessage: String?
    @State private var webRevision = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                InstagramWebContent(errorMessage: $errorMessage,
                                    initialURL: InstagramWebNavigation.loginURL)
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

private struct InstagramWebContent: UIViewControllerRepresentable {
    @Binding var errorMessage: String?
    let initialURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(errorMessage: $errorMessage) }

    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = InstagramSession.shared.store
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

        /// Les liens target=_blank et window.open ne chargent rien sans
        /// WKUIDelegate. Charge les destinations autorisées dans la WebView.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            guard let url = navigationAction.request.url, InstagramWebNavigation.allowsPopup(url) else {
                blockedNavigation()
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        /// Les redirections Instagram sont permises, ainsi que ses fournisseurs
        /// de connexion sociale (Facebook, Google, Apple) ; pas les autres
        /// domaines tiers, qui pourraient recevoir des cookies de session.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url, InstagramWebNavigation.allowsLogin(url) else {
                blockedNavigation()
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame {
                guard let url = navigationResponse.response.url, InstagramWebNavigation.allowsLogin(url) else {
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
            Task { @MainActor in await InstagramSession.shared.refresh() }
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
            LogCenter.err(L("Connexion Instagram : navigation vers un domaine externe refusée.",
                            "Instagram sign-in: external-domain navigation blocked."))
            errorMessage = L("Cette connexion autorise uniquement les pages Instagram et celles de ses fournisseurs de connexion (Facebook, Google, Apple). Utilise tes identifiants Instagram dans le formulaire de connexion.",
                             "This sign-in only allows Instagram pages and its sign-in providers (Facebook, Google, Apple). Use your Instagram credentials in the sign-in form.")
        }

        private func reportNavigationError(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
                // WebKitErrorFrameLoadInterruptedByPolicyChange : navigation
                // annulée par une décision, pas refus de session.
                LogCenter.info(L("Navigation Instagram interrompue par une décision de navigation (WebKit 102).",
                                 "Instagram navigation interrupted by a navigation policy decision (WebKit 102)."))
                return
            }
            // Codes uniquement : ni URL de connexion, ni cookies dans le journal.
            let code = nsError.code
            LogCenter.err(L("Navigation Instagram impossible : erreur \(code).", "Instagram navigation failed: error \(code)."))
            errorMessage = L("La page de connexion Instagram n'a pas pu charger (erreur \(code)). Les cookies présents ne garantissent pas que cette page fonctionne.",
                             "The Instagram sign-in page could not load (error \(code)). Existing cookies do not guarantee that this page works.")
        }
    }
}


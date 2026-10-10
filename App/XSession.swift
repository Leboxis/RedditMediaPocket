import SwiftUI
import WebKit
import Combine
import MediaCore

/// Session X obtenue par WebKit, sur le modèle de `RedditSession`.
///
/// x.com n'autorise aucun accès anonyme aux médias : l'API GraphQL interne
/// exige les cookies `auth_token` (session) et `ct0` (CSRF). Ce stockage est
/// distinct de celui de Reddit pour qu'une déconnexion X n'efface pas la
/// session Reddit, et inversement.
@MainActor final class XSession: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    static let shared = XSession()
    /// Profil WebKit persistant exclusivement réservé à X, sans partage avec Reddit.
    /// UUID constant : une même session est retrouvée au prochain lancement.
    let store = WKWebsiteDataStore(forIdentifier:
        UUID(uuidString: "E9F9D960-81B3-43D3-85DB-65DCBE7F82CE")!)
    @Published private(set) var hasAPICredentials = false
    @Published private(set) var hasSession = false
    @Published private(set) var apiAccepted = false
    @Published private(set) var apiRejected = false
    private var credentialValues: [String] = []
    @Published private(set) var revision = 0
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
    /// leur acceptation par X. La validation est oubliée quand ils changent.
    func refresh() async {
        let cookies = await allCookies()
        let values = cookies.filter { $0.name == "auth_token" || $0.name == "ct0" }
            .map { "\($0.domain)|\($0.path)|\($0.name)|\($0.value)" }.sorted()
        let ready = !clearing && XTwitterCookiePolicy.hasLoginCookie(cookies: cookies)
        let apiReady = ready && XTwitterCookiePolicy.hasCredentials(cookies: cookies)
        if values != credentialValues || !ready {
            apiAccepted = false
            apiRejected = false
        }
        credentialValues = values
        hasSession = ready
        hasAPICredentials = apiReady
        revision += 1
    }

    func recordAPIAcceptance(_ accepted: Bool) {
        apiAccepted = accepted
        apiRejected = !accepted
    }

    var statusText: String {
        if apiRejected { return L("Session X refusée · reconnecte-toi", "X session rejected · sign in again") }
        if apiAccepted { return L("Session X acceptée au dernier appel", "X session accepted on last request") }
        if !hasSession { return L("X · connexion requise", "X · sign-in required") }
        if !hasAPICredentials {
            return L("Connexion X détectée · jeton CSRF en attente",
                     "X signed in · waiting for CSRF token")
        }
        return L("Session X détectée · accès API à vérifier",
                 "X session detected · API access unverified")
    }

    /// Jeton CSRF `ct0`, exigé par l'API GraphQL. Il peut apparaître
    /// après `auth_token` : son absence ne prouve pas une déconnexion.
    func csrfToken() async -> String? {
        let cookies = await allCookies()
        return XTwitterCookiePolicy.csrfToken(cookies: cookies)
    }

    /// En-tête `Cookie` pour les requêtes API. Le CDN média en est exclu par
    /// `XTwitterCookiePolicy` : ces URL sont publiques et ne recevront jamais
    /// le jeton de session.
    func cookieHeader(for url: URL) async -> String? {
        guard !clearing, XTwitterCookiePolicy.allows(url) else { return nil }
        let cookies = await allCookies()
        guard !clearing else { return nil }
        return XTwitterCookiePolicy.header(cookies: cookies, for: url)
    }

    func logout() async {
        clearing = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
        hasSession = false; hasAPICredentials = false
        apiAccepted = false; apiRejected = false
        credentialValues = []; revision += 1; clearing = false
    }
}

struct XLogin: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = XSession.shared
    @State private var errorMessage: String?
    @State private var webRevision = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                XWebContent(errorMessage: $errorMessage,
                            initialURL: XWebNavigation.loginURL)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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

private struct XWebContent: UIViewControllerRepresentable {
    @Binding var errorMessage: String?
    let initialURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(errorMessage: $errorMessage) }

    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = XSession.shared.store
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
        /// Charge les destinations X autorisées dans la WebView existante.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            guard let url = navigationAction.request.url, XWebNavigation.allowsPopup(url) else {
                blockedNavigation()
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        /// Les redirections X/Twitter sont permises mais pas les domaines tiers,
        /// qui pourraient recevoir accidentellement des cookies de session.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url, XTwitterCookiePolicy.allows(url) else {
                blockedNavigation()
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame {
                guard let url = navigationResponse.response.url, XTwitterCookiePolicy.allows(url) else {
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
            Task { @MainActor in await XSession.shared.refresh() }
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
            LogCenter.err(L("Connexion X : navigation vers un domaine externe refusée.",
                            "X sign-in: external-domain navigation blocked."))
            errorMessage = L("Cette connexion autorise uniquement les pages X. Utilise tes identifiants X dans le formulaire de connexion.",
                             "This sign-in only allows X pages. Use your X credentials in the sign-in form.")
        }

        private func reportNavigationError(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
                // WebKitErrorFrameLoadInterruptedByPolicyChange : navigation
                // annulée par une décision de navigation, pas refus de session.
                LogCenter.info(L("Navigation X interrompue par une décision de navigation (WebKit 102).",
                                 "X navigation interrupted by a navigation policy decision (WebKit 102)."))
                return
            }
            // Codes uniquement : ni URL de connexion, ni cookies dans le journal.
            let code = nsError.code
            LogCenter.err(L("Navigation X impossible : erreur \(code).", "X navigation failed: error \(code)."))
            errorMessage = L("La page de connexion X n’a pas pu charger (erreur \(code)). Les cookies présents ne garantissent pas que cette page fonctionne.",
                             "The X sign-in page could not load (error \(code)). Existing cookies do not guarantee that this page works.")
        }
    }
}

struct XSessionIndicator: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @ObservedObject private var session = XSession.shared
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.apiAccepted ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark")
                .font(.title3)
            Text(session.statusText)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .foregroundStyle(session.apiAccepted ? Color.green : (session.apiRejected ? Color.red : Color.secondary))
        .padding(12)
        .background(session.apiAccepted ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

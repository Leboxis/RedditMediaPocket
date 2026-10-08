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
    /// Store dédié : `WKWebsiteDataStore.default()` est déjà utilisé par Reddit.
    let store = WKWebsiteDataStore.nonPersistent()
    @Published private(set) var hasSession = false
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

    /// `auth_token` est le seul marqueur de session réellement publié par x.com :
    /// sa présence signifie « connecté », sans prétendre que le compte a été
    /// validé côté serveur. Même lecture que `RedditSession.hasSession`.
    func refresh() async {
        let cookies = await allCookies()
        hasSession = cookies.contains {
            $0.name == "auth_token" && !$0.value.isEmpty
        }
        revision += 1
    }

    /// Jeton CSRF `ct0`, exigé par l'API GraphQL. Une session valide en a
    /// toujours un ; son absence signifie session expirée.
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
        hasSession = false; revision += 1; clearing = false
    }
}

struct XLogin: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = XSession.shared
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                XWebLogin(errorMessage: $errorMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(session.hasSession ? L("X · session détectée", "X · session detected") : "x.com")
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

private struct XWebLogin: UIViewControllerRepresentable {
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator { Coordinator(errorMessage: $errorMessage) }

    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = XSession.shared.store
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.keyboardDismissMode = .interactive
        view.load(URLRequest(url: URL(string: "https://x.com/i/flow/login")!))
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
        for case let view as WKWebView in controller.view.subviews { view.stopLoading(); view.navigationDelegate = nil }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var errorMessage: String?
        init(errorMessage: Binding<String?>) { _errorMessage = errorMessage }

        /// Le parcours de connexion traverse `accounts.x.com` puis `x.com` :
        /// seuls ces hôtes sont autorisés, pas `twitter.com`.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url, XTwitterCookiePolicy.allows(url) else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame {
                guard let url = navigationResponse.response.url, XTwitterCookiePolicy.allows(url) else { decisionHandler(.cancel); return }
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
            errorMessage = L("Connexion X indisponible. Ferme puis réessaie.", "X sign-in unavailable. Close and try again.")
        }
    }
}

struct XSessionIndicator: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @ObservedObject private var session = XSession.shared
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.hasSession ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark")
                .font(.title3)
            Text(session.hasSession ? L("Session X détectée", "X session detected") : L("X · sans session", "X · signed out"))
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .foregroundStyle(session.hasSession ? Color.green : Color.secondary)
        .padding(12)
        .background(session.hasSession ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
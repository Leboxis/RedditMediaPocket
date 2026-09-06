import SwiftUI
import WebKit
import Combine
import MediaCore

@MainActor final class RedditSession: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    static let shared = RedditSession()
    let store = WKWebsiteDataStore.default()
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
    func refresh() async {
        let cookies = await allCookies()
        hasSession = cookies.contains {
            $0.name == "reddit_session" && RedditCookiePolicy.header(cookies: [$0], for: URL(string: "https://www.reddit.com/")!) != nil
        }
        revision += 1
    }
    func cookieHeader(for url: URL) async -> String? {
        guard !clearing, RedditCookiePolicy.allows(url) else { return nil }
        let cookies = await allCookies()
        guard !clearing else { return nil }
        return RedditCookiePolicy.header(cookies: cookies, for: url)
    }
    func logout() async {
        clearing = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
        hasSession = false; revision += 1; clearing = false
    }
}

struct RedditLogin: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = RedditSession.shared
    @State private var message = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).padding(10) }
                RedditWebLogin(message: $message)
            }
            .navigationTitle("reddit.com")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { Task { await session.refresh(); dismiss() } }
                }
            }
        }
    }
}

private struct RedditWebLogin: UIViewRepresentable {
    @Binding var message: String
    func makeCoordinator() -> Coordinator { Coordinator(message: $message) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = RedditSession.shared.store
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://www.reddit.com/login/")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var message: String
        init(message: Binding<String>) { _message = message }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url, RedditCookiePolicy.allows(url) else {
                message = "Utilise la connexion Reddit par identifiant et mot de passe."
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame {
                guard let url = navigationResponse.response.url, RedditCookiePolicy.allows(url) else { decisionHandler(.cancel); return }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in await RedditSession.shared.refresh() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            message = "Connexion indisponible. Ferme puis réessaie."
        }
    }
}

// Rebuild cookies for each redirect, preventing forwarding to a media CDN or third party.
final class SafeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https" else { completionHandler(nil); return }
        Task { @MainActor in
            var redirected = request
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            if url.host != response.url?.host { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
            if let cookie = await RedditSession.shared.cookieHeader(for: url) {
                redirected.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            completionHandler(redirected)
        }
    }
}

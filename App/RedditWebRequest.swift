import Foundation
import WebKit

/// Read private JSON in the same WebKit cookie store and browser context as login.
/// A request owns its web view; cancellation/timeout always releases its continuation.
@MainActor final class RedditWebRequest: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: HTTPURLResponse?
    private var timeout: Task<Void, Never>?

    func data(_ url: URL) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard url.scheme == "https", url.host == "www.reddit.com" else {
            throw NetworkError.invalid("Adresse Reddit invalide.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = WKWebViewConfiguration()
                config.websiteDataStore = RedditSession.shared.store
                let view = WKWebView(frame: .zero, configuration: config)
                self.view = view
                view.navigationDelegate = self
                view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60))
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        view?.navigationDelegate = nil
        view?.stopLoading(); view = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.scheme == "https", url.host == "www.reddit.com" else {
            decisionHandler(.cancel)
            finish(.failure(NetworkError.invalid("Reddit demande une nouvelle connexion dans les Réglages.")))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let http = navigationResponse.response as? HTTPURLResponse else {
            decisionHandler(.cancel); finish(.failure(URLError(.badServerResponse))); return
        }
        response = http
        guard (200...299).contains(http.statusCode) else {
            decisionHandler(.cancel)
            // Network applies the common HTTP/quota policy, including Retry-After.
            finish(.success((Data(), http)))
            return
        }
        guard http.mimeType == "application/json" else {
            decisionHandler(.cancel)
            finish(.failure(NetworkError.invalid("Session Reddit expirée ou connexion à confirmer dans les Réglages.")))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body.innerText", in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value):
                guard let text = value as? String, let response = self.response else {
                    self.finish(.failure(URLError(.cannotParseResponse))); return
                }
                self.finish(.success((Data(text.utf8), response)))
            case .failure(let error): self.finish(.failure(error))
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(URLError(.networkConnectionLost)))
    }
}

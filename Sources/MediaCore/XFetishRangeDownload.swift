import Foundation

/// HTTP byte ranges of one MP4, not DASH tracks. Bodies stream straight to disk.
public enum XFetishRangeDownload {
    public static let defaultsKey = "xFetishDownloadSegments"
    public static let segmentOptions = [8, 16, 24, 32]
    private static let maximumSegments = 32

    public enum Failure: LocalizedError {
        case unsupportedRanges, invalidResponse, http(HTTPURLResponse)

        public var errorDescription: String? {
            switch self {
            case .unsupportedRanges:
                return L("Plage HTTP X-Fetish invalide.", "Invalid X-Fetish HTTP range.")
            case .invalidResponse:
                return L("Réponse vidéo X-Fetish invalide.", "Invalid X-Fetish video response.")
            case .http(let response):
                return L("X-Fetish : HTTP \(response.statusCode).", "X-Fetish: HTTP \(response.statusCode).")
            }
        }
    }

    public static func segmentCount(_ stored: Int?) -> Int {
        guard let stored, segmentOptions.contains(stored) else { return 24 }
        return stored
    }

    static func ranges(total: Int64, count: Int) -> [ClosedRange<Int64>] {
        let count = max(1, min(maximumSegments, count))
        guard count > 1, total > 4 * 1024 * 1024, total <= 2 * 1024 * 1024 * 1024 else { return [] }
        return (0..<count).map { index in
            (total * Int64(index) / Int64(count))...(total * Int64(index + 1) / Int64(count) - 1)
        }
    }

    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && XFetishAPI.isXFetish(url) && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    public static func allowsStorage(_ url: URL) -> Bool {
        guard allows(url), let host = url.host?.lowercased() else { return false }
        return host.hasPrefix("storage") && host.hasSuffix(".x-fetish.tube")
    }

    static func contentRange(_ value: String?) -> (range: ClosedRange<Int64>, total: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start...end, total)
    }

    /// The caller first redeems get_file over IPv4 and supplies its browser headers.
    /// Each worker owns a file handle, so seeks in different ranges cannot race.
    public static func download(_ request: URLRequest, to destination: URL, segments: Int,
        configuration: URLSessionConfiguration = .ephemeral,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        guard let url = request.url, allowsStorage(url) else { throw Failure.invalidResponse }
        try Task.checkCancellation()
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = maximumSegments
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue(nil, forHTTPHeaderField: "Range")
        let fullRequest = request
        let part = destination.appendingPathExtension("part")
        let fm = FileManager.default
        var ownsPart = false
        defer { if ownsPart { try? fm.removeItem(at: part) } }

        let count = max(1, min(maximumSegments, segments))
        let rangeSession = RangeSession(configuration: configuration)
        defer { rangeSession.invalidate() }
        if count > 1 {
            do {
                let probe = try await rangeSession.fetch(fullRequest, range: 0...0)
                guard let total = contentRange(probe.value(forHTTPHeaderField: "Content-Range"))?.total else {
                    throw Failure.unsupportedRanges
                }
                let byteRanges = ranges(total: total, count: count)
                if !byteRanges.isEmpty {
                    try Data().write(to: part, options: .withoutOverwriting)
                    ownsPart = true
                    let aggregate = RangeProgress(count: byteRanges.count, total: total, report: progress)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for (index, range) in byteRanges.enumerated() {
                            group.addTask {
                                _ = try await rangeSession.fetch(fullRequest,
                                    file: part, range: range, total: total,
                                    progress: { received, _ in aggregate.update(index, received) })
                            }
                        }
                        do { while try await group.next() != nil { } }
                        catch { group.cancelAll(); throw error }
                    }
                    try Task.checkCancellation()
                    try fm.moveItem(at: part, to: destination)
                    ownsPart = false
                    return
                }
            } catch {
                try Task.checkCancellation()
                if DownloadFailurePolicy.isCancellation(error) { throw error }
                if case Failure.http(let response) = error,
                   response.statusCode == 403 || response.statusCode == 429 { throw error }
                // Only a range/network failure justifies a full retry, never a disk error.
                guard error is Failure || error is URLError else { throw error }
                if ownsPart { try fm.removeItem(at: part); ownsPart = false }
            }
        }
        try Task.checkCancellation()
        try Data().write(to: part, options: .withoutOverwriting)
        ownsPart = true
        let aggregate = RangeProgress(count: 1, total: nil, report: progress)
        _ = try await rangeSession.fetch(fullRequest, file: part,
            progress: { received, total in aggregate.update(0, received, total: total) })
        try Task.checkCancellation()
        try fm.moveItem(at: part, to: destination)
        ownsPart = false
    }
}

private final class RangeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int64]
    private var totalReceived: Int64 = 0
    private let total: Int64?
    private var lastReport = Date.distantPast
    private let report: (@Sendable (Int64, Int64) -> Void)?

    init(count: Int, total: Int64?, report: (@Sendable (Int64, Int64) -> Void)?) {
        received = Array(repeating: 0, count: count)
        self.total = total; self.report = report
    }
    func update(_ index: Int, _ bytes: Int64, total expected: Int64 = 0) {
        lock.lock(); defer { lock.unlock() }
        totalReceived += bytes - received[index]
        received[index] = bytes
        let done = totalReceived, expectedTotal = self.total ?? expected
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.3 || (expectedTotal > 0 && done == expectedTotal) {
            lastReport = now
            report?(done, expectedTotal)
        }
    }
}

/// Une seule `URLSession` + file série partagée par tous les segments d'un
/// téléchargement vidéo X-Fetish (évite 25-33 sessions/TLS séparées par fichier).
private final class RangeSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [Int: RangeStream] = [:]
    private var invalidated = false
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func fetch(_ request: URLRequest, file: URL? = nil, range: ClosedRange<Int64>? = nil, total: Int64? = nil,
               progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> HTTPURLResponse {
        let stream = RangeStream(file: file, range: range, total: total, progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var request = request
                if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
                start(stream: stream, request: request, continuation: continuation)
            }
        } onCancel: {
            stream.cancel()
        }
    }

    private func start(stream: RangeStream, request: URLRequest, continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        stream.lock.lock()
        guard !stream.cancelled else {
            stream.lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            stream.lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        let task = session.dataTask(with: request)
        stream.task = task
        stream.continuation = continuation
        streams[task.taskIdentifier] = stream
        lock.unlock()
        stream.lock.unlock()
        task.resume()
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let pending = Array(streams.values)
        lock.unlock()
        for stream in pending { stream.cancel() }
        session.invalidateAndCancel()
    }

    private func stream(for task: URLSessionTask) -> RangeStream? {
        lock.lock(); defer { lock.unlock() }
        return streams[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let stream = stream(for: dataTask) else { completionHandler(.cancel); return }
        stream.didReceive(response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stream(for: dataTask)?.didReceive(data: data, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let stream = streams.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        stream?.didComplete(error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let stream = stream(for: task) else { completionHandler(nil); return }
        stream.willRedirect(task: task, newRequest: request, completionHandler: completionHandler)
    }
}

/// État d'un flux de segment individuel ; callbacks sérialisés par `RangeSession`.
private final class RangeStream: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false
    var task: URLSessionDataTask?
    var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var redirects = 0
    private let file: URL?
    private let range: ClosedRange<Int64>?
    private let total: Int64?
    private let progress: (@Sendable (Int64, Int64) -> Void)?

    init(file: URL?, range: ClosedRange<Int64>?, total: Int64?,
         progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.file = file; self.range = range; self.total = total; self.progress = progress
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    func didReceive(response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, let url = http.url,
                  XFetishRangeDownload.allowsStorage(url) else { throw XFetishRangeDownload.Failure.invalidResponse }
            if http.statusCode >= 400 { throw XFetishRangeDownload.Failure.http(http) }
            if let range {
                guard http.statusCode == 206,
                      let content = XFetishRangeDownload.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                      content.range == range, total == nil || content.total == total else {
                    throw XFetishRangeDownload.Failure.unsupportedRanges
                }
                expected = range.upperBound - range.lowerBound + 1
            } else {
                guard http.statusCode == 200 else { throw XFetishRangeDownload.Failure.invalidResponse }
                expected = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            }
            let mime = http.mimeType?.lowercased() ?? ""
            guard mime.hasPrefix("video/") || mime == "application/octet-stream",
                  (http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity") == "identity" else {
                throw XFetishRangeDownload.Failure.invalidResponse
            }
            if let range, let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard Int64(length) == range.upperBound - range.lowerBound + 1 else {
                    throw XFetishRangeDownload.Failure.unsupportedRanges
                }
            }
            if let file {
                let handle = try FileHandle(forWritingTo: file)
                self.handle = handle
                try handle.seek(toOffset: UInt64(range?.lowerBound ?? 0))
            }
            self.response = http
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func didReceive(data: Data, task: URLSessionDataTask) {
        guard failure == nil else { return }
        do {
            if let expected, Int64(data.count) > expected - received {
                throw XFetishRangeDownload.Failure.unsupportedRanges
            }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            progress?(received, expected ?? 0)
        } catch { failure = error; task.cancel() }
    }

    func didComplete(error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        lock.unlock()
        guard let continuation else { return }
        var finalError = failure ?? error
        if finalError == nil && wasCancelled { finalError = CancellationError() }
        do { try handle?.close() } catch let closeError { finalError = finalError ?? closeError }
        handle = nil
        if let finalError { continuation.resume(throwing: finalError) }
        else if let response, received > 0, expected == nil || received == expected {
            continuation.resume(returning: response)
        } else { continuation.resume(throwing: XFetishRangeDownload.Failure.unsupportedRanges) }
    }

    func willRedirect(task: URLSessionTask, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard redirects < 5, let url = request.url, XFetishRangeDownload.allowsStorage(url) else {
            failure = XFetishRangeDownload.Failure.invalidResponse
            completionHandler(nil)
            return
        }
        redirects += 1
        var request = request
        for (field, value) in task.originalRequest?.allHTTPHeaderFields ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        completionHandler(request)
    }
}

import Foundation

/// HTTP byte ranges of one MP4, not DASH tracks. Bodies stream straight to disk.
public enum XFetishRangeDownload {
    public static let defaultsKey = "xFetishDownloadSegments"

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

    public static func segmentCount(_ stored: Int?) -> Int { max(1, min(12, stored ?? 4)) }

    static func ranges(total: Int64, count: Int) -> [ClosedRange<Int64>] {
        let count = segmentCount(count)
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
        configuration.httpMaximumConnectionsPerHost = 12
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

        let count = segmentCount(segments)
        if count > 1 {
            do {
                let probe = try await RangeStream.fetch(fullRequest, configuration: configuration, range: 0...0)
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
                                _ = try await RangeStream.fetch(fullRequest, configuration: configuration,
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
        _ = try await RangeStream.fetch(fullRequest, configuration: configuration, file: part,
            progress: { received, total in aggregate.update(0, received, total: total) })
        try Task.checkCancellation()
        try fm.moveItem(at: part, to: destination)
        ownsPart = false
    }
}

private final class RangeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int64]
    private let total: Int64?
    private var lastReport = Date.distantPast
    private let report: (@Sendable (Int64, Int64) -> Void)?

    init(count: Int, total: Int64?, report: (@Sendable (Int64, Int64) -> Void)?) {
        received = Array(repeating: 0, count: count)
        self.total = total; self.report = report
    }
    func update(_ index: Int, _ bytes: Int64, total expected: Int64 = 0) {
        lock.lock(); defer { lock.unlock() }
        received[index] = bytes
        let done = received.reduce(0, +), expectedTotal = self.total ?? expected
        if Date().timeIntervalSince(lastReport) >= 0.3 || (expectedTotal > 0 && done == expectedTotal) {
            lastReport = Date()
            report?(done, expectedTotal)
        }
    }
}

/// Delegate callbacks run on one serial queue; cancellation only touches the task under a lock.
private final class RangeStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
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

    private init(file: URL?, range: ClosedRange<Int64>?, total: Int64?,
                 progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.file = file; self.range = range; self.total = total; self.progress = progress
    }

    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration,
        file: URL? = nil, range: ClosedRange<Int64>? = nil, total: Int64? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> HTTPURLResponse {
        let stream = RangeStream(file: file, range: range, total: total, progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                stream.lock.lock(); defer { stream.lock.unlock() }
                guard !stream.cancelled else { continuation.resume(throwing: CancellationError()); return }
                stream.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: stream, delegateQueue: queue)
                stream.session = session
                var request = request
                if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                stream.task = task
                task.resume()
            }
        } onCancel: {
            stream.lock.lock(); defer { stream.lock.unlock() }
            stream.cancelled = true
            stream.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            if let expected, Int64(data.count) > expected - received {
                throw XFetishRangeDownload.Failure.unsupportedRanges
            }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            progress?(received, expected ?? 0)
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        var error = failure ?? error
        do { try handle?.close() } catch let closeError { error = error ?? closeError }
        handle = nil
        session.invalidateAndCancel()
        self.session = nil
        if let error { continuation.resume(throwing: error) }
        else if let response, received > 0, expected == nil || received == expected {
            continuation.resume(returning: response)
        } else { continuation.resume(throwing: XFetishRangeDownload.Failure.unsupportedRanges) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
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

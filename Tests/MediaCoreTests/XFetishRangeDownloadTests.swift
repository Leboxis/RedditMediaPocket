import XCTest
@testable import MediaCore

final class XFetishRangeDownloadTests: XCTestCase {
    func testSegmentPreferenceUsesOnlyTheFourSupportedChoices() {
        XCTAssertEqual(XFetishRangeDownload.segmentOptions, [8, 16, 24, 32])
        XCTAssertEqual(XFetishRangeDownload.segmentCount(nil), 24)
        for count in [8, 16, 24, 32] { XCTAssertEqual(XFetishRangeDownload.segmentCount(count), count) }
    }

    func testLegacyAndInvalidPreferencesFallBackToTwentyFour() {
        for count in [-1, 0, 1, 2, 4, 6, 10, 12, 15, 17, 31, 33, 99] {
            XCTAssertEqual(XFetishRangeDownload.segmentCount(count), 24)
        }
    }

    func testRangesCoverAnUnevenFileWithoutOverlaps() {
        let total: Int64 = 4 * 1024 * 1024 + 17
        for count in Array(2...12) + [16, 24, 32] {
            let ranges = XFetishRangeDownload.ranges(total: total, count: count)
            XCTAssertEqual(ranges.count, count)
            XCTAssertEqual(ranges.first?.lowerBound, 0)
            XCTAssertEqual(ranges.last?.upperBound, total - 1)
            XCTAssertEqual(ranges.reduce(Int64(0)) { $0 + $1.upperBound - $1.lowerBound + 1 }, total)
            for index in 1..<ranges.count {
                XCTAssertEqual(ranges[index - 1].upperBound + 1, ranges[index].lowerBound)
            }
        }
    }

    func testRangeCountRemainsBoundedAt32() {
        let ranges = XFetishRangeDownload.ranges(total: 4 * 1024 * 1024 + 17, count: 99)
        XCTAssertEqual(ranges.count, 32)
    }

    func testSmallUnknownAndOversizedTotalsUseOneConnection() {
        let totals: [Int64] = [0, 1, 4 * 1024 * 1024, 2 * 1024 * 1024 * 1024 + 1]
        for total in totals {
            XCTAssertTrue(XFetishRangeDownload.ranges(total: total, count: 4).isEmpty)
        }
    }

    func testContentRangeRejectsUnknownOverflowAndInvalidBounds() {
        for raw in ["bytes 0-0/*", "bytes -1-0/10", "bytes 9-1/10", "bytes 0-10/10",
                    "bytes 0-0/99999999999999999999", "items 0-0/10", "bytes 0-0/0"] {
            XCTAssertNil(XFetishRangeDownload.contentRange(raw))
        }
        XCTAssertEqual(XFetishRangeDownload.contentRange("bytes 0-0/10")?.total, 10)
    }

    func testStorageValidationRejectsTheIPv6SiteAndForeignHosts() {
        XCTAssertTrue(XFetishRangeDownload.allowsStorage(URL(string: "https://storage4.x-fetish.tube/remote_control.php?acctoken=secret")!))
        for raw in ["https://x-fetish.tube/get_file/1/a.mp4", "https://storage1.evil.example/a.mp4",
                    "http://storage1.x-fetish.tube/a.mp4", "https://storage1.x-fetish.tube:444/a.mp4"] {
            XCTAssertFalse(XFetishRangeDownload.allowsStorage(URL(string: raw)!))
        }
    }

    func testExistingPartFileIsNeverOverwrittenOrDeleted() async throws {
        let fixture = try RangeFixture()
        defer { fixture.remove() }
        let part = fixture.output.appendingPathExtension("part")
        let original = Data("existing partial file".utf8)
        try original.write(to: part)
        do {
            try await XFetishRangeDownload.download(fixture.request, to: fixture.output, segments: 1,
                                                    configuration: fixture.configuration)
            XCTFail("Expected exclusive creation to fail")
        } catch { XCTAssertEqual(try Data(contentsOf: part), original) }
        XCTAssertTrue(fixture.server.ranges.isEmpty)
    }

    func testParallelRangesProduceExactFileAndProgress() async throws {
        for count in [8, 16, 24, 32] {
            let fixture = try RangeFixture()
            defer { fixture.remove() }
            let progress = ByteProgress()
            try await XFetishRangeDownload.download(fixture.request, to: fixture.output, segments: count,
                configuration: fixture.configuration, progress: { received, total in progress.record(received, total) })
            XCTAssertEqual(try Data(contentsOf: fixture.output), fixture.body)
            let requests = fixture.server.ranges
            XCTAssertEqual(requests.count, count + 1, "One probe followed by the selected number of ranges")
            XCTAssertEqual(Set(requests).count, count + 1, "Ranges must be distinct")
            XCTAssertTrue(requests.contains("bytes=0-0"))
            XCTAssertFalse(requests.contains("full"))
            XCTAssertEqual(progress.last?.0, Int64(fixture.body.count))
            XCTAssertEqual(progress.last?.1, Int64(fixture.body.count))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.appendingPathExtension("part").path))
        }
    }

    func testOneSegmentSkipsProbe() async throws {
        let fixture = try RangeFixture()
        defer { fixture.remove() }
        try await XFetishRangeDownload.download(fixture.request, to: fixture.output, segments: 1,
                                                configuration: fixture.configuration)
        XCTAssertEqual(fixture.server.ranges, ["full"])
        XCTAssertEqual(try Data(contentsOf: fixture.output), fixture.body)
    }

    func testUnsupportedProbeAndBadRangeFallBackToFullDownload() async throws {
        for mode in [RangeServer.Mode.ignoresRanges, .wrongRange, .truncated] {
            let fixture = try RangeFixture(mode: mode)
            defer { fixture.remove() }
            try await XFetishRangeDownload.download(fixture.request, to: fixture.output, segments: 4,
                                                    configuration: fixture.configuration)
            XCTAssertEqual(try Data(contentsOf: fixture.output), fixture.body)
            XCTAssertEqual(fixture.server.ranges.filter { $0 == "full" }.count, 1)
        }
    }

    func testForbiddenAndRateLimitDoNotFallBackAndLeaveNoFiles() async throws {
        for mode in [RangeServer.Mode.forbidden, .limited] {
            let fixture = try RangeFixture(mode: mode)
            defer { fixture.remove() }
            do {
                try await XFetishRangeDownload.download(fixture.request, to: fixture.output, segments: 4,
                                                        configuration: fixture.configuration)
                XCTFail("Expected HTTP refusal")
            } catch XFetishRangeDownload.Failure.http(let response) {
                XCTAssertEqual(response.statusCode, mode == .forbidden ? 403 : 429)
            }
            XCTAssertFalse(fixture.server.ranges.contains("full"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [])
        }
    }

    func testCancellationCancelsSiblingsWithoutFallbackOrPartFile() async throws {
        let fixture = try RangeFixture(mode: .waits)
        defer { fixture.remove() }
        let started = expectation(description: "All 32 ranges started")
        started.expectedFulfillmentCount = 32
        fixture.server.started = { started.fulfill() }
        let task = Task {
            try await XFetishRangeDownload.download(fixture.request, to: fixture.output, segments: 32,
                                                    configuration: fixture.configuration)
        }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(DownloadFailurePolicy.isCancellation(error)) }
        XCTAssertFalse(fixture.server.ranges.contains("full"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [])
    }

    func testFailedRangeCancelsWaitingSiblingsImmediately() async throws {
        let fixture = try RangeFixture(mode: .failsWhileSiblingsWait)
        defer { fixture.remove() }
        let stopped = expectation(description: "Three waiting siblings cancelled")
        stopped.expectedFulfillmentCount = 3
        fixture.server.stopped = { stopped.fulfill() }
        do {
            try await XFetishRangeDownload.download(fixture.request, to: fixture.output, segments: 4,
                                                    configuration: fixture.configuration)
            XCTFail("Expected HTTP 403")
        } catch XFetishRangeDownload.Failure.http(let response) { XCTAssertEqual(response.statusCode, 403) }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertFalse(fixture.server.ranges.contains("full"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [])
    }

    func testRejectsForeignAndInsecureURLs() async throws {
        let fixture = try RangeFixture()
        defer { fixture.remove() }
        for raw in ["http://storage1.x-fetish.tube/a.mp4", "https://evil.example/a.mp4",
                    "https://x-fetish.tube.evil.example/a.mp4", "https://user:secret@x-fetish.tube/a.mp4"] {
            do {
                try await XFetishRangeDownload.download(URLRequest(url: URL(string: raw)!), to: fixture.output,
                    segments: 4, configuration: fixture.configuration)
                XCTFail("Expected invalid URL")
            } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
        XCTAssertTrue(fixture.server.ranges.isEmpty)
    }
}

private final class ByteProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64)] = []
    func record(_ received: Int64, _ total: Int64) {
        lock.lock(); defer { lock.unlock() }
        values.append((received, total))
    }
    var last: (Int64, Int64)? { lock.lock(); defer { lock.unlock() }; return values.last }
}

private struct RangeFixture {
    let directory: URL
    let request: URLRequest
    let server: RangeServer
    var body: Data { server.body }
    var output: URL { directory.appendingPathComponent("video.mp4") }
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        return configuration
    }
    init(mode: RangeServer.Mode = .normal) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        request = URLRequest(url: URL(string: "https://storage1.x-fetish.tube/\(directory.lastPathComponent).mp4")!)
        server = RangeServer(mode: mode)
        RangeProtocol.register(server, for: request.url!)
    }
    func remove() {
        RangeProtocol.unregister(request.url!)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RangeServer: @unchecked Sendable {
    enum Mode { case normal, ignoresRanges, wrongRange, truncated, forbidden, limited, waits, failsWhileSiblingsWait }
    let mode: Mode
    let body = Data((0..<(4 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
    let lock = NSLock()
    private var requested: [String] = []
    private var waiting: [RangeProtocol] = []
    var started: (() -> Void)?
    var stopped: (() -> Void)?
    var ranges: [String] { lock.lock(); defer { lock.unlock() }; return requested }
    init(mode: Mode) { self.mode = mode }
    func reply(to stub: RangeProtocol) {
        let range = stub.request.value(forHTTPHeaderField: "Range")
        lock.lock(); requested.append(range ?? "full"); lock.unlock()
        var code = 200
        var fields = ["Content-Type": "video/mp4", "Content-Length": "\(body.count)"]
        var data = body
        if let range, range != "bytes=0-0", mode == .waits || mode == .failsWhileSiblingsWait {
            lock.lock()
            waiting.append(stub)
            let failed = waiting.count == 4 && mode == .failsWhileSiblingsWait ? waiting.removeFirst() : nil
            lock.unlock()
            started?()
            if let failed {
                let response = HTTPURLResponse(url: failed.request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
                failed.client?.urlProtocol(failed, didReceive: response, cacheStoragePolicy: .notAllowed)
                failed.client?.urlProtocolDidFinishLoading(failed)
            }
            return
        }
        if let range, mode != .ignoresRanges {
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2 else { return }
            let start = bounds[0], end = bounds[1]
            code = 206
            data = body.subdata(in: start..<(end + 1))
            fields["Content-Length"] = "\(data.count)"
            fields["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
            if range != "bytes=0-0" {
                switch mode {
                case .wrongRange: fields["Content-Range"] = "bytes 1-\(end)/\(body.count)"
                case .truncated: data.removeLast()
                case .forbidden: code = 403
                case .limited: code = 429; fields["Retry-After"] = "60"
                default: break
                }
            }
        }
        let response = HTTPURLResponse(url: stub.request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: fields)!
        stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
        stub.client?.urlProtocol(stub, didLoad: data)
        stub.client?.urlProtocolDidFinishLoading(stub)
    }
    func stop(_ stub: RangeProtocol) {
        lock.lock()
        let index = waiting.firstIndex { $0 === stub }
        if let index { waiting.remove(at: index) }
        lock.unlock()
        if index != nil { stopped?() }
    }
}

private final class RangeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [URL: RangeServer] = [:]
    static func register(_ server: RangeServer, for url: URL) { lock.lock(); defer { lock.unlock() }; servers[url] = server }
    static func unregister(_ url: URL) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: url) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = request.url.flatMap { Self.servers[$0] }; Self.lock.unlock()
        if let server { server.reply(to: self) }
        else { client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)) }
    }
    override func stopLoading() {
        Self.lock.lock(); let server = request.url.flatMap { Self.servers[$0] }; Self.lock.unlock()
        server?.stop(self)
    }
}

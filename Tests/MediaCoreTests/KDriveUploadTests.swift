import XCTest
@testable import MediaCore

final class KDriveUploadTests: XCTestCase {
    // MARK: - Seuil direct / session chunkée (comme Orvian-IOS : 95 Mio)

    func testDirectUploadBelow95MiB() {
        XCTAssertFalse(KDriveUploadPolicy.usesChunkedSession(fileSize: 0))
        XCTAssertFalse(KDriveUploadPolicy.usesChunkedSession(fileSize: 95 * 1024 * 1024 - 1))
        XCTAssertFalse(KDriveUploadPolicy.usesChunkedSession(fileSize: KDriveUploadPolicy.directUploadLimit - 1))
    }

    func testChunkedSessionAtAndAbove95MiB() {
        XCTAssertTrue(KDriveUploadPolicy.usesChunkedSession(fileSize: 95 * 1024 * 1024))
        XCTAssertTrue(KDriveUploadPolicy.usesChunkedSession(fileSize: 100_000_000)) // 100 Mo décimaux > 95 Mio
        XCTAssertTrue(KDriveUploadPolicy.usesChunkedSession(fileSize: 753 * 1024 * 1024))
        XCTAssertTrue(KDriveUploadPolicy.usesChunkedSession(fileSize: 1_000_000_000))
    }

    // MARK: - Plan de découpage

    func testChunkPlanUses32MiBChunks() {
        let plan = KDriveUploadPolicy.chunkPlan(fileSize: 271 * 1024 * 1024)
        XCTAssertEqual(plan.chunkSize, 32 * 1024 * 1024)
        XCTAssertEqual(plan.totalChunks, 9) // 271 / 32 = 8.47 -> 9
    }

    func testChunkPlanExactMultipleAndSingleChunk() {
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 32 * 1024 * 1024).totalChunks, 1)
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 64 * 1024 * 1024).totalChunks, 2)
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 32 * 1024 * 1024 + 1).totalChunks, 2)
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 1).totalChunks, 1)
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 0).totalChunks, 1)
    }

    func testChunkPlanStaysUnder10000ChunksForHugeFiles() {
        let oneTiB: Int64 = 1_099_511_627_776
        let plan = KDriveUploadPolicy.chunkPlan(fileSize: oneTiB)
        XCTAssertLessThanOrEqual(plan.totalChunks, 10_000)
        XCTAssertGreaterThanOrEqual(plan.chunkSize, oneTiB / 10_000)
        XCTAssertLessThanOrEqual(plan.chunkSize, KDriveUploadPolicy.maxChunkRequestSize)
    }

    // MARK: - Hôtes d'upload de confiance

    func testTrustedUploadHosts() {
        XCTAssertTrue(KDriveUploadURL.isTrustedUploadHost("api.infomaniak.com"))
        XCTAssertTrue(KDriveUploadURL.isTrustedUploadHost("upload.kdrive.infomaniak.com"))
        XCTAssertTrue(KDriveUploadURL.isTrustedUploadHost("up123.upload.kdrive.infomaniak.com"))
        XCTAssertTrue(KDriveUploadURL.isTrustedUploadHost("UPLOAD.KDRIVE.INFOMANIAK.COM")) // casse normalisée
        XCTAssertFalse(KDriveUploadURL.isTrustedUploadHost("evil.com"))
        XCTAssertFalse(KDriveUploadURL.isTrustedUploadHost("upload.kdrive.infomaniak.com.evil.com"))
        XCTAssertFalse(KDriveUploadURL.isTrustedUploadHost("kdrive.infomaniak.com"))
        XCTAssertFalse(KDriveUploadURL.isTrustedUploadHost(nil))
        XCTAssertFalse(KDriveUploadURL.isTrustedUploadHost(""))
    }

    func testTrustedUploadURLRequiresHTTPS() {
        XCTAssertTrue(KDriveUploadURL.isTrustedUploadURL(URL(string: "https://upload.kdrive.infomaniak.com")!))
        XCTAssertFalse(KDriveUploadURL.isTrustedUploadURL(URL(string: "http://upload.kdrive.infomaniak.com")!))
        XCTAssertFalse(KDriveUploadURL.isTrustedUploadURL(URL(string: "https://evil.com")!))
    }

    // MARK: - URL de chunk

    func testChunkURLSwapsHostAndPreservesQuery() {
        let uploadURL = URL(string: "https://up123.upload.kdrive.infomaniak.com/?foo=bar&chunk_number=99")!
        let url = KDriveUploadURL.chunkURL(
            uploadURL: uploadURL, driveId: "42", sessionToken: "tok",
            chunkNumber: 3, chunkSize: 33_554_432, chunkHash: "abcd"
        )!
        XCTAssertEqual(url.host, "up123.upload.kdrive.infomaniak.com")
        XCTAssertEqual(url.path, "/3/drive/42/upload/session/tok/chunk")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains { $0.name == "foo" && $0.value == "bar" })
        XCTAssertTrue(items.contains { $0.name == "chunk_number" && $0.value == "3" })
        XCTAssertTrue(items.contains { $0.name == "chunk_size" && $0.value == "33554432" })
        XCTAssertTrue(items.contains { $0.name == "chunk_hash" && $0.value == "sha256:abcd" })
        // L'ancien chunk_number de l'upload_url ne doit pas survivre.
        XCTAssertEqual(items.filter { $0.name == "chunk_number" }.count, 1)
    }

    func testChunkURLWithoutHashOmitsChunkHash() {
        let url = KDriveUploadURL.chunkURL(
            uploadURL: nil, driveId: "1", sessionToken: "t",
            chunkNumber: 1, chunkSize: 10, chunkHash: nil
        )!
        XCTAssertEqual(url.host, "api.infomaniak.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(items.contains { $0.name == "chunk_hash" })
    }

    func testChunkURLRejectsUntrustedUploadURL() {
        let evil = URL(string: "https://evil.com/steal")!
        XCTAssertNil(KDriveUploadURL.chunkURL(
            uploadURL: evil, driveId: "1", sessionToken: "t",
            chunkNumber: 1, chunkSize: 10, chunkHash: nil
        ))
    }

    // MARK: - Réponse de chunk

    private func chunkJSON(_ body: String) -> Data { Data(body.utf8) }

    func testChunkReplyAcceptedWhenStatusOk() {
        let ok = chunkJSON(#"{"result":"success","data":{"status":"ok","number":3,"size":33554432}}"#)
        XCTAssertTrue(KDriveChunkReply.isAccepted(data: ok, chunkNumber: 3, chunkSize: 33_554_432))
    }

    func testChunkReplyAcceptedWhenResultAbsent() {
        let ok = chunkJSON(#"{"data":{"status":"ok"}}"#)
        XCTAssertTrue(KDriveChunkReply.isAccepted(data: ok, chunkNumber: 1, chunkSize: 10))
    }

    func testChunkReplyRejectedOnErrorResultOrNonOkStatus() {
        XCTAssertFalse(KDriveChunkReply.isAccepted(data: chunkJSON(#"{"result":"error","data":{"status":"ok"}}"#), chunkNumber: 1, chunkSize: 10))
        XCTAssertFalse(KDriveChunkReply.isAccepted(data: chunkJSON(#"{"result":"success","data":{"status":"uploading"}}"#), chunkNumber: 1, chunkSize: 10))
        XCTAssertFalse(KDriveChunkReply.isAccepted(data: chunkJSON(#"{"result":"success"}"#), chunkNumber: 1, chunkSize: 10))
        XCTAssertFalse(KDriveChunkReply.isAccepted(data: Data("not json".utf8), chunkNumber: 1, chunkSize: 10))
    }

    func testChunkReplyRejectedOnNumberOrSizeMismatch() {
        let wrongNumber = chunkJSON(#"{"result":"success","data":{"status":"ok","number":2,"size":10}}"#)
        XCTAssertFalse(KDriveChunkReply.isAccepted(data: wrongNumber, chunkNumber: 1, chunkSize: 10))
        let wrongSize = chunkJSON(#"{"result":"success","data":{"status":"ok","number":1,"size":99}}"#)
        XCTAssertFalse(KDriveChunkReply.isAccepted(data: wrongSize, chunkNumber: 1, chunkSize: 10))
    }

    // MARK: - Pacer à fenêtre glissante

    func testPacerAllowsUpToLimitThenWaits() {
        var pacer = SlidingWindowPacer(limit: 50, window: 60)
        let now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<50 {
            XCTAssertEqual(pacer.reserveSlot(now: now), 0)
        }
        let wait = pacer.reserveSlot(now: now)
        XCTAssertGreaterThan(wait, 0)
        XCTAssertLessThanOrEqual(wait, 60)
        XCTAssertEqual(pacer.count(at: now), 51)
    }

    func testPacerSlidesAfterWindow() {
        var pacer = SlidingWindowPacer(limit: 2, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(pacer.reserveSlot(now: t0), 0)
        XCTAssertEqual(pacer.reserveSlot(now: t0), 0)
        XCTAssertGreaterThan(pacer.reserveSlot(now: t0), 0)
        // 61 s plus tard, la fenêtre est libérée.
        XCTAssertEqual(pacer.reserveSlot(now: t0.addingTimeInterval(61)), 0)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(61)), 1)
    }

    func testPacerOldestInWindow() {
        var pacer = SlidingWindowPacer(limit: 10, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(pacer.oldest(at: t0))
        pacer.reserveSlot(now: t0)
        pacer.reserveSlot(now: t0.addingTimeInterval(5))
        XCTAssertEqual(pacer.oldest(at: t0.addingTimeInterval(5)), t0)
        // à t0+61 la fenêtre couvre ]t0+1, t0+61] : t0+5 est encore dedans
        XCTAssertEqual(pacer.oldest(at: t0.addingTimeInterval(61)), t0.addingTimeInterval(5))
        XCTAssertNil(pacer.oldest(at: t0.addingTimeInterval(66)))
    }
}

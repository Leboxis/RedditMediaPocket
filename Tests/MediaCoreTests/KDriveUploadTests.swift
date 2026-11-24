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

    func testChunkPlanUses250MBChunks() {
        let plan = KDriveUploadPolicy.chunkPlan(fileSize: 271 * 1024 * 1024)
        XCTAssertEqual(plan.chunkSize, 250_000_000)
        XCTAssertEqual(plan.totalChunks, 2) // 271 Mio / 250 Mo = 1.14 -> 2
    }

    func testChunkPlanExactMultipleAndSingleChunk() {
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 250_000_000).totalChunks, 1)
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 2 * 250_000_000).totalChunks, 2)
        XCTAssertEqual(KDriveUploadPolicy.chunkPlan(fileSize: 250_000_000 + 1).totalChunks, 2)
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

    func testPacerSpacesRequestsInsteadOfBursting() {
        var pacer = SlidingWindowPacer(limit: 50, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(pacer.reserveSlot(now: t0), 0)
        // Plus de rafale : la 2e requête attend l'espacement régulier.
        let wait = pacer.reserveSlot(now: t0)
        XCTAssertEqual(wait, pacer.spacing, accuracy: 0.001)
        // Une tentative bloquée ne consomme pas de créneau.
        XCTAssertEqual(pacer.count(at: t0), 1)
        // À l'espacement exact, la requête part.
        XCTAssertEqual(pacer.reserveSlot(now: t0.addingTimeInterval(pacer.spacing)), 0)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(pacer.spacing)), 2)
    }

    func testPacerNeverExceedsLimitInWindow() {
        var pacer = SlidingWindowPacer(limit: 3, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(pacer.reserveSlot(now: t0), 0)
        XCTAssertEqual(pacer.reserveSlot(now: t0.addingTimeInterval(30)), 0)
        // Fenêtre saturée (3 max) : la suivante attend, sans consommer.
        XCTAssertGreaterThan(pacer.reserveSlot(now: t0.addingTimeInterval(30.5)), 0)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(30.5)), 2)
        XCTAssertEqual(pacer.reserveSlot(now: t0.addingTimeInterval(61)), 0)
        XCTAssertEqual(pacer.reserveSlot(now: t0.addingTimeInterval(91.5)), 0)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(91.5)), 2)
        XCTAssertGreaterThan(pacer.reserveSlot(now: t0.addingTimeInterval(91.5)), 0)
    }

    func testPacerNextSlotWaitDoesNotConsume() {
        var pacer = SlidingWindowPacer(limit: 56, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(pacer.nextSlotWait(now: t0), 0)
        pacer.reserveSlot(now: t0)
        XCTAssertEqual(pacer.nextSlotWait(now: t0), pacer.spacing, accuracy: 0.001)
        XCTAssertEqual(pacer.nextSlotWait(now: t0.addingTimeInterval(pacer.spacing)), 0)
        XCTAssertEqual(pacer.count(at: t0), 1)
    }

    func testPacerSlidesAfterWindow() {
        var pacer = SlidingWindowPacer(limit: 2, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(pacer.reserveSlot(now: t0), 0)
        // Après vidage de la fenêtre, le premier départ est immédiat.
        XCTAssertEqual(pacer.reserveSlot(now: t0.addingTimeInterval(61)), 0)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(61)), 1)
    }

    func testPacerOldestInWindow() {
        var pacer = SlidingWindowPacer(limit: 10, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(pacer.oldest(at: t0))
        pacer.reserveSlot(now: t0)
        pacer.reserveSlot(now: t0.addingTimeInterval(7))
        XCTAssertEqual(pacer.oldest(at: t0.addingTimeInterval(7)), t0)
        // à t0+61 la fenêtre couvre ]t0+1, t0+61] : t0+7 est encore dedans
        XCTAssertEqual(pacer.oldest(at: t0.addingTimeInterval(61)), t0.addingTimeInterval(7))
        XCTAssertNil(pacer.oldest(at: t0.addingTimeInterval(68)))
    }

    func testPacerRecordAppendsWithoutBlocking() {
        var pacer = SlidingWindowPacer(limit: 2, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        pacer.record(now: t0)
        pacer.record(now: t0)
        pacer.record(now: t0)
        XCTAssertEqual(pacer.count(at: t0), 3)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(61)), 0)
    }

    func testUploadConcurrencyOptionsAndClamping() {
        XCTAssertEqual(KDriveUploadPolicy.uploadConcurrencyOptions, [4, 6, 8, 10])
        for option in KDriveUploadPolicy.uploadConcurrencyOptions {
            XCTAssertEqual(KDriveUploadPolicy.clampedConcurrentUploads(option), option)
        }
        XCTAssertEqual(KDriveUploadPolicy.clampedConcurrentUploads(0), 4)
        XCTAssertEqual(KDriveUploadPolicy.clampedConcurrentUploads(5), 4)
        XCTAssertEqual(KDriveUploadPolicy.clampedConcurrentUploads(12), 4)
    }

    // MARK: - Plafond de cadence réglable

    func testPacingLimitConstantsAndClamping() {
        XCTAssertEqual(KDriveUploadPolicy.minPacingLimitPerMinute, 60)
        XCTAssertEqual(KDriveUploadPolicy.defaultPacingLimitPerMinute, 60)
        XCTAssertEqual(KDriveUploadPolicy.maxPacingLimitPerMinute, 600)

        for value in stride(from: KDriveUploadPolicy.minPacingLimitPerMinute, through: KDriveUploadPolicy.maxPacingLimitPerMinute, by: 10) {
            XCTAssertEqual(KDriveUploadPolicy.clampedPacingLimit(value), value)
        }
        XCTAssertEqual(KDriveUploadPolicy.clampedPacingLimit(0), 60)
        XCTAssertEqual(KDriveUploadPolicy.clampedPacingLimit(59), 60)
        XCTAssertEqual(KDriveUploadPolicy.clampedPacingLimit(-50), 60)
        XCTAssertEqual(KDriveUploadPolicy.clampedPacingLimit(601), 600)
        XCTAssertEqual(KDriveUploadPolicy.clampedPacingLimit(1_000), 600)
    }

    func testPacerUpdateLimitUpdatesSpacingImmediately() {
        var pacer = SlidingWindowPacer(limit: 58, window: 60)
        XCTAssertEqual(pacer.limit, 58)
        XCTAssertEqual(pacer.spacing, 60.0 / 57.0, accuracy: 0.001)

        pacer.updateLimit(30)
        XCTAssertEqual(pacer.limit, 30)
        XCTAssertEqual(pacer.spacing, 60.0 / 29.0, accuracy: 0.001)
        XCTAssertEqual(pacer.window, 60)
    }

    func testPacerUpdateLimitRelaxesSpacingWithoutLosingWindow() {
        var pacer = SlidingWindowPacer(limit: 3, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(pacer.reserveSlot(now: t0), 0)
        XCTAssertEqual(pacer.reserveSlot(now: t0.addingTimeInterval(30)), 0)
        // Espacement de 30 s (3 req/min) : la 3e requête attend.
        XCTAssertEqual(pacer.nextSlotWait(now: t0.addingTimeInterval(30.5)), 29.5, accuracy: 0.001)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(30.5)), 2)

        // Plafond relevé à 6 : l'espacement tombe à 12 s, les requêtes déjà
        // enregistrées restent comptées dans la fenêtre.
        pacer.updateLimit(6)
        XCTAssertEqual(pacer.limit, 6)
        XCTAssertEqual(pacer.spacing, 12, accuracy: 0.001)
        XCTAssertEqual(pacer.nextSlotWait(now: t0.addingTimeInterval(30.5)), 11.5, accuracy: 0.001)
        XCTAssertEqual(pacer.count(at: t0.addingTimeInterval(30.5)), 2)
    }

    func testPacerUpdateLimitClampsToAtLeastOne() {
        var pacer = SlidingWindowPacer(limit: 58, window: 60)
        pacer.updateLimit(0)
        XCTAssertEqual(pacer.limit, 1)
        XCTAssertEqual(pacer.spacing, 60, accuracy: 0.001)
        pacer.updateLimit(-3)
        XCTAssertEqual(pacer.limit, 1)
    }
}

import XCTest
@testable import MediaCore

/// Banc d'essai du parcours X : chaque configuration tourne 30 s sur un
/// réseau simulé — latence GraphQL par page, lien partagé de 12 Mo/s plafonné
/// par connexion à 3 Mo/s, égouttements (transfert sans octet pendant 20 s) —
/// et mesure le débit moyen des médias terminés dans la fenêtre.
///
/// Hors CI : le test est sauté sauf si `RUN_BENCH=1`.
/// `RUN_BENCH=1 swift test --filter PipelineBenchmarkTests`
final class PipelineBenchmarkTests: XCTestCase {
    /// Débit du lien simulé, partagé entre toutes les connexions actives.
    static let linkBandwidthMBps = 12.0
    /// Plafond de débit d'une connexion TCP (fenêtre, RTT mobile).
    static let perConnectionMBps = 3.0
    /// Latence d'établissement d'une connexion média.
    static let connectLatency = 0.15
    /// Latence d'un aller-retour GraphQL (page du fil `/media`).
    static let pageLatency = 0.30
    /// Surcoût de la relecture des cookies WebKit à chaque page, supprimé
    /// par le cache CSRF.
    static let csrfReadCost = 0.05
    /// Sans octet pendant ce délai, le watchdog annule et retente.
    static let stallDetection = 20.0
    /// Fenêtre de mesure de chaque configuration.
    static let window: TimeInterval = 30

    struct SimMedia: Sendable {
        let sizeMB: Double
        let stalls: Bool
    }

    /// Lien partagé : plus il y a de connexions actives, moins chacune en
    /// reçoit (plafonné au débit par connexion).
    actor Link {
        var active = 0

        func transfer(_ media: SimMedia, stallHold: Double?) async -> Double {
            active += 1
            defer { active -= 1 }
            let share = max(1.0, PipelineBenchmarkTests.linkBandwidthMBps / Double(active))
            let effective = min(PipelineBenchmarkTests.perConnectionMBps, share)
            if media.stalls, let hold = stallHold {
                // Égouttement : aucun octet pendant `hold`, puis le transfert
                // reprend normalement (watchdog : annulation + relance).
                try? await Task.sleep(for: .seconds(hold))
            } else if media.stalls {
                // Sans watchdog : le filet des 10 minutes ne tombe jamais
                // dans la fenêtre, le créneau reste occupé.
                try? await Task.sleep(for: .seconds(3600))
            } else {
                try? await Task.sleep(for: .seconds(PipelineBenchmarkTests.connectLatency + media.sizeMB / effective))
            }
            // Un transfert interrompu par la fin de la fenêtre ne compte pas :
            // ses octets n'ont pas été reçus.
            if Task.isCancelled { return 0 }
            return media.sizeMB
        }
    }

    actor Ledger {
        var bytes = 0.0
        var items = 0

        func add(_ sizeMB: Double) {
            bytes += sizeMB
            items += 1
        }
    }

    /// Profil type d'un compte X : 1 média par post, un post sur cinq en a
    /// deux ; 60 % d'images (2 Mo), 30 % de vidéos (8 Mo), 10 % de GIF (4 Mo).
    /// Un média sur quinze s'égoutte.
    nonisolated static func makeMedia(_ index: Int, videoScale: Double) -> SimMedia {
        var size: Double
        switch index % 10 {
        case 0...5: size = 2
        case 6...8: size = 8 * videoScale
        default: size = 4
        }
        if index % 5 == 0 { size *= 2 }
        return SimMedia(sizeMB: size, stalls: index % 15 == 7)
    }

    /// Ancien parcours : lots discrets. Le producteur lit les pages et remplit
    /// un lot ; dès que le lot atteint `limit`, il attend la fin complète du
    /// lot précédent avant d'en lancer un nouveau.
    func runBatchPipeline(limit: Int, postsPerPage: Int, pageLatency: Double,
                          stallHold: Double?, videoScale: Double) async -> (bytes: Double, items: Int) {
        let link = Link()
        let ledger = Ledger()
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var pending: [SimMedia] = []
            var batchTask: Task<Void, Never>?
        }
        let box = Box()
        let window = Self.window
        let runTask = Task {
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pageLatency))
                if Task.isCancelled { break }
                for _ in 0..<postsPerPage {
                    let mediaCount = index % 5 == 0 ? 2 : 1
                    for _ in 0..<mediaCount {
                        box.lock.lock()
                        box.pending.append(PipelineBenchmarkTests.makeMedia(index, videoScale: videoScale))
                        guard box.pending.count >= limit else {
                            box.lock.unlock()
                            index += 1
                            continue
                        }
                        let previous = box.batchTask
                        let batch = box.pending
                        box.pending = []
                        box.lock.unlock()
                        await previous?.value
                        let link = link
                        box.batchTask = Task {
                            try? await ConcurrentDownloads.run(batch, limit: limit) { media in
                                let size = await link.transfer(media, stallHold: stallHold)
                                await ledger.add(size)
                            }
                        }
                        index += 1
                    }
                }
            }
        }
        try? await Task.sleep(for: .seconds(window))
        runTask.cancel()
        box.lock.lock()
        box.batchTask?.cancel()
        box.lock.unlock()
        let bytes = await ledger.bytes
        let items = await ledger.items
        return (bytes, items)
    }

    /// Nouveau parcours : canal continu. Les médias préparés rejoignent le
    /// canal, `limit` consommateurs le vident sans arrêt ; la pagination ne
    /// s'interrompt jamais.
    func runChannelPipeline(limit: Int, postsPerPage: Int, pageLatency: Double,
                            stallHold: Double?, videoScale: Double) async -> (bytes: Double, items: Int) {
        let link = Link()
        let ledger = Ledger()
        let channel = ConcurrentChannel<SimMedia>()
        let window = Self.window
        let workers = (0..<limit).map { _ in
            Task {
                while let media = await channel.next() {
                    let size = await link.transfer(media, stallHold: stallHold)
                    await ledger.add(size)
                }
            }
        }
        let runTask = Task {
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pageLatency))
                if Task.isCancelled { break }
                for _ in 0..<postsPerPage {
                    let mediaCount = index % 5 == 0 ? 2 : 1
                    for _ in 0..<mediaCount {
                        channel.send(PipelineBenchmarkTests.makeMedia(index, videoScale: videoScale))
                        index += 1
                    }
                }
            }
        }
        try? await Task.sleep(for: .seconds(window))
        runTask.cancel()
        channel.finish()
        for worker in workers { worker.cancel() }
        for worker in workers { await worker.value }
        let bytes = await ledger.bytes
        let items = await ledger.items
        return (bytes, items)
    }

    func testPipelineBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["RUN_BENCH"] == "1" else {
            throw XCTSkip("Banc d'essai long : lancer avec RUN_BENCH=1")
        }
        var results: [(String, Double, Int)] = []
        func measure(_ label: String, _ run: () async -> (bytes: Double, items: Int)) async {
            let (bytes, items) = await run()
            let mbps = bytes / Self.window
            results.append((label, mbps, items))
            let mbpsText = String((mbps * 100).rounded() / 100)
            print("BENCH \(label.padding(toLength: 42, withPad: " ", startingAt: 0)) \(mbpsText) Mo/s (\(items) médias)")
        }

        // 0. Référence : lots discrets, 3 transferts, pages de 40, égouttements
        // non détectés, relecture CSRF à chaque page.
        await measure("0 reference (lots, 3, 40/page)") {
            await runBatchPipeline(limit: 3, postsPerPage: 40,
                                   pageLatency: Self.pageLatency + Self.csrfReadCost,
                                   stallHold: nil, videoScale: 1.0)
        }
        // 1. + pipeline continu (lots supprimés).
        await measure("1 + pipeline continu (3, 40/page)") {
            await runChannelPipeline(limit: 3, postsPerPage: 40,
                                     pageLatency: Self.pageLatency + Self.csrfReadCost,
                                     stallHold: nil, videoScale: 1.0)
        }
        // 2. + concurrence 6 (nouveau défaut).
        await measure("2 + concurrence 6") {
            await runChannelPipeline(limit: 6, postsPerPage: 40,
                                     pageLatency: Self.pageLatency + Self.csrfReadCost,
                                     stallHold: nil, videoScale: 1.0)
        }
        // 3. + concurrence 12 (nouveau plafond).
        await measure("3 + concurrence 12") {
            await runChannelPipeline(limit: 12, postsPerPage: 40,
                                     pageLatency: Self.pageLatency + Self.csrfReadCost,
                                     stallHold: nil, videoScale: 1.0)
        }
        // 4. + pages de 100 (moins d'allers-retours GraphQL).
        await measure("4 + pages de 100") {
            await runChannelPipeline(limit: 6, postsPerPage: 100,
                                     pageLatency: Self.pageLatency + Self.csrfReadCost,
                                     stallHold: nil, videoScale: 1.0)
        }
        // 5. + watchdog : égouttement détecté après 20 s, transfert repris.
        await measure("5 + watchdog anti-stall") {
            await runChannelPipeline(limit: 6, postsPerPage: 100,
                                     pageLatency: Self.pageLatency + Self.csrfReadCost,
                                     stallHold: Self.stallDetection, videoScale: 1.0)
        }
        // 6. + cache CSRF : latence de page sans la relecture des cookies.
        await measure("6 + cache CSRF") {
            await runChannelPipeline(limit: 6, postsPerPage: 100,
                                     pageLatency: Self.pageLatency,
                                     stallHold: Self.stallDetection, videoScale: 1.0)
        }
        // 7. + vidéos bitrate réduit (60 %) : plus rapide, qualité perdue.
        await measure("7 + videos bitrate reduit (60 %)") {
            await runChannelPipeline(limit: 6, postsPerPage: 100,
                                     pageLatency: Self.pageLatency,
                                     stallHold: Self.stallDetection, videoScale: 0.6)
        }

        print("\nBENCH TABLE — débit de référence : \(results[0].1) Mo/s")
        print("BENCH TABLE — débit final : \(results[results.count - 1].1) Mo/s")
    }
}

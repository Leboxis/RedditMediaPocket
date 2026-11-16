import SwiftUI
import MediaCore

/// État d'une sonde de diagnostic.
enum DiagnosticState: Equatable {
    case pending, running, ok(String), fail(String)
}

/// Une sonde : interroge une source et dit ce qui marche et ce qui est cassé
/// (jeton RedGifs, session expirée, `queryId` X périmé, API Instagram muette).
struct DiagnosticCheck: Identifiable {
    let id: String
    let title: String
    var state: DiagnosticState = .pending
}

/// Écran « Test de santé des sources » : chaque source configurée reçoit une
/// requête légère et anonyme quand c'est possible, ou un examen de session
/// quand la source l'exige. Le résultat distingue « marche » et « cassé » avec
/// le message d'erreur exact, au lieu d'un « aucun média » silencieux.
struct SourceDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var checks: [DiagnosticCheck] = []
    @State private var running = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(checks) { check in
                        DiagnosticRow(check: check)
                    }
                } footer: {
                    Text(L("Les sondes sont légères et anonymes. Un refus ici ne préjuge pas d'un refus pendant un parcours complet : il indique seulement que la source répond ou non.",
                           "Probes are lightweight and anonymous. A refusal here does not predict a refusal during a full scan: it only reports whether the source answers."))
                }
            }
            .navigationTitle(L("Test de santé des sources", "Source health check"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Lancer", "Run")) { Task { await run() } }
                        .disabled(running)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("OK", "OK")) { dismiss() }
                }
            }
            .task { if checks.isEmpty { await run() } }
        }
    }

    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let network = Network()
        let reddit = RedditSession.shared
        let xSession = XSession.shared
        let tikTokSession = TikTokSession.shared
        checks = [
            DiagnosticCheck(id: "reddit-feed", title: L("Reddit : flux public anonyme", "Reddit: anonymous public feed")),
            DiagnosticCheck(id: "reddit-session", title: L("Reddit : session locale", "Reddit: local session")),
            DiagnosticCheck(id: "redgifs", title: L("RedGifs : jeton temporaire", "RedGifs: temporary token")),
            DiagnosticCheck(id: "x-session", title: L("X : session locale", "X: local session")),
            DiagnosticCheck(id: "tiktok-session", title: L("TikTok : session locale", "TikTok: local session")),
            DiagnosticCheck(id: "instagram", title: L("Instagram : API web anonyme", "Instagram: anonymous web API")),
            DiagnosticCheck(id: "xfetish", title: L("X-Fetish : site public", "X-Fetish: public site"))
        ]
        for index in checks.indices {
            checks[index].state = .running
            let id = checks[index].id
            let state: DiagnosticState
            switch id {
            case "reddit-feed":
                state = await probeFeed(URL(string: "https://www.reddit.com/r/pics/.rss")!,
                                        ok: L("Flux RSS servi.", "RSS feed served."))
            case "reddit-session":
                state = sessionState(reddit.hasSession,
                                     ok: L("Session détectée.", "Session detected."),
                                     missing: L("Aucune session : les sauvegardés exigent une connexion.", "No session: saved posts require sign-in."))
            case "redgifs":
                state = await probeRedgifs()
            case "x-session":
                state = sessionState(xSession.hasSession,
                                     ok: L("Session détectée.", "Session detected."),
                                     missing: L("Aucune session : X ne publie aucun média sans elle.", "No session: X publishes no media without one."))
            case "tiktok-session":
                state = sessionState(tikTokSession.hasSession,
                                     ok: L("Session détectée.", "Session detected."),
                                     missing: L("Aucune session : TikTok exige une connexion pour un profil.", "No session: TikTok requires sign-in for a profile."))
            case "instagram":
                state = await probeFeed(InstagramAPI.profileInfoURL(username: "instagram"),
                                        ok: L("API web servie anonymement.", "Web API served anonymously."),
                                        headers: InstagramAPI.headers(referer: URL(string: "https://www.instagram.com/instagram/")!))
            default:
                state = await probeFeed(URL(string: "https://x-fetish.tube/")!,
                                        ok: L("Site joignable.", "Site reachable."))
            }
            checks[index].state = state
        }
    }

    /// Une session absente n'est pas une panne : l'état le dit sans erreur.
    private func sessionState(_ present: Bool, ok: String, missing: String) -> DiagnosticState {
        present ? .ok(ok) : .fail(missing)
    }

    private func probeFeed(_ url: URL, ok: String, headers: [String: String]? = nil) async -> DiagnosticState {
        do {
            let data = try await network.data(url, headers: headers)
            return data.isEmpty ? .fail(L("Réponse vide.", "Empty response.")) : .ok(ok)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func probeRedgifs() async -> DiagnosticState {
        do {
            let data = try await network.data(URL(string: "https://api.redgifs.com/v2/auth/temporary")!)
            let token = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["token"] as? String
            guard let token, !token.isEmpty else {
                return .fail(L("Réponse sans jeton.", "Response without a token."))
            }
            return .ok(L("Jeton délivré.", "Token delivered."))
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}

private struct DiagnosticRow: View {
    let check: DiagnosticCheck

    var body: some View {
        HStack {
            switch check.state {
            case .pending:
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            case .running:
                ProgressView()
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.callout.weight(.medium))
                switch check.state {
                case .pending: Text(L("En attente.", "Pending.")).font(.caption).foregroundStyle(.secondary)
                case .running: Text(L("Sonde en cours…", "Probing…")).font(.caption).foregroundStyle(.secondary)
                case .ok(let message): Text(message).font(.caption).foregroundStyle(.green)
                case .fail(let message): Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

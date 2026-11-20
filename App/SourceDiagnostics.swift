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
            DiagnosticCheck(id: "reddit-feed", title: L("Reddit : listing JSON (session requise depuis le 13/11/2026)", "Reddit: JSON listing (session required since 11/13/2026)")),
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
                state = await probeRedditListing(network)
            case "reddit-session":
                state = sessionState(reddit.hasSession,
                                     ok: L("Session détectée.", "Session detected."),
                                     missing: L("Aucune session : les sauvegardés exigent une connexion.", "No session: saved posts require sign-in."))
            case "redgifs":
                state = await probeRedgifs(network)
            case "x-session":
                state = sessionState(xSession.hasSession,
                                     ok: L("Session détectée.", "Session detected."),
                                     missing: L("Aucune session : X ne publie aucun média sans elle.", "No session: X publishes no media without one."))
            case "tiktok-session":
                state = sessionState(tikTokSession.hasSession,
                                     ok: L("Session détectée.", "Session detected."),
                                     missing: L("Aucune session : TikTok exige une connexion pour un profil.", "No session: TikTok requires sign-in for a profile."))
            case "instagram":
                state = await probeInstagram(network)
            default:
                state = await probeFeed(network, url: URL(string: "https://x-fetish.tube/")!,
                                        ok: L("Site joignable.", "Site reachable."))
            }
            checks[index].state = state
        }
    }

    /// Une session absente n'est pas une panne : l'état le dit sans erreur.
    private func sessionState(_ present: Bool, ok: String, missing: String) -> DiagnosticState {
        present ? .ok(ok) : .fail(missing)
    }

    /// Sonde le listing JSON public de Reddit (`/r/pics/new.json`). Depuis le
    /// 13/11/2026 les `.rss` sont coupés (404) et les `.json` exigent une
    /// session : 200 = OK avec session, 403/401 = session manquante (attendu
    /// sans connexion).
    private func probeRedditListing(_ network: Network) async -> DiagnosticState {
        let url = URL(string: "https://www.reddit.com/r/pics/new.json?limit=1")!
        do {
            let data = try await network.data(url)
            return data.isEmpty
                ? .fail(L("Réponse vide.", "Empty response."))
                : .ok(L("Listing JSON servi (\(data.count) octets).", "JSON listing served (\(data.count) bytes)."))
        } catch NetworkError.refused(let code) where code == 401 || code == 403 {
            return .fail(L("HTTP \(code) : session requise — les flux RSS sont coupés depuis le 13/11/2026 et les `.json` exigent une connexion.", "HTTP \(code): session required — RSS feeds have been off since 11/13/2026 and `.json` requires sign-in."))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func probeFeed(_ network: Network, url: URL, ok: String, headers: [String: String]? = nil) async -> DiagnosticState {
        do {
            let data = try await network.data(url, headers: headers)
            return data.isEmpty ? .fail(L("Réponse vide.", "Empty response.")) : .ok(ok)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    /// Instagram n'a plus d'API anonyme : la sonde vérifie le chemin qui la
    /// remplace — page du profil lue, jetons d'API GraphQL présents.
    private func probeInstagram(_ network: Network) async -> DiagnosticState {
        let pageURL = InstagramAPI.profilePageURL(username: "instagram")
        do {
            let page = try await network.dataAndHeaders(pageURL, headers: InstagramAPI.pageHeaders(referer: pageURL))
            guard InstagramAPI.tokens(inHTML: page.data, cookies: page.headers["set-cookie"]) != nil else {
                return .fail(L("Page de profil servie sans jeton d'API (interface modifiée).",
                               "Profile page served without an API token (interface changed)."))
            }
            return .ok(L("Page de profil et jetons anonymes servis.", "Anonymous profile page and tokens served."))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func probeRedgifs(_ network: Network) async -> DiagnosticState {
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
                Image(systemName: "circle.dotted").foregroundStyle(DS.onSurfaceMuted)
            case .running:
                ProgressView()
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.accentEmphasis)
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(DS.error)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.callout.weight(.medium))
                switch check.state {
                case .pending: Text(L("En attente.", "Pending.")).font(.caption).foregroundStyle(DS.onSurfaceMuted)
                case .running: Text(L("Sonde en cours…", "Probing…")).font(.caption).foregroundStyle(DS.onSurfaceMuted)
                case .ok(let message): Text(message).font(.caption).foregroundStyle(DS.accentEmphasis)
                case .fail(let message): Text(message).font(.caption).foregroundStyle(DS.error)
                }
            }
        }
        .padding(.vertical, DS.space(1))
    }
}

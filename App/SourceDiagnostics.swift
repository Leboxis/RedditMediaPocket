import SwiftUI
import MediaCore

/// État d'une sonde de diagnostic.
enum DiagnosticState: Equatable {
    case pending, running, ok(String), unconfigured(String), fail(String)
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
        .tint(DS.accentEmphasis)
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
            DiagnosticCheck(id: "reddit-feed", title: L("Reddit : listing r/ (JSON ou repli HTML)", "Reddit: r/ listing (JSON or HTML fallback)")),
            DiagnosticCheck(id: "reddit-session", title: L("Reddit : session locale", "Reddit: local session")),
            DiagnosticCheck(id: "redgifs", title: L("RedGifs : jeton temporaire", "RedGifs: temporary token")),
            DiagnosticCheck(id: "x-session", title: L("X : session locale", "X: local session")),
            DiagnosticCheck(id: "tiktok-session", title: L("TikTok : session locale", "TikTok: local session")),
            DiagnosticCheck(id: "instagram", title: L("Instagram : page de profil et API web", "Instagram: profile page & web API")),
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
        present ? .ok(ok) : .unconfigured(missing)
    }

    /// Suit exactement le chemin d'un téléchargement `r/` : le listing JSON
    /// d'abord, puis — sur 401/403 — le listing HTML de `old.reddit.com` qu'utilise
    /// `Downloader.fetchPosts`. Reddit refuse le `.json` des subreddits (403 même
    /// avec session), mais la page HTML reste servie : tester seulement le JSON
    /// afficherait donc une panne là où les téléchargements passent.
    private func probeRedditListing(_ network: Network) async -> DiagnosticState {
        let jsonURL = FeedSource.subreddit("pics").feedURL(sort: "new")
        do {
            let data = try await network.data(jsonURL)
            let posts = try RedditListing.parse(data)
            return posts.isEmpty
                ? .fail(L("Listing JSON vide : aucun post reconnu.", "JSON listing empty: no post recognized."))
                : .ok(L("Listing JSON servi (\(posts.count) posts).", "JSON listing served (\(posts.count) posts)."))
        } catch NetworkError.refused(let code) where code == 401 || code == 403 {
            let htmlURL = RedditHTMLListing.url(subreddit: "pics", sort: "new", after: nil)
            do {
                let html = try await network.data(htmlURL)
                let posts = try RedditHTMLListing.parse(html)
                guard !posts.isEmpty else {
                    return .fail(L("JSON HTTP \(code) et listing HTML vide : aucun post reconnu.",
                                   "JSON HTTP \(code) and empty HTML listing: no post recognized."))
                }
                return .ok(L("JSON refusé (HTTP \(code)) mais listing HTML servi (\(posts.count) posts) — c'est ce repli qu'utilisent les téléchargements r/.",
                             "JSON refused (HTTP \(code)) but HTML listing served (\(posts.count) posts) — this is the fallback r/ downloads use."))
            } catch {
                return .fail(L("JSON HTTP \(code) et listing HTML indisponible : \(error.localizedDescription)",
                               "JSON HTTP \(code) and HTML listing unavailable: \(error.localizedDescription)"))
            }
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

    /// Instagram : vérifie le chemin utilisé par les téléchargements — page du
    /// profil lue (avec cookies de session si présents), jetons d'API GraphQL présents.
    private func probeInstagram(_ network: Network) async -> DiagnosticState {
        let pageURL = InstagramAPI.profilePageURL(username: "instagram")
        let sessionCookies = await InstagramSession.shared.cookieHeader(for: pageURL)
        do {
            let page = try await network.dataAndHeaders(pageURL, headers: InstagramAPI.pageHeaders(referer: pageURL, sessionCookies: sessionCookies))
            guard InstagramAPI.tokens(inHTML: page.data, cookies: page.headers["set-cookie"]) != nil else {
                return .fail(L("Page de profil servie sans jeton d'API (interface modifiée).",
                               "Profile page served without an API token (interface changed)."))
            }
            return .ok(sessionCookies != nil
                       ? L("Page de profil et jetons servis (avec session).", "Profile page and tokens served (signed in).")
                       : L("Page de profil et jetons anonymes servis.", "Anonymous profile page and tokens served."))
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
        HStack(alignment: .center, spacing: DS.space(3)) {
            Group {
                switch check.state {
                case .pending:
                    Image(systemName: "circle.dotted").foregroundStyle(DS.onSurfaceMuted)
                case .running:
                    ProgressView()
                case .ok:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.success)
                case .unconfigured:
                    Image(systemName: "minus.circle").foregroundStyle(DS.warning)
                case .fail:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.error)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.callout.weight(.medium))
                switch check.state {
                case .pending: Text(L("En attente.", "Pending.")).font(.caption).foregroundStyle(DS.onSurfaceMuted)
                case .running: Text(L("Sonde en cours…", "Probing…")).font(.caption).foregroundStyle(DS.onSurfaceMuted)
                case .ok(let message): Text(message).font(.caption).foregroundStyle(DS.success)
                case .unconfigured(let message): Text(message).font(.caption).foregroundStyle(DS.warning)
                case .fail(let message): Text(message).font(.caption).foregroundStyle(DS.error)
                }
            }
        }
        .padding(.vertical, DS.space(1))
        .accessibilityElement(children: .combine)
    }
}

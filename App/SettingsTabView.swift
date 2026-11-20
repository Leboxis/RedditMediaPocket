import SwiftUI
import MediaCore

/// Onglet **Réglages** : le formulaire des réglages, embarqué tel quel dans un
/// onglet (sans bouton « OK » de fermeture).
struct SettingsTabView: View {
    @ObservedObject var model: Downloader

    var body: some View {
        DownloadSettings(model: model, embedded: true)
    }
}

/// Ligne de connexion d'un service, dans les Réglages : marque compacte,
/// statut dans le sous-titre, pastille d'état et menu d'actions. Toucher la
/// ligne rouvre la fenêtre du service ; déconnexion et ouverture sont dans
/// le menu d'extrémité.
private struct ConnectionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let connected: Bool
    let rejected: Bool
    let status: String
    let busy: Bool
    let clearing: Bool
    let connectLabel: String
    let onConnect: () -> Void
    let onSignOut: () -> Void

    private var statusColor: Color { connected ? Color.green : (rejected ? DS.error : DS.onSurfaceMuted) }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.onSurface)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 12)
            Menu {
                Button(action: onConnect) { Label(connectLabel, systemImage: connected ? "safari" : "person.badge.key") }
                Button(role: .destructive, action: onSignOut) {
                    Label(L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(DS.onSurfaceMuted)
            }
            .disabled(busy || clearing)
            .accessibilityLabel(L("Actions \(title)", "\(title) actions"))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !busy, !clearing else { return }
            onConnect()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(status)")
        .accessibilityHint(connectLabel)
    }
}

private struct DownloadSettings: View {
    @ObservedObject var model: Downloader
    /// Vrai quand la vue est embarquée dans un onglet (pas de bouton « OK »).
    let embedded: Bool
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @ObservedObject private var reddit = RedditSession.shared
    @ObservedObject private var xSession = XSession.shared
    @ObservedObject private var tikTokSession = TikTokSession.shared
    @ObservedObject private var instagramSession = InstagramSession.shared
    @State private var loginPresented = false
    @State private var xLoginPresented = false
    @State private var tikTokLoginPresented = false
    @State private var instagramLoginPresented = false
    @State private var confirmDeleteAll = false
    @State private var diagnosticsPresented = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Langue", "Language"), selection: $language) {
                        Text("Français").tag("fr")
                        Text("English").tag("en")
                    }
                    .disabled(model.running)
                } footer: {
                    Text(L("Détectée automatiquement au premier lancement. Modifiable ici.", "Detected automatically on first launch. You can change it here."))
                }
                Section {
                    Stepper(value: $model.concurrentLimit, in: 1...ConcurrentDownloads.maximumLimit) {
                        HStack {
                            Text(L("Téléchargements simultanés", "Concurrent downloads"))
                            Spacer()
                            Text("\(model.concurrentLimit)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(model.running ? L("Appliqué au prochain lancement. En cours : \(model.sessionLimit).", "Applies to the next run. Current: \(model.sessionLimit).") : L("1 à 16. Par défaut : 10 pour toutes les sources. Un nombre élevé peut augmenter les limitations du serveur.", "1 to 16. Defaults: 10 for all sources. Higher values may increase server rate limiting."))
                }
                Section {
                    Picker(L("Morceaux par vidéo", "Parts per video"), selection: $model.xFetishSegments) {
                        ForEach(XFetishRangeDownload.segmentOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityValue("\(model.xFetishSegments)")
                } header: {
                    Text("X-Fetish")
                } footer: {
                    Text(L("Vidéos uniquement. 24 morceaux et 6 téléchargements simultanés par défaut. Repli automatique en connexion unique si nécessaire. Plus de morceaux peut augmenter les refus 403/429.", "Videos only. 24 parts and 6 concurrent downloads by default. Falls back to a single connection when needed. More parts may increase 403/429 refusals."))
                    if model.running {
                        Text(L("Appliqué au prochain lancement. En cours : \(model.sessionSegments).", "Applies to the next run. Current: \(model.sessionSegments)."))
                    }
                }
                Section {
                    ConnectionRow(symbol: "person.crop.circle", tint: DS.accent, title: L("Reddit", "Reddit"),
                                  connected: reddit.hasSession, rejected: false,
                                  status: reddit.hasSession ? L("Session détectée", "Session detected") : L("Sans session", "Signed out"),
                                  busy: model.running, clearing: reddit.clearing,
                                  connectLabel: reddit.hasSession ? L("Ouvrir Reddit", "Open Reddit") : L("Se connecter à Reddit", "Sign in to Reddit"),
                                  onConnect: { loginPresented = true },
                                  onSignOut: { Task { await reddit.logout() } })
                    ConnectionRow(symbol: "bird", tint: .gray, title: "X",
                                  connected: xSession.apiAccepted, rejected: xSession.apiRejected,
                                  status: xSession.apiAccepted ? L("Session détectée", "Session detected")
                                    : (xSession.apiRejected ? L("Session refusée", "Session rejected") : L("Sans session", "Signed out")),
                                  busy: model.running, clearing: xSession.clearing,
                                  connectLabel: xSession.hasSession ? L("Ouvrir X", "Open X") : L("Se connecter à X", "Sign in to X"),
                                  onConnect: { xLoginPresented = true },
                                  onSignOut: { Task { await xSession.logout() } })
                    ConnectionRow(symbol: "music.note", tint: .cyan, title: "TikTok",
                                  connected: tikTokSession.apiAccepted, rejected: tikTokSession.apiRejected,
                                  status: tikTokSession.apiAccepted ? L("Session détectée", "Session detected")
                                    : (tikTokSession.apiRejected ? L("Session refusée", "Session rejected") : L("Sans session", "Signed out")),
                                  busy: model.running, clearing: tikTokSession.clearing,
                                  connectLabel: tikTokSession.hasSession ? L("Ouvrir TikTok", "Open TikTok") : L("Se connecter à TikTok", "Sign in to TikTok"),
                                  onConnect: { tikTokLoginPresented = true },
                                  onSignOut: { Task { await tikTokSession.logout() } })
                    ConnectionRow(symbol: "camera", tint: .pink, title: "Instagram",
                                  connected: instagramSession.apiAccepted, rejected: instagramSession.apiRejected,
                                  status: instagramSession.apiAccepted ? L("Session détectée", "Session detected")
                                    : (instagramSession.apiRejected ? L("Session refusée", "Session rejected") : L("Sans session", "Signed out")),
                                  busy: model.running, clearing: instagramSession.clearing,
                                  connectLabel: instagramSession.hasSession ? L("Ouvrir Instagram", "Open Instagram") : L("Se connecter à Instagram", "Sign in to Instagram"),
                                  onConnect: { instagramLoginPresented = true },
                                  onSignOut: { Task { await instagramSession.logout() } })
                } header: {
                    Text(L("Connexions", "Accounts"))
                } footer: {
                    Text(model.running ? L("Arrête les transferts pour modifier la session.", "Stop downloads to change the session.")
                         : L("Sessions locales, indépendantes d'un service à l'autre. Toucher une ligne ouvre la fenêtre du service ; la déconnexion est dans son menu.", "Local sessions, independent across services. Tap a row to open the service's window; sign-out is in its menu."))
                }
                KDriveSettingsSection()
                Section {
                    Button(L("Test de santé des sources", "Source health check")) { diagnosticsPresented = true }
                } header: {
                    Text(L("Diagnostic", "Diagnostics"))
                } footer: {
                    Text(L("Interroge chaque source configurée et dit ce qui marche : flux public Reddit, jeton RedGifs, sessions X et TikTok, API Instagram, site X-Fetish.", "Queries each configured source and reports what works: Reddit public feed, RedGifs token, X and TikTok sessions, Instagram API, X-Fetish site."))
                }
                Section {
                    Picker(L("Espace disque maximal", "Maximum disk space"), selection: Binding(
                        get: { StorageQuota.gigabytes(for: model.storageQuota.bytes) },
                        set: { model.storageQuota = StorageQuota(bytes: Int64($0) * StorageQuota.bytesPerGB) }
                    )) {
                        ForEach(StorageQuota.optionsGB, id: \.self) { gb in
                            Text(StorageQuota.label(gb: gb)).tag(gb)
                        }
                    }
                    .disabled(model.running)
                } header: {
                    Text(L("Stockage", "Storage"))
                } footer: {
                    Text(model.running
                         ? L("Appliqué au prochain lancement.", "Applies to the next run.")
                         : L("Le parcours s'arrête proprement quand le plafond est atteint ; les médias déjà téléchargés restent en place. Le plafond porte sur la collection en cours.", "The scan stops cleanly once the limit is reached; media already downloaded stay in place. The limit applies to the current collection."))
                }
                Section {
                    Button(L("Supprimer tous les téléchargements", "Delete all downloads"), role: .destructive) { confirmDeleteAll = true }
                        .disabled(model.running)
                        .foregroundStyle(DS.error)
                } footer: {
                    Text(L("Efface les médias et les archives de tous les utilisateurs. Irréversible.", "Deletes media and archives for all users. Cannot be undone."))
                }
            }
            .fullScreenCover(isPresented: $loginPresented) { RedditLogin() }
            .fullScreenCover(isPresented: $xLoginPresented) { XLogin() }
            .fullScreenCover(isPresented: $tikTokLoginPresented) { TikTokLogin() }
            .fullScreenCover(isPresented: $instagramLoginPresented) { InstagramLogin() }
            .sheet(isPresented: $diagnosticsPresented) { SourceDiagnosticsView() }
            .confirmationDialog(L("Supprimer tous les téléchargements ?", "Delete all downloads?"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button(L("Tout supprimer", "Delete all"), role: .destructive) { model.deleteAllDownloads() }
                Button(L("Annuler", "Cancel"), role: .cancel) { }
            } message: {
                Text(L("Tous les médias téléchargés seront définitivement effacés.", "All downloaded media will be permanently deleted."))
            }
            .navigationTitle(L("Réglages", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                }
            }
        }
        .tint(DS.accent)
    }
}

#Preview("Réglages — clair") {
    SettingsTabView(model: Downloader())
}

#Preview("Réglages — sombre") {
    SettingsTabView(model: Downloader())
        .preferredColorScheme(.dark)
}

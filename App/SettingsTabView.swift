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
    @AppStorage("kDriveApiToken") private var kDriveToken = ""
    @AppStorage("kDriveId") private var kDriveId = ""
    @AppStorage("kDriveDirectoryName") private var kDriveDirectoryName = "Racine (kDrive)"
    @Environment(\.dismiss) private var dismiss

    private var kDriveConfigured: Bool {
        !kDriveToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !kDriveId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var kDriveFolderLabel: String {
        kDriveDirectoryName.isEmpty ? L("Racine (kDrive)", "Root (kDrive)") : kDriveDirectoryName
    }
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
                            Text("\(model.concurrentLimit)").monospacedDigit().foregroundStyle(DS.onSurfaceMuted)
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
                    SettingsRow(
                        symbol: "person.crop.circle", tint: DS.accent, title: L("Reddit", "Reddit"),
                        status: reddit.hasSession ? L("Session détectée", "Session detected") : L("Sans session", "Signed out"),
                        statusColor: reddit.hasSession ? DS.accentEmphasis : DS.onSurfaceMuted,
                        tap: { loginPresented = true },
                        enabled: !(model.running || reddit.clearing),
                        menuItems: [
                            .init(label: reddit.hasSession ? L("Ouvrir Reddit", "Open Reddit") : L("Se connecter à Reddit", "Sign in to Reddit"),
                                  systemImage: reddit.hasSession ? "safari" : "person.badge.key",
                                  action: { loginPresented = true }),
                            .init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                                  destructive: true, action: { Task { await reddit.logout() } })
                        ])
                    SettingsRow(
                        symbol: "bird", tint: .gray, title: "X",
                        status: xSession.apiAccepted ? L("Session détectée", "Session detected")
                            : (xSession.apiRejected ? L("Session refusée", "Session rejected") : L("Sans session", "Signed out")),
                        statusColor: xSession.apiAccepted ? DS.accentEmphasis : (xSession.apiRejected ? DS.error : DS.onSurfaceMuted),
                        tap: { xLoginPresented = true },
                        enabled: !(model.running || xSession.clearing),
                        menuItems: [
                            .init(label: xSession.hasSession ? L("Ouvrir X", "Open X") : L("Se connecter à X", "Sign in to X"),
                                  systemImage: xSession.hasSession ? "safari" : "person.badge.key",
                                  action: { xLoginPresented = true }),
                            .init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                                  destructive: true, action: { Task { await xSession.logout() } })
                        ])
                    SettingsRow(
                        symbol: "music.note", tint: .cyan, title: "TikTok",
                        status: tikTokSession.apiAccepted ? L("Session détectée", "Session detected")
                            : (tikTokSession.apiRejected ? L("Session refusée", "Session rejected") : L("Sans session", "Signed out")),
                        statusColor: tikTokSession.apiAccepted ? DS.accentEmphasis : (tikTokSession.apiRejected ? DS.error : DS.onSurfaceMuted),
                        tap: { tikTokLoginPresented = true },
                        enabled: !(model.running || tikTokSession.clearing),
                        menuItems: [
                            .init(label: tikTokSession.hasSession ? L("Ouvrir TikTok", "Open TikTok") : L("Se connecter à TikTok", "Sign in to TikTok"),
                                  systemImage: tikTokSession.hasSession ? "safari" : "person.badge.key",
                                  action: { tikTokLoginPresented = true }),
                            .init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                                  destructive: true, action: { Task { await tikTokSession.logout() } })
                        ])
                    SettingsRow(
                        symbol: "camera", tint: .pink, title: "Instagram",
                        status: instagramSession.apiAccepted ? L("Session détectée", "Session detected")
                            : (instagramSession.apiRejected ? L("Session refusée", "Session rejected") : L("Sans session", "Signed out")),
                        statusColor: instagramSession.apiAccepted ? DS.accentEmphasis : (instagramSession.apiRejected ? DS.error : DS.onSurfaceMuted),
                        tap: { instagramLoginPresented = true },
                        enabled: !(model.running || instagramSession.clearing),
                        menuItems: [
                            .init(label: instagramSession.hasSession ? L("Ouvrir Instagram", "Open Instagram") : L("Se connecter à Instagram", "Sign in to Instagram"),
                                  systemImage: instagramSession.hasSession ? "safari" : "person.badge.key",
                                  action: { instagramLoginPresented = true }),
                            .init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                                  destructive: true, action: { Task { await instagramSession.logout() } })
                        ])
                    NavigationLink {
                        KDriveSettingsDetailView()
                    } label: {
                        SettingsRow(
                            symbol: "icloud", tint: .blue, title: "Infomaniak kDrive",
                            status: kDriveConfigured
                                ? L("Configuré · \(kDriveFolderLabel)", "Configured · \(kDriveFolderLabel)")
                                : L("Non configuré", "Not configured"),
                            statusColor: kDriveConfigured ? DS.accentEmphasis : DS.onSurfaceMuted,
                            tap: nil,
                            menuItems: [
                                .init(label: L("Effacer la configuration", "Clear configuration"), systemImage: "trash",
                                      destructive: true, action: { kDriveToken = ""; kDriveId = "" })
                            ])
                    }
                    // Diagnostic discret, dans la zone Connexions.
                    Button { diagnosticsPresented = true } label: {
                        Label(L("Test de santé des sources", "Source health check"), systemImage: "waveform.path.ecg")
                            .font(.caption)
                            .foregroundStyle(DS.onSurfaceMuted)
                            .contentShape(Rectangle())
                    }
                } header: {
                    Text(L("Connexions", "Accounts"))
                } footer: {
                    Text(model.running ? L("Arrête les transferts pour modifier la session.", "Stop downloads to change the session.")
                         : L("Sessions locales, indépendantes d'un service à l'autre. Toucher une ligne ouvre la fenêtre du service ou ses réglages ; la déconnexion est dans son menu.", "Local sessions, independent across services. Tap a row to open the service's window or its settings; sign-out is in its menu."))
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

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
    /// État de la synchronisation Cloudflare, partagé avec toute l'app.
    @StateObject private var synchronisation = SyncService.shared
    /// État de la synchronisation des cookies de session.
    @StateObject private var sessions = SessionCookieSyncService.shared
    @State private var clePresentee = false
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
    @State private var logoutServiceTitle: String?
    @State private var logoutAction: (() async -> Void)?
    @AppStorage("kDriveApiToken") private var kDriveToken = ""
    @AppStorage("kDriveId") private var kDriveId = ""
    @AppStorage("kDriveDirectoryName") private var kDriveDirectoryName = ""
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
                    Text(model.running ? L("Appliqué au prochain lancement. En cours : \(model.sessionLimit).", "Applies to the next run. Current: \(model.sessionLimit).") : L("1 à 16. Par défaut : 10, ou 6 pour X-Fetish. Un nombre élevé peut augmenter les limitations du serveur.", "1 to 16. Defaults: 10, or 6 for X-Fetish. Higher values may increase server rate limiting."))
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
                        symbol: "person.crop.circle",
                        tint: reddit.hasSession ? DS.success : DS.warning,
                        title: L("Reddit", "Reddit"),
                        status: reddit.hasSession ? L("Session détectée", "Session detected") : L("Sans session", "Signed out"),
                        statusColor: reddit.hasSession ? DS.success : DS.warning,
                        tap: { loginPresented = true },
                        enabled: !(model.running || reddit.clearing),
                        menuItems: redditMenuItems)
                    SettingsRow(
                        symbol: "bird",
                        tint: sessionStatusColor(hasSession: xSession.hasSession, rejected: xSession.apiRejected),
                        title: "X",
                        status: sessionStatus(hasSession: xSession.hasSession, rejected: xSession.apiRejected),
                        statusColor: sessionStatusColor(hasSession: xSession.hasSession, rejected: xSession.apiRejected),
                        tap: { xLoginPresented = true },
                        enabled: !(model.running || xSession.clearing),
                        menuItems: xMenuItems)
                    SettingsRow(
                        symbol: "music.note",
                        tint: sessionStatusColor(hasSession: tikTokSession.hasSession, rejected: tikTokSession.apiRejected),
                        title: "TikTok",
                        status: sessionStatus(hasSession: tikTokSession.hasSession, rejected: tikTokSession.apiRejected),
                        statusColor: sessionStatusColor(hasSession: tikTokSession.hasSession, rejected: tikTokSession.apiRejected),
                        tap: { tikTokLoginPresented = true },
                        enabled: !(model.running || tikTokSession.clearing),
                        menuItems: tikTokMenuItems)
                    SettingsRow(
                        symbol: "camera",
                        tint: sessionStatusColor(hasSession: instagramSession.hasSession, rejected: instagramSession.apiRejected),
                        title: "Instagram",
                        status: sessionStatus(hasSession: instagramSession.hasSession, rejected: instagramSession.apiRejected),
                        statusColor: sessionStatusColor(hasSession: instagramSession.hasSession, rejected: instagramSession.apiRejected),
                        tap: { instagramLoginPresented = true },
                        enabled: !(model.running || instagramSession.clearing),
                        menuItems: instagramMenuItems)
                    NavigationLink {
                        KDriveSettingsDetailView()
                    } label: {
                        SettingsRow(
                            symbol: "icloud",
                            tint: kDriveConfigured ? DS.success : DS.warning,
                            title: "Infomaniak kDrive",
                            status: kDriveConfigured
                                ? L("Configuré · \(kDriveFolderLabel)", "Configured · \(kDriveFolderLabel)")
                                : L("Non configuré", "Not configured"),
                            statusColor: kDriveConfigured ? DS.success : DS.warning,
                            tap: nil)
                    }
                    SettingsRow(
                        symbol: "waveform.path.ecg",
                        tint: DS.accentEmphasis,
                        title: L("Test de santé des sources", "Source health check"),
                        status: L("Vérifier les API et sessions locales", "Check APIs and local sessions"),
                        tap: { diagnosticsPresented = true },
                        showsChevron: true)
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

                Section {
                    HStack {
                        Text(L("État", "Status"))
                        Spacer()
                        Text(synchronisation.etat)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let date = synchronisation.derniereSynchronisation {
                        Text("\(L("Dernière synchronisation", "Last sync")) : \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(L("Synchroniser maintenant", "Sync now")) {
                        Task {
                            if reddit.hasSession, let suivis = try? await model.followedUsers() {
                                SuiviStore.enregistrerListe(suivis, notifier: false)
                            }
                            await synchronisation.synchroniser()
                        }
                    }
                    Button(L("Restaurer depuis le serveur", "Restore from server")) {
                        Task { await synchronisation.restaurer() }
                    }
                    Button(L("Clé API", "API key")) { clePresentee = true }
                } header: {
                    Text(L("Comptes suivis (Cloudflare)", "Followed accounts (Cloudflare)"))
                } footer: {
                    Text(L("La liste des comptes suivis (Reddit, X et TikTok) ainsi que leur statut (coche « déjà téléchargé », date du dernier téléchargement complet et du dernier upload) sont synchronisés. Ils restent affichés même sans connexion et reviennent après une réinstallation. Les cookies de session sont synchronisés dans la section ci-dessous. Aucun média ne quitte l'iPhone.", "The list of followed accounts (Reddit, X and TikTok) and their status (“already downloaded” checkmark, last full download date and last upload date) are synced. They remain visible even when signed out and come back after a reinstall. Session cookies are synced in the section below. No media leaves the iPhone."))
                }
                Section {
                    HStack {
                        Text(L("État", "Status"))
                        Spacer()
                        Text(sessions.etat)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let date = sessions.derniereSynchronisation {
                        Text("\(L("Dernière synchronisation", "Last sync")) : \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !sessions.sitesSauvegardes.isEmpty {
                        Text("\(L("Sites sauvegardés", "Backed-up sites")) : \(sessions.sitesSauvegardes.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(L("Synchroniser les sessions", "Sync sessions")) {
                        Task { await sessions.synchroniser() }
                    }
                    Button(L("Restaurer les sessions", "Restore sessions")) {
                        Task { await sessions.restaurer() }
                    }
                    Button(L("Effacer les sessions du serveur", "Clear remote sessions"), role: .destructive) {
                        Task { await sessions.supprimerSauvegarde() }
                    }
                } header: {
                    Text(L("Sessions (Cloudflare)", "Sessions (Cloudflare)"))
                } footer: {
                    Text(L("Les cookies Reddit, X, TikTok et Instagram sont envoyés après chaque connexion puis réinjectés dans l'iPhone dès que la clé API est renseignée : une installation neuve retrouve donc ses connexions. Serveur personnel, protégé par la même clé. Aucun média n'est synchronisé.", "Reddit, X, TikTok and Instagram cookies are uploaded after each sign-in and injected back into the iPhone as soon as the API key is entered: a fresh install therefore recovers its sign-ins. Personal server, protected by the same key. No media is synced."))
                }
            }
            .sheet(isPresented: $clePresentee) {
                APIKeySettingsView()
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
            .confirmationDialog(
                L("Déconnecter \(logoutServiceTitle ?? "") ?", "Sign out of \(logoutServiceTitle ?? "")?"),
                isPresented: Binding(
                    get: { logoutServiceTitle != nil },
                    set: { if !$0 { logoutServiceTitle = nil; logoutAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("Déconnexion", "Sign out"), role: .destructive) {
                    let action = logoutAction
                    logoutServiceTitle = nil
                    logoutAction = nil
                    if let action { Task { await action() } }
                }
                Button(L("Annuler", "Cancel"), role: .cancel) {
                    logoutServiceTitle = nil
                    logoutAction = nil
                }
            } message: {
                Text(L("La session locale de ce service sera supprimée.", "The local session for this service will be removed."))
            }
            .navigationTitle(L("Réglages", "Settings"))
            .navigationBarTitleDisplayMode(embedded ? .large : .inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                }
            }
        }
        .tint(DS.accentEmphasis)
    }

    private func sessionStatus(hasSession: Bool, rejected: Bool) -> String {
        if rejected { return L("Session refusée", "Session rejected") }
        return hasSession ? L("Session détectée", "Session detected") : L("Sans session", "Signed out")
    }

    private func sessionStatusColor(hasSession: Bool, rejected: Bool) -> Color {
        if rejected { return DS.error }
        return hasSession ? DS.success : DS.warning
    }

    private var redditMenuItems: [SettingsRow.MenuItem] {
        var items = [SettingsRow.MenuItem(
            label: reddit.hasSession ? L("Ouvrir Reddit", "Open Reddit") : L("Se connecter à Reddit", "Sign in to Reddit"),
            systemImage: reddit.hasSession ? "safari" : "person.badge.key",
            action: { loginPresented = true }
        )]
        if reddit.hasSession {
            items.append(.init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                               destructive: true, action: {
                logoutServiceTitle = "Reddit"
                logoutAction = { await reddit.logout() }
            }))
        }
        return items
    }

    private var xMenuItems: [SettingsRow.MenuItem] {
        var items = [SettingsRow.MenuItem(
            label: xSession.hasSession ? L("Ouvrir X", "Open X") : L("Se connecter à X", "Sign in to X"),
            systemImage: xSession.hasSession ? "safari" : "person.badge.key",
            action: { xLoginPresented = true }
        )]
        if xSession.hasSession {
            items.append(.init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                               destructive: true, action: {
                logoutServiceTitle = "X"
                logoutAction = { await xSession.logout() }
            }))
        }
        return items
    }

    private var tikTokMenuItems: [SettingsRow.MenuItem] {
        var items = [SettingsRow.MenuItem(
            label: tikTokSession.hasSession ? L("Ouvrir TikTok", "Open TikTok") : L("Se connecter à TikTok", "Sign in to TikTok"),
            systemImage: tikTokSession.hasSession ? "safari" : "person.badge.key",
            action: { tikTokLoginPresented = true }
        )]
        if tikTokSession.hasSession {
            items.append(.init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                               destructive: true, action: {
                logoutServiceTitle = "TikTok"
                logoutAction = { await tikTokSession.logout() }
            }))
        }
        return items
    }

    private var instagramMenuItems: [SettingsRow.MenuItem] {
        var items = [SettingsRow.MenuItem(
            label: instagramSession.hasSession ? L("Ouvrir Instagram", "Open Instagram") : L("Se connecter à Instagram", "Sign in to Instagram"),
            systemImage: instagramSession.hasSession ? "safari" : "person.badge.key",
            action: { instagramLoginPresented = true }
        )]
        if instagramSession.hasSession {
            items.append(.init(label: L("Déconnexion", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right",
                               destructive: true, action: {
                logoutServiceTitle = "Instagram"
                logoutAction = { await instagramSession.logout() }
            }))
        }
        return items
    }
}

#Preview("Réglages — clair") {
    SettingsTabView(model: Downloader())
}

#Preview("Réglages — sombre") {
    SettingsTabView(model: Downloader())
        .preferredColorScheme(.dark)
}

import SwiftUI
import MediaCore

/// Onglet **Réglages** : le formulaire des réglages, embarqué tel quel dans un
/// onglet (sans bouton « OK » de fermeture).
struct SettingsTabView: View {
    @Bindable var model: Downloader

    var body: some View {
        DownloadSettings(model: model, embedded: true)
    }
}

private struct DownloadSettings: View {
    @Bindable var model: Downloader
    /// État de la synchronisation Cloudflare, partagé avec toute l'app.
    @State private var synchronisation = SyncService.shared
    /// État de la synchronisation des cookies de session.
    @State private var sessions = SessionCookieSyncService.shared
    @State private var clePresentee = false
    /// Vrai quand la vue est embarquée dans un onglet (pas de bouton « OK »).
    let embedded: Bool
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    @State private var reddit = RedditSession.shared
    @State private var xSession = XSession.shared
    @State private var tikTokSession = TikTokSession.shared
    @State private var instagramSession = InstagramSession.shared
    @State private var loginPresented = false
    @State private var xLoginPresented = false
    @State private var tikTokLoginPresented = false
    @State private var instagramLoginPresented = false
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteRemoteSessions = false
    @State private var hasCloudflareAPIKey = KeychainStore.get() != nil
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
                }
                Section {
                    Stepper(value: $model.concurrentLimit, in: 1...ConcurrentDownloads.maximumLimit) {
                        HStack {
                            Text(L("Téléchargements simultanés", "Concurrent downloads"))
                            Spacer()
                            Text("\(model.concurrentLimit)").monospacedDigit().foregroundStyle(DS.onSurfaceMuted)
                        }
                    }
                }
                Section {
                    DSSegmentedControl(
                        L("Morceaux par vidéo", "Parts per video"),
                        selection: $model.xFetishSegments,
                        options: XFetishRangeDownload.segmentOptions.map { ($0, "\($0)") }
                    )
                    .accessibilityValue("\(model.xFetishSegments)")
                } header: {
                    Text("X-Fetish")
                }
                Section {
                    KDrivePacingToggle()
                    KDrivePacingLimitSlider()
                    KDriveConcurrentUploadsPicker()
                } header: {
                    Text(L("Upload kDrive", "kDrive upload"))
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
                }
                Section {
                    Button(L("Supprimer tous les téléchargements", "Delete all downloads"), role: .destructive) { confirmDeleteAll = true }
                        .disabled(model.running)
                        .foregroundStyle(DS.error)
                } footer: {
                    Text(L("Efface les médias et les archives de tous les utilisateurs. Irréversible.", "Deletes media and archives for all users. Cannot be undone."))
                }

                Section {
                    SettingsRow(
                        symbol: "person.2",
                        tint: cloudflareStatusColor(
                            etat: synchronisation.etat,
                            lastSync: synchronisation.derniereSynchronisation
                        ),
                        title: L("Comptes suivis", "Followed accounts"),
                        status: cloudflareFollowsStatus,
                        statusColor: cloudflareStatusColor(
                            etat: synchronisation.etat,
                            lastSync: synchronisation.derniereSynchronisation
                        ),
                        tap: { syncCloudflareFollows() },
                        menuItems: cloudflareFollowsMenuItems)
                    SettingsRow(
                        symbol: "key.icloud",
                        tint: cloudflareStatusColor(
                            etat: sessions.etat,
                            lastSync: sessions.derniereSynchronisation
                        ),
                        title: L("Sessions", "Sessions"),
                        status: cloudflareSessionsStatus,
                        statusColor: cloudflareStatusColor(
                            etat: sessions.etat,
                            lastSync: sessions.derniereSynchronisation
                        ),
                        tap: { Task { await sessions.synchroniser() } },
                        menuItems: cloudflareSessionsMenuItems)
                } header: {
                    HStack {
                        Text("Cloudflare")
                        Spacer()
                        Button {
                            clePresentee = true
                        } label: {
                            HStack(spacing: DS.space(1)) {
                                Image(systemName: hasCloudflareAPIKey ? "key.fill" : "key")
                                Text(hasCloudflareAPIKey ? L("Clé API", "API key") : L("Ajouter clé API", "Add API key"))
                            }
                            .font(.caption.weight(.medium))
                            .textCase(nil)
                            .foregroundStyle(hasCloudflareAPIKey ? DS.onSurfaceMuted : DS.warning)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hasCloudflareAPIKey ? L("Modifier la clé API Cloudflare", "Edit Cloudflare API key") : L("Configurer la clé API Cloudflare", "Configure Cloudflare API key"))
                    }
                } footer: {
                    Text(L("Toucher une ligne synchronise ; « … » ouvre restauration et suppression.", "Tap a row to sync; “…” opens restore and delete."))
                }
            }
            .sheet(isPresented: $clePresentee) {
                APIKeySettingsView()
            }
            .onChange(of: clePresentee) { _, shown in
                if !shown { hasCloudflareAPIKey = KeychainStore.get() != nil }
            }
            .task {
                hasCloudflareAPIKey = KeychainStore.get() != nil
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
                L("Effacer les sessions du serveur ?", "Clear remote sessions?"),
                isPresented: $confirmDeleteRemoteSessions,
                titleVisibility: .visible
            ) {
                Button(L("Effacer du serveur", "Clear remote"), role: .destructive) {
                    Task { await sessions.supprimerSauvegarde() }
                }
                Button(L("Annuler", "Cancel"), role: .cancel) { }
            } message: {
                Text(L("Les cookies de session sauvegardés sur Cloudflare seront supprimés. Vos connexions locales restent intactes.", "Session cookies backed up on Cloudflare will be removed. Local sessions remain intact."))
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

    private func cloudflareStatusColor(etat: String, lastSync: Date?) -> Color {
        if !hasCloudflareAPIKey { return DS.warning }
        let lower = etat.lowercased()
        if lower.contains("erreur") || lower.contains("error") || lower.contains("impossible") || lower.contains("failed") {
            return DS.error
        }
        return lastSync != nil ? DS.success : DS.onSurfaceMuted
    }

    private func cloudflareShortDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var cloudflareFollowsStatus: String {
        var parts = [synchronisation.etat]
        if let date = synchronisation.derniereSynchronisation {
            parts.append(cloudflareShortDate(date))
        }
        return parts.joined(separator: " · ")
    }

    private var cloudflareSessionsStatus: String {
        var parts = [sessions.etat]
        if !sessions.sitesSauvegardes.isEmpty {
            parts.append(sessions.sitesSauvegardes.joined(separator: ", "))
        }
        if let date = sessions.derniereSynchronisation {
            parts.append(cloudflareShortDate(date))
        }
        return parts.joined(separator: " · ")
    }

    private func syncCloudflareFollows() {
        Task {
            if reddit.hasSession, let suivis = try? await model.followedUsers() {
                SuiviStore.enregistrerListe(suivis, notifier: false)
            }
            await synchronisation.synchroniser()
        }
    }

    private var cloudflareFollowsMenuItems: [SettingsRow.MenuItem] {
        [
            .init(
                label: L("Synchroniser maintenant", "Sync now"),
                systemImage: "arrow.triangle.2.circlepath",
                action: { syncCloudflareFollows() }
            ),
            .init(
                label: L("Restaurer depuis le serveur", "Restore from server"),
                systemImage: "arrow.down.circle",
                action: { Task { await synchronisation.restaurer() } }
            )
        ]
    }

    private var cloudflareSessionsMenuItems: [SettingsRow.MenuItem] {
        [
            .init(
                label: L("Synchroniser les sessions", "Sync sessions"),
                systemImage: "arrow.triangle.2.circlepath",
                action: { Task { await sessions.synchroniser() } }
            ),
            .init(
                label: L("Restaurer les sessions", "Restore sessions"),
                systemImage: "arrow.down.circle",
                action: { Task { await sessions.restaurer() } }
            ),
            .init(
                label: L("Effacer du serveur", "Clear remote"),
                systemImage: "trash",
                destructive: true,
                action: { confirmDeleteRemoteSessions = true }
            )
        ]
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

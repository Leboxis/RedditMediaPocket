import SwiftUI
import MediaCore

@main @MainActor struct RedditMediaPocketApp: App {
    @UIApplicationDelegateAdaptor(PocketAppDelegate.self) private var appDelegate
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current
    init() { AppLanguage.initialize(); LegacyBackgroundCleanup.shared.runIfNeeded() }
    var body: some Scene { WindowGroup { ContentView().environment(\.locale, Locale(identifier: language)) } }
}

/// Coquille de navigation de la refonte « Console d'archive » (direction A) :
/// un `TabView` de 4 onglets — **Nouveau** (la commande + console de transfert,
/// écran-matrice), **Bibliothèque** (galerie), **Activité** (journaux),
/// **Réglages** — avec la bannière d'upload kDrive et l'alerte d'erreur
/// globales. La synchronisation Cloudflare se règle en bas des Réglages.
struct ContentView: View {
    @StateObject private var model = Downloader()
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            NewDownloadView(model: model)
                .tabItem { Label(L("Nouveau", "New"), systemImage: "arrow.down.circle") }
                .tag(0)
            LibraryView(model: model, goToDownload: { tab = 0 })
                .tabItem { Label(L("Bibliothèque", "Library"), systemImage: "square.grid.3x3") }
                .tag(1)
            ActivityView(model: model)
                .tabItem { Label(L("Activité", "Activity"), systemImage: "bolt.horizontal") }
                .tag(2)
            SettingsTabView(model: model)
                .tabItem { Label(L("Réglages", "Settings"), systemImage: "gearshape") }
                .tag(3)
        }
        .tint(DS.accentEmphasis)
        .task {
            await SyncService.shared.demarrer()
            model.appliquerDonneesDuServeur()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            KDriveUploadBanner()
                .padding(.top, DS.space(1))
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.reloadIfFolderChanged() }
            if phase == .background { model.stop() }
        }
        .alert("Pocket", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

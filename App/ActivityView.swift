import SwiftUI
import MediaCore

/// Onglet **Activité** : journal de bord et journal des échecs, présentés
/// comme des lignes de la zone Connexions des Réglages (même composant
/// `SettingsRow`), ouvertes en feuille.
struct ActivityView: View {
    var model: Downloader
    private var logs = LogCenter.shared
    private var journal = FailureJournal.shared
    private var kDriveFreshness = KDriveFreshnessCenter.shared
    @State private var logsPresented = false
    @State private var failuresPresented = false
    @State private var kDriveStatusPresented = false

    private var kDriveStatusColor: Color {
        if kDriveFreshness.redCount > 0 { return DS.calmRose }
        if kDriveFreshness.orangeCount > 0 { return DS.calmAmber }
        return DS.onSurfaceMuted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsRow(
                        symbol: "arrow.clockwise.icloud",
                        customIcon: { AnyView(KDriveStatusIcon(baseSize: 18)) },
                        tint: DS.accentEmphasis,
                        title: L("État kDrive des collections", "kDrive collections status"),
                        status: kDriveFreshness.summaryLine,
                        statusColor: kDriveStatusColor,
                        tap: { kDriveStatusPresented = true },
                        showsChevron: true)
                    SettingsRow(
                        symbol: "doc.text.magnifyingglass", tint: DS.accentEmphasis,
                        title: L("Journal de bord", "Logs"),
                        status: logs.errorCount > 0
                            ? L("\(logs.errorCount) erreur(s)", "\(logs.errorCount) error(s)")
                            : L("Aucune erreur", "No errors"),
                        statusColor: logs.errorCount > 0 ? DS.error : DS.onSurfaceMuted,
                        tap: { logsPresented = true },
                        showsChevron: true)
                    SettingsRow(
                        symbol: "exclamationmark.triangle", tint: DS.accentEmphasis,
                        title: L("Journal des échecs", "Failure journal"),
                        status: journal.entries.isEmpty
                            ? L("Aucun échec en attente", "No pending failures")
                            : L("\(journal.entries.count) en attente", "\(journal.entries.count) pending"),
                        statusColor: journal.entries.isEmpty ? DS.onSurfaceMuted : DS.accentEmphasis,
                        tap: { failuresPresented = true },
                        showsChevron: true)
                }
            }
            .navigationTitle(L("Activité", "Activity"))
            .sheet(isPresented: $kDriveStatusPresented) { KDriveCollectionsStatusView(model: model) }
            .sheet(isPresented: $logsPresented) { LogsView() }
            .sheet(isPresented: $failuresPresented) { FailureJournalView(model: model) }
        }
    }
}

#Preview("Activité — clair") {
    ActivityView(model: Downloader())
}

#Preview("Activité — sombre") {
    ActivityView(model: Downloader())
        .preferredColorScheme(.dark)
}

#Preview("Activité — texte accessibility XXL") {
    ActivityView(model: Downloader())
        .dynamicTypeSize(.accessibility3)
}

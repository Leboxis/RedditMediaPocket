import SwiftUI
import MediaCore

/// Onglet **Activité** : le suivi des opérations — journal de bord et journal
/// des échecs, présentés en feuilles depuis une liste à deux entrées.
struct ActivityView: View {
    @ObservedObject var model: Downloader
    @ObservedObject private var logs = LogCenter.shared
    @ObservedObject private var journal = FailureJournal.shared
    @State private var logsPresented = false
    @State private var failuresPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { logsPresented = true } label: {
                        activityRow(
                            icon: "doc.text.magnifyingglass",
                            title: L("Journal de bord", "Logs"),
                            detail: logs.errorCount > 0
                                ? L("\(logs.errorCount) erreur(s)", "\(logs.errorCount) error(s)")
                                : L("Aucune erreur", "No errors"),
                            detailColor: logs.errorCount > 0 ? DS.error : DS.onSurfaceMuted
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    Button { failuresPresented = true } label: {
                        activityRow(
                            icon: "exclamationmark.triangle",
                            title: L("Journal des échecs", "Failure journal"),
                            detail: journal.entries.isEmpty
                                ? L("Aucun échec en attente", "No pending failures")
                                : L("\(journal.entries.count) en attente", "\(journal.entries.count) pending"),
                            detailColor: journal.entries.isEmpty ? DS.onSurfaceMuted : DS.accentEmphasis
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
            .navigationTitle(L("Activité", "Activity"))
            .sheet(isPresented: $logsPresented) { LogsView() }
            .sheet(isPresented: $failuresPresented) { FailureJournalView(model: model) }
        }
    }

    private func activityRow(icon: String, title: String, detail: String, detailColor: Color) -> some View {
        HStack(spacing: DS.space(3)) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.accentEmphasis)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.onSurface)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.onSurfaceMuted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(detail)")
    }
}

#Preview("Activité — clair") {
    ActivityView(model: Downloader())
}

#Preview("Activité — sombre") {
    ActivityView(model: Downloader())
        .preferredColorScheme(.dark)
}

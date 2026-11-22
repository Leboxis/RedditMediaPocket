import SwiftUI
import MediaCore

/// Ligne de réglage type « connexion » : tuile d'icône teintée, titre, statut
/// en sous-titre, action d'extrémité (menu « … » ou chevron). Partagée par la
/// zone Connexions des Réglages, la ligne kDrive et l'onglet Activité pour
/// que toutes ces zones se ressemblent.
struct SettingsRow: View {
    struct MenuItem: Identifiable {
        var id: String { "\(label)-\(systemImage)" }
        let label: String
        let systemImage: String
        var destructive = false
        let action: () -> Void
    }

    let symbol: String
    var customIcon: AnyView? = nil
    let tint: Color
    let title: String
    let status: String
    var statusColor: Color = DS.onSurfaceMuted
    /// Action au toucher sur la ligne ; `nil` quand la ligne est embarquée
    /// dans un `NavigationLink` (le lien gère le toucher).
    var tap: (() -> Void)?
    var enabled = true
    var menuItems: [MenuItem] = []
    var showsChevron = false

    var body: some View {
        HStack(spacing: DS.space(3)) {
            rowLabel
            Spacer(minLength: DS.space(3))
            if !menuItems.isEmpty {
                Menu {
                    ForEach(menuItems) { item in
                        Button(role: item.destructive ? .destructive : nil, action: item.action) {
                            Label(item.label, systemImage: item.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(DS.onSurfaceMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L("Actions \(title)", "\(title) actions"))
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.onSurfaceMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, DS.space(1))
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    @ViewBuilder private var rowLabel: some View {
        let info = HStack(spacing: DS.space(3)) {
            Group {
                if let customIcon {
                    customIcon
                } else {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusS))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.onSurface)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(status)")

        if let tap {
            Button(action: tap) { info }
                .buttonStyle(.plain)
        } else {
            info
        }
    }
}

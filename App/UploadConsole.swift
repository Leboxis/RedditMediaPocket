import SwiftUI
import MediaCore

/// Carte « console » des envois kDrive (direction A) : en-tête façon ligne de
/// Réglages (tuile icône + titre + statut), puis — pendant l'envoi — grand
/// compteur monospaced, barre de progression accent et statistiques en
/// caption ; à la fin, icône de statut + résumé synthétique.
struct UploadConsoleCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let status: String
    /// Compteur affiché en grand (ex. « 12 / 181 »), nil à l'état final.
    let counter: String?
    let progress: Double?
    /// Statistiques (libellé, valeur) en petites lignes monospaced.
    let stats: [(label: String, value: String)]
    let summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space(3)) {
            // En-tête, même habillage qu'une ligne de la zone Connexions.
            HStack(spacing: DS.space(3)) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 44, height: 44)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusM))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.headline)
                        .foregroundStyle(DS.onSurface)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(DS.onSurfaceMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: DS.space(3))
            }

            if let counter, let progress {
                VStack(alignment: .leading, spacing: DS.space(2)) {
                    Text(counter)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(DS.onSurface)
                        .accessibilityLabel(counter)
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(DS.accent)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("Progression de l'envoi", "Upload progress"))
                        .accessibilityValue("\(Int(progress * 100)) %")
                }
            }

            if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(DS.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !stats.isEmpty {
                VStack(alignment: .leading, spacing: DS.space(1)) {
                    ForEach(stats.indices, id: \.self) { i in
                        HStack {
                            Text(stats[i].label)
                                .font(DS.caption2)
                                .foregroundStyle(DS.onSurfaceMuted)
                            Spacer()
                            Text(stats[i].value)
                                .font(DS.monoCaption)
                                .foregroundStyle(DS.onSurface)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(DS.space(4))
        .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusL))
        .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
        .accessibilityElement(children: .combine)
    }
}

/// Bouton d'action pleine largeur, épinglé en bas des feuilles d'upload.
struct UploadActionButton: View {
    let title: String
    let systemImage: String?
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: DS.space(2)) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(DS.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(prominent ? .borderedProminent : .bordered)
        .tint(prominent ? DS.accent : (destructive ? DS.error : DS.accent))
        .controlSize(.large)
    }
}

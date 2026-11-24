import SwiftUI
import MediaCore

/// Carte « console » des envois kDrive (direction A) : en-tête façon ligne de
/// Réglages (tuile icône + titre + statut), puis — pendant l'envoi — grand
/// compteur monospaced, barre de progression accent et statistiques en
/// caption sur deux colonnes ; à la fin, icône de statut + résumé synthétique.
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
        VStack(alignment: .leading, spacing: DS.space(2)) {
            HStack(spacing: DS.space(3)) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
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
            .accessibilityElement(children: .combine)

            if let counter, let progress {
                VStack(alignment: .leading, spacing: DS.space(1)) {
                    Text(counter)
                        .font(DS.monoTitle)
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
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.space(2)) {
                    ForEach(stats, id: \.label) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.label)
                                .font(DS.caption2)
                                .foregroundStyle(DS.onSurfaceMuted)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            Text(stat.value)
                                .font(DS.monoCaption)
                                .foregroundStyle(DS.onSurface)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(DS.space(3))
        .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusL))
        .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
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
        let label = HStack(spacing: DS.space(2)) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .font(DS.headline)
        .frame(maxWidth: .infinity, minHeight: 48)

        let button = Button(role: destructive ? .destructive : nil, action: action) { label }
        if prominent {
            button.buttonStyle(DSPrimaryButtonStyle())
        } else {
            button.buttonStyle(.bordered).tint(destructive ? DS.error : DS.accentEmphasis)
        }
    }
}

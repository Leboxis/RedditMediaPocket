import SwiftUI
import UIKit

/// Design system de la refonte « Console d'archive » (direction A).
///
/// Toute valeur visuelle passe par ces tokens : aucune couleur littérale,
/// aucun rayon ou espacement magique dans les vues. Les couleurs sont des
/// couleurs sémantiques de l'Asset Catalog, chacune avec une variante Any et
/// une variante Dark (jamais d'inversion en dark : variantes désaturées et
/// plus claires).
enum DS {
    // MARK: - Couleurs (Asset Catalog, Any + Dark)

    /// Remplissages d'accent (boutons primaires, onglet actif).
    static let accent = Color("Accent")
    /// Accent pour texte et icônes posés sur un fond (contraste ≥ 4,5:1).
    static let accentEmphasis = Color("AccentEmphasis")
    static let background = Color("Background")
    static let surface = Color("Surface")
    static let surfaceElevated = Color("SurfaceElevated")
    static let onSurface = Color("OnSurface")
    static let onSurfaceMuted = Color("OnSurfaceMuted")
    /// Texte posé sur `accent` (paire approuvée accent/fond, contraste ≥ 4,5:1).
    static let onAccent = Color("OnAccent")
    static let error = Color("Error")
    /// Statut « connecté / opérationnel » : vert (contraste ≥ 4,5:1 sur fond clair et sombre).
    static let success = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1)
            : UIColor(red: 0.08, green: 0.50, blue: 0.20, alpha: 1)
    })
    /// Statut « absent / non configuré » : orange (contraste ≥ 4,5:1).
    static let warning = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.70, blue: 0.25, alpha: 1)
            : UIColor(red: 0.70, green: 0.38, blue: 0.00, alpha: 1)
    })
    /// Palette « Apple Calm Tech » (Colorimétrie C) :
    /// - `calmSage` : Vert Sauge discret (#6EE7B7 sombre / #0F766E clair) pour la coche « À jour ».
    /// - `calmAmber` : Ambre (#F59E0B sombre / #B45309 clair) pour les nouveautés ou envois en attente.
    /// - `calmRose` : Rose-Corail (#FB7185 sombre / #BE123C clair) pour les collections absentes ou en erreur.
    static let calmSage = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.431, green: 0.906, blue: 0.718, alpha: 1)
            : UIColor(red: 0.059, green: 0.463, blue: 0.431, alpha: 1)
    })
    static let calmAmber = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1)
            : UIColor(red: 0.706, green: 0.325, blue: 0.035, alpha: 1)
    })
    static let calmRose = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.984, green: 0.443, blue: 0.522, alpha: 1)
            : UIColor(red: 0.745, green: 0.071, blue: 0.235, alpha: 1)
    })
    static let separator = Color("Separator")

    // MARK: - Espacement (pas de 4 pt)

    static func space(_ step: Int) -> CGFloat { CGFloat(step * 4) }

    // MARK: - Rayons

    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 20

    /// Gouttière de la grille de médias plein cadre (galerie).
    static let gridGap: CGFloat = 2

    // MARK: - Élévation (cartes / sheets uniquement)

    static let shadowColor = Color.black
    static let shadowOpacity = 0.12
    static let shadowRadius: CGFloat = 12
    static let shadowY: CGFloat = 4

    // MARK: - Typographie (styles système uniquement, Dynamic Type)

    static let largeTitle = Font.system(.largeTitle, weight: .bold)
    static let title = Font.system(.title2, weight: .bold)
    static let headline = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let callout = Font.system(.callout, weight: .medium)
    static let caption = Font.system(.caption, weight: .medium)
    static let caption2 = Font.system(.caption2)
    static let monoTitle = Font.system(.title3, design: .monospaced, weight: .semibold)
    static let monoHeadline = Font.system(.headline, design: .monospaced, weight: .semibold)
    static let monoCaption = Font.system(.caption, design: .monospaced, weight: .medium)

    /// Voile sombre derri\u00e8re les compteurs pos\u00e9s sur les vignettes.
    static let scrim = Color.black.opacity(0.45)
    /// Texte lisible pos\u00e9 sur `scrim`.
    static let onScrim = Color.white

    // MARK: - Animation (ressorts cohérents, interruptibles)

    /// Entrées/sorties : ressort court, léger rebond.
    static let spring = Animation.spring(duration: 0.4, bounce: 0.15)
    /// Micro-feedback (pression) : < 250 ms.
    static let micro = Animation.easeOut(duration: 0.15)
    /// Feedback de pression des éléments tactiles.
    static let pressScale: CGFloat = 0.97
}

/// Style de bouton « pressable » : scale 0,97 au toucher, animé en 150 ms,
/// sans animation si Réduire les animations est actif.
struct DSPressableButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? DS.pressScale : 1)
            .animation(reduceMotion ? nil : DS.micro, value: configuration.isPressed)
    }
}

/// Bouton d'action principal pleine largeur ou standard, utilisant la paire
/// approuvée `DS.accent` / `DS.onAccent`.
struct DSPrimaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = DS.radiusM
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.headline)
            .foregroundStyle(isEnabled ? DS.onAccent : DS.onSurfaceMuted)
            .padding(.horizontal, DS.space(4))
            .frame(minHeight: 48)
            .background(isEnabled ? DS.accent : DS.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? DS.pressScale : 1)
            .animation(reduceMotion ? nil : DS.micro, value: configuration.isPressed)
    }
}

/// Carte système : fond `surfaceElevated`, rayon M, ombre douce unique.
struct DSCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(DS.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.radiusM))
            .shadow(color: DS.shadowColor.opacity(DS.shadowOpacity),
                    radius: DS.shadowRadius, y: DS.shadowY)
    }
}

extension View {
    func dsCard() -> some View { modifier(DSCardModifier()) }
}

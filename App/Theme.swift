import SwiftUI

/// Jetons visuels de l'interface, et leur version.
///
/// Deux révisions coexistent : `classic` reproduit l'app telle qu'elle était
/// avant la refonte, `modern` porte la nouvelle direction. Le choix se fait par
/// `uiRevision` (2 par défaut), lu **une seule fois** à la racine et injecté par
/// l'environnement : une vue qui lirait `UserDefaults` elle-même ne serait pas
/// repeinte au basculement, sans relance.
///
/// Règle de la réversion : en mode classique, l'app doit être indiscernable de
/// celle d'avant la refonte. Tout écart est un défaut, pas un détail.
struct Theme: Equatable {
    /// Clé `@AppStorage` du choix d'apparence.
    static let revisionKey = "uiRevision"
    /// 2 = nouvelle interface, valeur par défaut.
    static let defaultRevision = 2

    let revision: Int

    // Couleurs
    let background: Color
    let surface: Color
    let separator: Color
    let accent: Color
    let primaryText: Color
    let secondaryText: Color

    // Rayons
    let cornerField: CGFloat
    let cornerCard: CGFloat
    let cornerSheet: CGFloat

    // Structure
    let sourceSheetDetent: PresentationDetent
    /// Vrai quand la mise en page moderne est active : barre flottante, composeur.
    let usesFloatingToolbar: Bool

    static let accentOrange = Color.orange

    /// L'app d'avant la refonte, à l'identique.
    static let classic = Theme(
        revision: 1,
        background: Color(uiColor: .systemBackground),
        surface: Color(uiColor: .secondarySystemBackground),
        separator: Color(uiColor: .separator),
        accent: accentOrange,
        primaryText: .primary,
        secondaryText: .secondary,
        // Les rayons réels de l'existant, qui ne sont pas uniformes : 9 pour les
        // champs de recherche, 14 pour les cartes et la barre de saisie.
        cornerField: 9,
        cornerCard: 14,
        cornerSheet: 14,
        sourceSheetDetent: .height(420),
        usesFloatingToolbar: false
    )

    /// La direction retenue : fond pur, surface dense, rayons plus francs.
    static let modern = Theme(
        revision: 2,
        // Noir pur en sombre, blanc pur en clair — pas de gris de fond : c'est
        // le média qui porte la couleur, le chrome reste neutre.
        background: Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }),
        surface: Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)   // #1C1C1E
                : UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1) // #F2F2F7
        }),
        separator: Color(uiColor: .separator),
        accent: accentOrange,
        primaryText: .primary,
        secondaryText: .secondary,
        cornerField: 10,
        cornerCard: 14,
        cornerSheet: 22,
        sourceSheetDetent: .medium,
        usesFloatingToolbar: true
    )

    /// Toute valeur autre que 2 rend l'app d'avant : un réglage corrompu ou
    /// hérité d'une version future ne doit pas laisser une interface à moitié
    /// appliquée.
    static func resolved(revision: Int) -> Theme {
        revision >= 2 ? .modern : .classic
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.classic
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Ressort court, ou fondu si Réduire les animations est actif.
///
/// Centralisé : c'est le seul endroit où les durées sont décidées, et le seul
/// moyen d'être sûr qu'aucune animation n'échappe au réglage d'accessibilité.
enum Motion {
    static let selection = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let sheet = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let fade = Animation.easeInOut(duration: 0.15)

    /// Aucune animation quand le réglage système est actif, sinon `animation`.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Variante à utiliser dans `withAnimation` : un fondu très court plutôt
    /// que rien, pour que le changement d'état reste lisible.
    static func state(_ reduceMotion: Bool, _ animation: Animation = selection) -> Animation {
        reduceMotion ? fade : animation
    }
}

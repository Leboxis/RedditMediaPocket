import Foundation

/// Délais centralisés de l'app : les gardes-fou suivants étaient écrits en
/// littéraux éparpillés (30 s de garde de page en trois fichiers, 10 s de
/// scrutation, garde de 120 s des transferts par la page…). Rien de variable
/// ici — uniquement des valeurs déjà en service, regroupées pour être
/// ajustées en un seul endroit et testées hors macOS.
public enum TimingPolicy {

    /// Garde de chargement d'une page TikTok dans la WebView cachée
    /// (`TikTokVideoPageReader`, et la lecture/profil des Sauvegardés au
    /// delà de `TikTokWebPagination.navigate`).
    public static let webViewLoad: TimeInterval = 30

    /// Scrutation du JSON d'hydratation d'une page vidéo : ce pas, répété
    /// `webViewBlobAttempts` fois (`webViewBlobAttempts × webViewBlobStep`
    /// ≈ 10 s) pendant que la page peut encore hydrater son blob.
    public static let webViewBlobStep: TimeInterval = 0.5
    public static let webViewBlobAttempts: Int = 20

    /// Garde d'un appel signé lancé depuis la page (`signedFetch`).
    public static let signedFetch: TimeInterval = 25

    /// Garde du transfert d'un média par la page TikTok (`fetchMedia`).
    /// Le délai est large : les grands fichiers partent en plusieurs chunks.
    public static let mediaTransfer: TimeInterval = 120

    /// Régle URLSession des lectures réseau (HTML, JSON, médias).
    public static let networkRequest: TimeInterval = 30
    public static let networkResource: TimeInterval = 600

    /// Durée de vie maximale d'une WebView média (lectures TikTok de contenus
    /// lourds) avant fermeture forcée.
    public static let mediaWebView: TimeInterval = 300
}

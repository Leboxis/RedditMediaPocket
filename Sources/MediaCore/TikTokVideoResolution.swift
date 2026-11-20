import Foundation

/// Cascade de résolution de la page d'une vidéo TikTok isolée : une URLSession
/// directe reçoit parfois de TikTok un squelette sans JSON d'hydratation
/// (vérification silencieuse, variante mobile « ouvrir l'app ») ; la lecture
/// reprend alors dans la WebView cachée branchée sur la session, présentée
/// desktop puis mobile. Logique testable hors macOS : l'ordre, les UA et
/// l'UA retenu pour les transferts média n'ont pas à être répétables à la main.
public enum TikTokVideoResolution {

    /// Une tentative de la cascade. `desktop` décrit le client présenté à
    /// TikTok (faux = UA iPhone, réellement servi par la WebView) ; `userAgent`
    /// est l'UA exact de cette tentative : celui qui obtient la page doit
    /// aussi porter les requêtes des médias, les URL CDN le vérifiant.
    public struct Attempt: Equatable, Sendable {
        public let desktop: Bool
        public let userAgent: String

        public init(desktop: Bool, userAgent: String) {
            self.desktop = desktop
            self.userAgent = userAgent
        }
    }

    /// Cascade complète : la tentative directe d'abord (URLSession, UA
    /// desktop), puis les relectures dans la WebView cachée (desktop, puis
    /// iPhone). L'ordre n'est pas décoratif : TikTok accepte le client desktop
    /// direct quand il veut bien servir la page, la WebView desktop couvre le
    /// cas « exige un navigateur », et la forme iPhone est la dernière issue
    /// quand même la WebView desktop reçoit un squelette.
    public static func cascade(directUserAgent: String, mobileUserAgent: String) -> [Attempt] {
        [
            Attempt(desktop: true, userAgent: directUserAgent),
            Attempt(desktop: true, userAgent: directUserAgent),
            Attempt(desktop: false, userAgent: mobileUserAgent),
        ]
    }

    /// La première tentative (index 0) est la demande directe ; les suivantes
    /// relisent la page dans la WebView cachée.
    public static func isDirectAttempt(_ index: Int) -> Bool { index == 0 }

    /// UA retenu pour les transferts média : celui de la tentative qui a
    /// obtenu la page lisible. Les URL CDN de TikTok refusent l'UA qui ne
    /// correspond pas à la demande initiale.
    public static func mediaUserAgent(for attempt: Attempt) -> String { attempt.userAgent }
}

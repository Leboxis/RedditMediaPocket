import Foundation

/// Relance bornée sur erreur transitoire (réseau mobile instable) : trois
/// essais au total, puis abandon. L'attente double entre chaque nouvel essai.
///
/// Un 429 n'est jamais réessayé : `Network.check` le convertit déjà en
/// `NetworkError.limited`, qui doit rester fatal pour la session entière.
/// L'annulation ne l'est pas davantage : elle vient de l'utilisateur, elle se
/// propage telle quelle.
public enum RetryPolicy {
    /// Nombre de relances au-delà du premier essai.
    public static let maximumExtraAttempts = 2

    /// Vrai si `error` mérite un nouvel essai, `attempt` étant le nombre de
    /// relances déjà accordées (0 avant le premier).
    public static func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard attempt < maximumExtraAttempts else { return false }
        guard !DownloadFailurePolicy.isCancellation(error) else { return false }
        return DownloadFailurePolicy.isTransient(error)
    }

    /// Attente avant la relance numéro `attempt` (1 puis 2) : 2 s puis 4 s.
    public static func delay(forAttempt attempt: Int) -> Duration {
        .seconds(1 << max(1, attempt))
    }
}
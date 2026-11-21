import Foundation
import MediaCore

/// Erreurs du client API, sans dépendance tierce.
public enum APIError: Error, Sendable {
    /// La réponse n'est pas une réponse HTTP exploitable.
    case invalidResponse
    /// Code HTTP hors 2xx. Le message vient, si possible, du champ « erreur » du serveur.
    case httpError(statusCode: Int, message: String?)
    /// Échec de transport (hors ligne, délai dépassé, annulation…).
    case transport(URLError)
    /// Le corps reçu ne correspond pas au modèle attendu.
    case decoding(Error)
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L("Réponse serveur invalide.", "Invalid server response.")
        case .httpError(let statut, let message):
            if let message, !message.isEmpty { return message }
            return L("Erreur HTTP \(statut).", "HTTP error \(statut).")
        case .transport(let erreur):
            switch erreur.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return L("Pas de connexion Internet.", "No Internet connection.")
            case .timedOut:
                return L("La demande a expiré.", "The request timed out.")
            case .cancelled:
                return L("Demande annulée.", "Request cancelled.")
            default:
                return erreur.localizedDescription
            }
        case .decoding:
            return L("Données reçues invalides.", "Invalid data received.")
        }
    }
}

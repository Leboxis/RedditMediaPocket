import Foundation

public enum NetworkError: LocalizedError {
    case refused(Int), limited(service: String, until: Date?), invalid(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let code):
            return L("Accès refusé par le serveur (HTTP \(code)).", "Server denied access (HTTP \(code)).")
        case .limited(let service, _):
            return L("\(service) : limite de requêtes atteinte (HTTP 429).", "\(service): request limit reached (HTTP 429).")
        case .invalid(let message): return message
        }
    }
}

public enum DownloadFailurePolicy {
    public static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Missing media may be skipped; a service limit must abort the page so
    /// its unprocessed posts are not committed to the visited history.
    /// Décision Jev A bug 9 : un échec passager (réseau coupé, 408/5xx) doit
    /// interrompre la page pour être réessayé, pas être marqué vu.
    public static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                    .secureConnectionFailed].contains(urlError.code)
        }
        if case NetworkError.refused(let code) = error {
            return code == 408 || (500...599).contains(code)
        }
        return false
    }

    public static func attempt(_ operation: () async throws -> Void) async throws -> Bool {
        do {
            try await operation()
            return true
        } catch {
            try Task.checkCancellation()
            if isCancellation(error) { throw error }
            if case NetworkError.limited = error { throw error }
            if isTransient(error) { throw error }
            return false
        }
    }
}

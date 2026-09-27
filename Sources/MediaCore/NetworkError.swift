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
    /// Missing media may be skipped; a service limit must abort the page so
    /// its unprocessed posts are not committed to the visited history.
    public static func attempt(_ operation: () async throws -> Void) async throws -> Bool {
        do {
            try await operation()
            return true
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if case NetworkError.limited = error { throw error }
            return false
        }
    }
}

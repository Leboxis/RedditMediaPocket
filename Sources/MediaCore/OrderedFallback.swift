import Foundation

/// Essaie des candidats dans l'ordre ; le premier succès gagne.
/// Politique : une annulation, une limite serveur (429) ou un échec
/// passager (réseau instable, 408/5xx) remonte immédiatement — tenter
/// un candidat inférieur ou compter « inaccessible » serait faux. Tout
/// autre refus (403/404/410…) passe au candidat suivant ; si tous
/// échouent, la dernière erreur est relancée.
public enum OrderedFallback {
    public static func first<Item: Sendable>(_ items: [Item],
        operation: @escaping @Sendable (Item) async throws -> URL) async throws -> URL {
        guard !items.isEmpty else {
            throw NetworkError.invalid(L("Aucun média disponible.", "No media available."))
        }
        var lastError: Error?
        for item in items {
            do {
                return try await operation(item)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let networkError = error as? NetworkError, case .limited = networkError { throw error }
                if DownloadFailurePolicy.isTransient(error) { throw error }
                lastError = error
            }
        }
        throw lastError ?? NetworkError.invalid(L("Aucun média disponible.", "No media available."))
    }
}

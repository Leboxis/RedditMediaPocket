import Foundation
import Security

/// Une clé embarquée dans un binaire reste extractible : acceptable ici pour des données peu sensibles.
public enum KeychainError: Error, Sendable {
    /// Opération Keychain refusée par le système (code OSStatus).
    case statut(OSStatus)
}

/// Stockage de la clé API dans le Keychain (jamais dans UserDefaults ni dans le code).
public enum KeychainStore {
    public static let service = "mon-api"
    public static let account = "api-key"

    /// Politique d'accès : disponible après premier déverrouillage, uniquement sur cet appareil.
    private static let accessibilite = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Lit la clé. Renvoie nil si elle n'est pas encore enregistrée.
    public static func get() -> String? {
        let requete: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var element: CFTypeRef?
        let statut = SecItemCopyMatching(requete as CFDictionary, &element)
        guard statut == errSecSuccess, let donnees = element as? Data else { return nil }
        return String(data: donnees, encoding: .utf8)
    }

    /// Écrit ou remplace la clé (ajout puis mise à jour en cas de doublon).
    public static func set(_ valeur: String) throws {
        let identite: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let donnees = Data(valeur.utf8)
        var ajout = identite
        ajout[kSecValueData] = donnees
        ajout[kSecAttrAccessible] = accessibilite

        switch SecItemAdd(ajout as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let statut = SecItemUpdate(
                identite as CFDictionary,
                [kSecValueData: donnees] as CFDictionary
            )
            guard statut == errSecSuccess else { throw KeychainError.statut(statut) }
        case let statut:
            throw KeychainError.statut(statut)
        }
    }

    /// Supprime la clé. Une clé déjà absente est considérée comme une réussite.
    public static func delete() throws {
        let requete: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let statut = SecItemDelete(requete as CFDictionary)
        guard statut == errSecSuccess || statut == errSecItemNotFound else {
            throw KeychainError.statut(statut)
        }
    }
}

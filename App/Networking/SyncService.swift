import Foundation
import MediaCore

/// Synchronise toutes les données non secrètes avec le Worker Cloudflare.
/// Les changements sont regroupés par un anti-rebond de 1,5 s pour éviter les envois en rafale.
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published private(set) var etat = L("Non synchronisé", "Not synced")
    @Published private(set) var derniereSynchronisation: Date?

    private let client: ItemsAPIClientProtocol
    private var tacheAntiRebond: Task<Void, Never>?
    private var observateurs: [NSObjectProtocol] = []
    private var demarre = false
    private var restaurationRecente = false

    init(client: ItemsAPIClientProtocol = ItemsAPIClient()) {
        self.client = client
    }

    /// À appeler au lancement : restaure d'abord, puis surveille les changements.
    func demarrer() async {
        guard !demarre else { return }
        demarre = true
        await restaurer()
        observerLesChangements()
    }

    private func observerLesChangements() {
        observateurs.append(
            NotificationCenter.default.addObserver(
                forName: .pocketDonneesDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.planifierSynchronisation() }
            }
        )
    }

    /// Programme un envoi groupé après une courte attente.
    func planifierSynchronisation() {
        guard !restaurationRecente else { return }
        tacheAntiRebond?.cancel()
        tacheAntiRebond = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await synchroniser()
        }
    }

    /// Envoie l'état complet au serveur (création au premier lancement, mise à jour ensuite).
    func synchroniser() async {
        guard let donnees = PocketSnapshot.capturer().jsonValue else {
            etat = L("Préparation impossible", "Preparation failed")
            return
        }
        let brouillon = ItemDraft(
            name: "suivis",
            type: TypeItem.suivi.rawValue,
            description: L("Comptes Reddit suivis et dates", "Followed Reddit accounts and dates"),
            data: donnees
        )
        do {
            let page = try await client.list(type: TypeItem.suivi.rawValue, search: "suivis", page: 1, limit: 20)
            if let existant = page.items.first(where: { $0.name == "suivis" }) {
                _ = try await client.update(id: existant.id, brouillon)
            } else {
                _ = try await client.create(brouillon)
            }
            etat = L("Synchronisé", "Synced")
            derniereSynchronisation = Date()
        } catch {
            etat = L("Erreur : \(error.localizedDescription)", "Error: \(error.localizedDescription)")
        }
    }

    /// Récupère la copie distante et l'applique (utile après réinstallation).
    func restaurer() async {
        restaurationRecente = true
        defer {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.restaurationRecente = false
            }
        }
        do {
            let page = try await client.list(type: TypeItem.suivi.rawValue, search: "suivis", page: 1, limit: 20)
            guard let element = page.items.first(where: { $0.name == "suivis" }),
                  let octets = element.data?.donneesJSON(),
                  let copie = try? JSONDecoder().decode(PocketSnapshot.self, from: octets) else {
                etat = L("Aucune sauvegarde distante", "No remote backup")
                return
            }
            copie.appliquer()
            etat = L("Données restaurées", "Data restored")
            derniereSynchronisation = Date()
            NotificationCenter.default.post(name: .pocketDonneesRestaurees, object: nil)
        } catch {
            etat = L("Restauration impossible", "Restore failed")
        }
    }
}

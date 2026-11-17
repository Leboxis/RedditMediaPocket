import Foundation

/// File illimitée producteur/consommateur, thread-safe sans acteur.
///
/// Remplace les lots discrets du parcours X : le producteur (lecture des
/// pages) dépose chaque média préparé, des consommateurs (transferts) le
/// vident en continu. Un créneau se libère dès qu'un média finit — une vidéo
/// lente n'immobilise plus les suivantes, et la pagination continue pendant
/// les transferts au lieu de s'arrêter à chaque frontière de lot.
///
/// `next()` est sensible à l'annulation : seul le consommateur annulé est
/// réveillé avec `nil`, les autres continuent de servir la file.
public final class ConcurrentChannel<Item: Sendable>: Sendable {
    /// État protégé par `lock` : file d'attente, consommateurs suspendus,
    /// drapeau de fermeture. `@unchecked Sendable` car tout accès passe par
    /// le verrou, jamais par l'isolement d'acteur.
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var items: [Item] = []
        var waiters: [Int64: CheckedContinuation<Item?, Never>] = [:]
        var nextID: Int64 = 0
        var finished = false
    }

    private let storage = Storage()

    public init() {}

    /// Dépose un média. Réveille un consommateur suspendu si la file était
    /// vide, sinon met en file. Ignoré après `finish()`.
    public func send(_ item: Item) {
        let storage = self.storage
        storage.lock.lock()
        if storage.finished { storage.lock.unlock(); return }
        if let id = storage.waiters.keys.first {
            let waiter = storage.waiters.removeValue(forKey: id)
            storage.lock.unlock()
            waiter?.resume(returning: item)
            return
        }
        storage.items.append(item)
        storage.lock.unlock()
    }

    /// Ferme le canal : les consommateurs en attente reçoivent `nil` et les
    /// suivants aussi une fois la file vidée. Idempotent.
    public func finish() {
        let storage = self.storage
        storage.lock.lock()
        storage.finished = true
        let waiters = storage.waiters
        storage.waiters.removeAll()
        storage.lock.unlock()
        for waiter in waiters.values { waiter.resume(returning: nil) }
    }

    /// Média suivant, ou `nil` une fois le canal fermé et vidé.
    public func next() async -> Item? {
        let storage = self.storage
        storage.lock.lock()
        if let item = storage.items.first {
            storage.items.removeFirst()
            storage.lock.unlock()
            return item
        }
        if storage.finished { storage.lock.unlock(); return nil }
        storage.lock.unlock()
        let ref = WaiterRef()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                storage.lock.lock()
                if let item = storage.items.first {
                    storage.items.removeFirst()
                    storage.lock.unlock()
                    continuation.resume(returning: item)
                    return
                }
                if storage.finished || Task.isCancelled {
                    storage.lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                let id = storage.nextID
                storage.nextID += 1
                storage.waiters[id] = continuation
                storage.lock.unlock()
                ref.set(id)
                // Ferme la fenêtre où l'annulation est survenue entre la
                // vérification sous verrou et l'enregistrement du serveur :
                // `onCancel` n'a rien trouvé à réveiller, le consommateur se
                // rétracte lui-même.
                if Task.isCancelled { self.cancelWaiter(id) }
            }
        } onCancel: {
            if let id = ref.get() { self.cancelWaiter(id) }
        }
    }

    /// Rétracte un consommateur précis. Idempotent : un identifiant absent a
    /// déjà été servi (élément reçu, canal fermé ou annulation précédente).
    private func cancelWaiter(_ id: Int64) {
        let storage = self.storage
        storage.lock.lock()
        let waiter = storage.waiters.removeValue(forKey: id)
        storage.lock.unlock()
        waiter?.resume(returning: nil)
    }

    /// Identifiant du consommateur courant, partagé entre le corps de
    /// `next()` et son gestionnaire d'annulation.
    private final class WaiterRef: @unchecked Sendable {
        private let lock = NSLock()
        private var id: Int64?

        func set(_ value: Int64) {
            lock.lock(); id = value; lock.unlock()
        }

        func get() -> Int64? {
            lock.lock(); defer { lock.unlock() }
            return id
        }
    }
}

import Foundation

/// Sélection par glissement en plage dans une grille carrée (style Photos iOS).
///
/// Retient l'ancre et la sélection initiale (`baseline`) afin qu'un aller-retour
/// du doigt ajoute puis retire proprement les éléments intermédiaires sans
/// perdre ceux qui étaient déjà cochés avant le geste.
public struct GalleryDragSelection<Item: Hashable & Sendable>: Sendable {
    public let anchorIndex: Int
    public let addsToSelection: Bool
    public let baseline: Set<Item>
    public private(set) var lastIndex: Int

    public init?(items: [Item], anchorIndex: Int, initialSelection: Set<Item>) {
        guard items.indices.contains(anchorIndex) else { return nil }
        self.anchorIndex = anchorIndex
        self.baseline = initialSelection
        self.addsToSelection = !initialSelection.contains(items[anchorIndex])
        self.lastIndex = anchorIndex
    }

    /// Résout l'index d'une cellule dans une grille régulière à `columns`
    /// colonnes carrées espacées de `spacing`. Hors borne, retourne `nil` au
    /// départ du geste (`clampToBounds == false`) pour éviter de démarrer dans
    /// le vide sous une dernière rangée incomplète, et borne ensuite sur la
    /// cellule la plus proche pendant la glissade.
    public static func itemIndex(
        x: Double,
        y: Double,
        gridWidth: Double,
        columns: Int = 3,
        spacing: Double = 2,
        count: Int,
        clampToBounds: Bool = false
    ) -> Int? {
        guard columns > 0, count > 0, gridWidth > 0 else { return nil }
        let cellSide = (gridWidth - spacing * Double(columns - 1)) / Double(columns)
        guard cellSide > 0 else { return nil }
        let step = cellSide + spacing
        if !clampToBounds, x < 0 || x >= gridWidth || y < 0 { return nil }
        let col = min(columns - 1, max(0, Int(floor(x / step))))
        let row = max(0, Int(floor(y / step)))
        let index = row * columns + col
        if clampToBounds { return min(count - 1, index) }
        return index < count ? index : nil
    }

    /// Recalcule `selection` pour couvrir toute la plage `[anchorIndex, targetIndex]`.
    /// Retourne `true` lorsque la cellule survolée change d'index.
    @discardableResult
    public mutating func update(
        to targetIndex: Int,
        items: [Item],
        selection: inout Set<Item>
    ) -> Bool {
        guard !items.isEmpty, items.indices.contains(anchorIndex) else { return false }
        let clamped = min(max(0, targetIndex), items.count - 1)
        let lower = min(anchorIndex, clamped)
        let upper = max(anchorIndex, clamped)
        var updated = baseline
        for index in lower...upper {
            if addsToSelection {
                updated.insert(items[index])
            } else {
                updated.remove(items[index])
            }
        }
        let changed = clamped != lastIndex
        lastIndex = clamped
        if selection != updated { selection = updated }
        return changed
    }
}

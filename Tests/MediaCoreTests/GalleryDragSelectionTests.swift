import XCTest
@testable import MediaCore

final class GalleryDragSelectionTests: XCTestCase {
    func testItemIndexMapsCoordinatesAcrossColumnsAndRows() {
        // Largeur 374 = 3 cellules carrées de 123,33… espacées de 2 pt (pas ~ 125,33).
        let width = 374.0
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: 10, y: 10, gridWidth: width, count: 7), 0)
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: 130, y: 10, gridWidth: width, count: 7), 1)
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: 360, y: 10, gridWidth: width, count: 7), 2)
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: 10, y: 130, gridWidth: width, count: 7), 3)
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: 10, y: 260, gridWidth: width, count: 7), 6)

        // Emplacement vide sur la dernière ligne incomplète : ignoré au départ,
        // rabattu sur le dernier élément pendant un glissement actif.
        XCTAssertNil(GalleryDragSelection<Int>.itemIndex(x: 260, y: 260, gridWidth: width, count: 7, clampToBounds: false))
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: 260, y: 260, gridWidth: width, count: 7, clampToBounds: true), 6)

        // Bords négatifs et droite : ignorés au départ, bornés ensuite.
        XCTAssertNil(GalleryDragSelection<Int>.itemIndex(x: -5, y: 10, gridWidth: width, count: 7, clampToBounds: false))
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: -5, y: -5, gridWidth: width, count: 7, clampToBounds: true), 0)
        XCTAssertNil(GalleryDragSelection<Int>.itemIndex(x: 400, y: 10, gridWidth: width, count: 7, clampToBounds: false))
        XCTAssertEqual(GalleryDragSelection<Int>.itemIndex(x: 400, y: 10, gridWidth: width, count: 7, clampToBounds: true), 2)

        XCTAssertNil(GalleryDragSelection<Int>.itemIndex(x: 10, y: 10, gridWidth: 0, count: 7))
        XCTAssertNil(GalleryDragSelection<Int>.itemIndex(x: 10, y: 10, gridWidth: width, count: 0))
    }

    func testDragSelectsRangePreservesBaselineAndSupportsReversal() throws {
        let items = Array(0..<9)
        var selection: Set<Int> = [0, 7]
        var session = try XCTUnwrap(GalleryDragSelection(items: items, anchorIndex: 2, initialSelection: selection))
        XCTAssertTrue(session.addsToSelection)

        XCTAssertFalse(session.update(to: 2, items: items, selection: &selection))
        XCTAssertEqual(selection, [0, 2, 7])

        XCTAssertTrue(session.update(to: 5, items: items, selection: &selection))
        XCTAssertEqual(selection, [0, 2, 3, 4, 5, 7])

        // Retour en arrière sans lever le doigt : 4 et 5 sont retirés, 0 et 7 restent.
        XCTAssertTrue(session.update(to: 3, items: items, selection: &selection))
        XCTAssertEqual(selection, [0, 2, 3, 7])
    }

    func testDragFromSelectedAnchorDeselectsRangeAndAllowsReversal() throws {
        let items = Array(0..<6)
        var selection: Set<Int> = [0, 1, 2, 3, 5]
        var session = try XCTUnwrap(GalleryDragSelection(items: items, anchorIndex: 3, initialSelection: selection))
        XCTAssertFalse(session.addsToSelection)

        XCTAssertTrue(session.update(to: 1, items: items, selection: &selection))
        XCTAssertEqual(selection, [0, 5])

        // En glissant vers 2, l'élément 1 retrouve sa coche initiale.
        XCTAssertTrue(session.update(to: 2, items: items, selection: &selection))
        XCTAssertEqual(selection, [0, 1, 5])
    }

    func testInvalidAnchorReturnsNil() {
        XCTAssertNil(GalleryDragSelection(items: [1, 2], anchorIndex: 2, initialSelection: []))
        XCTAssertNil(GalleryDragSelection(items: [Int](), anchorIndex: 0, initialSelection: []))
    }
}

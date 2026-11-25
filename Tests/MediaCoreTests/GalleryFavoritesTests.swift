import XCTest
@testable import MediaCore

final class GalleryFavoritesTests: XCTestCase {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    func testKeyUsesStandardizedPath() {
        let plain = url("/tmp/pocket/r.pics/media.jpg")
        XCTAssertEqual(GalleryFavorites.key(for: plain), plain.standardizedFileURL.path)
    }

    func testToggleAddsThenRemoves() {
        var favorites: Set<String> = []
        let media = url("/tmp/pocket/r.pics/a.jpg")
        XCTAssertTrue(GalleryFavorites.toggle(&favorites, media))
        XCTAssertTrue(GalleryFavorites.isFavorite(favorites, media))
        XCTAssertFalse(GalleryFavorites.toggle(&favorites, media))
        XCTAssertFalse(GalleryFavorites.isFavorite(favorites, media))
        XCTAssertTrue(favorites.isEmpty)
    }

    func testFilterKeepsEverythingWhenDisabled() {
        let files = [url("/tmp/pocket/a.jpg"), url("/tmp/pocket/b.mp4")]
        let favorites: Set<String> = [GalleryFavorites.key(for: files[0])]
        XCTAssertEqual(GalleryFavorites.filter(files, favorites: favorites, onlyFavorites: false), files)
    }

    func testFilterOnlyFavoritesKeepsMatchingOnes() {
        let files = [url("/tmp/pocket/a.jpg"), url("/tmp/pocket/b.mp4"), url("/tmp/pocket/c.jpg")]
        let favorites: Set<String> = [GalleryFavorites.key(for: files[0]), GalleryFavorites.key(for: files[2])]
        XCTAssertEqual(GalleryFavorites.filter(files, favorites: favorites, onlyFavorites: true), [files[0], files[2]])
    }

    func testEncodeDecodeRoundTrip() throws {
        let favorites: Set<String> = ["/tmp/pocket/a.jpg", "/tmp/pocket/b.mp4"]
        let data = try GalleryFavorites.encode(favorites)
        XCTAssertEqual(try GalleryFavorites.decode(data), favorites)
    }

    func testDecodeEmptyArray() throws {
        let data = try JSONEncoder().encode([String]())
        XCTAssertTrue(try GalleryFavorites.decode(data).isEmpty)
    }
}

import XCTest
@testable import MediaCore

/// Routes de sauvegardés TikTok réellement servies par le site.
///
/// Constat réseau du 19/11/2026, sans session et avec session : `tiktok.com`
/// redirige `/saved`, `/favorites`, `/bookmarks` et `/collections` vers
/// `/404?fromUrl=…` (HTTP 302). Aucune page Enregistrés n'est servie : les
/// sauvegardés n'existent que par les routes API signées.
final class TikTokSavedRoutesTests: XCTestCase {
    func testKnownDeadPathsAreRejected() {
        for path in ["/saved", "/favorites", "/bookmarks", "/collections",
                     "/saved/", "/Collections"] {
            XCTAssertTrue(TikTokAPI.isDeadSavedPath(path),
                          "\(path) redirige vers la page 404 et doit être refusé")
        }
    }

    func testProfilePathIsNotDead() {
        XCTAssertFalse(TikTokAPI.isDeadSavedPath("/@someuser"))
        XCTAssertFalse(TikTokAPI.isDeadSavedPath("/"))
        XCTAssertFalse(TikTokAPI.isDeadSavedPath("/@someuser/video/123"))
    }

    /// Le segment n'est comparé qu'en entier : un pseudo qui contient le mot
    /// ne doit pas être écarté comme une page morte.
    func testPathContainingWordIsNotDead() {
        XCTAssertFalse(TikTokAPI.isDeadSavedPath("/@saved"))
        XCTAssertFalse(TikTokAPI.isDeadSavedPath("/@collections"))
        XCTAssertFalse(TikTokAPI.isDeadSavedPath("/saved/videos/"))
    }

    /// La route documentaire reste celle du site, même si elle redirige : la
    /// corriger un jour se fera ici, sans changer les appelants.
    func testSavedURLCanonical() {
        XCTAssertEqual(TikTokAPI.savedURL().absoluteString, "https://www.tiktok.com/saved")
    }
}

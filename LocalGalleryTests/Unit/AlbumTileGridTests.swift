import XCTest
@testable import LocalGallery

/// The album tile grid's two derived decisions.
///
/// Both are pure functions of the folder tree, and both are load-bearing:
///
/// * `AlbumGridRules.destination(for:)` decides whether tapping a folder
///   shows its photos directly or shows a browser listing its subfolders.
///   It has to match the rule the widget's folder deep-link uses, or the
///   same folder opens on two different screens depending on how the user
///   arrived.
/// * `AlbumGridRules.makePhotosAlbum(for:…)` decides what the "Photos"
///   tile shows and whether it is shown at all. At the library root the
///   tile stands for the whole library, not the root folder's own
///   (usually empty) photos.
final class AlbumTileGridTests: XCTestCase {

    private func photo(_ name: String) -> PhotoFile {
        PhotoFile.fixture(url: URL(fileURLWithPath: "/library/\(name).jpg"))
    }

    // MARK: - Destination

    func testALeafFolderWithPhotosOpensItsGrid() {
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/Holiday"),
            name: "Holiday",
            photos: [photo("a"), photo("b")]
        )
        XCTAssertEqual(AlbumGridRules.destination(for: folder), .grid)
    }

    func testAFolderWithSubfoldersOpensItsBrowser() {
        // It has photos of its own *and* subfolders. The grid would hide
        // the subfolders, so the browser shows both.
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/Trip"),
            name: "Trip",
            photos: [photo("a")],
            subfolders: [PhotoFolder.fixture(url: URL(fileURLWithPath: "/library/Trip/Day1"), name: "Day1")]
        )
        XCTAssertEqual(AlbumGridRules.destination(for: folder), .browser)
    }

    func testAnEmptyFolderOpensItsBrowser() {
        // Nothing to show in a grid — the browser is the only honest view.
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/Empty"),
            name: "Empty"
        )
        XCTAssertEqual(AlbumGridRules.destination(for: folder), .browser)
    }

    func testAFolderWithOnlySubfoldersOpensItsBrowser() {
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/OnlySubs"),
            name: "OnlySubs",
            subfolders: [PhotoFolder.fixture(url: URL(fileURLWithPath: "/library/OnlySubs/A"), name: "A")]
        )
        XCTAssertEqual(AlbumGridRules.destination(for: folder), .browser)
    }

    // MARK: - The "Photos" album tile

    func testTheLibraryRootTileStandsForTheWholeLibrary() {
        // The root folder usually holds no photos of its own, but the tile
        // still appears — it is the way into the Photos tab, and it is
        // counted against the whole library.
        let root = PhotoFolder.fixture(url: URL(fileURLWithPath: "/library"), name: "library")
        let album = AlbumGridRules.makePhotosAlbum(
            for: root,
            isLibraryRoot: true,
            libraryPhotoCount: 431
        )
        XCTAssertEqual(album?.title, "All Photos")
        XCTAssertEqual(album?.count, 431)
    }

    func testAnEmptyLibraryHasNoAllPhotosTile() {
        // "All Photos · 0 photos" is a dead end — the tile is not shown,
        // and the folder's own empty state says the same thing better.
        let root = PhotoFolder.fixture(url: URL(fileURLWithPath: "/library"), name: "library")
        let album = AlbumGridRules.makePhotosAlbum(
            for: root,
            isLibraryRoot: true,
            libraryPhotoCount: 0
        )
        XCTAssertNil(album)
    }

    func testTheLibraryRootTileUsesTheRootCover() {
        // The root's cover may come from a subfolder — the core resolves
        // it that way — and that is still the representative image.
        let cover = URL(fileURLWithPath: "/library/sub/cover.jpg")
        let root = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library"),
            name: "library",
            coverPhotoURL: cover
        )
        let album = AlbumGridRules.makePhotosAlbum(
            for: root,
            isLibraryRoot: true,
            libraryPhotoCount: 1
        )
        XCTAssertEqual(album?.coverURL, cover)
    }

    func testAChildFolderTileIsItsOwnPhotos() {
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/Holiday"),
            name: "Holiday",
            photos: [photo("a"), photo("b"), photo("c")]
        )
        let album = AlbumGridRules.makePhotosAlbum(
            for: folder,
            isLibraryRoot: false,
            libraryPhotoCount: 999
        )
        XCTAssertEqual(album?.title, "Holiday")
        // The folder's own photos, not the library's count.
        XCTAssertEqual(album?.count, 3)
    }

    func testAChildFolderWithNoPhotosHasNoAlbumTile() {
        // A folder whose photos all live in subfolders has no "Photos"
        // tile of its own — the subfolder tiles cover it.
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/OnlySubs"),
            name: "OnlySubs",
            subfolders: [PhotoFolder.fixture(url: URL(fileURLWithPath: "/library/OnlySubs/A"), name: "A")]
        )
        let album = AlbumGridRules.makePhotosAlbum(
            for: folder,
            isLibraryRoot: false,
            libraryPhotoCount: 12
        )
        XCTAssertNil(album)
    }

    func testAChildFolderTileFallsBackToItsFirstPhotoForTheCover() {
        // `coverPhotoURL` is normally set by the scan; when it is missing,
        // the folder's own first photo is a better cover than nothing.
        let only = photo("a")
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/Holiday"),
            name: "Holiday",
            photos: [only],
            coverPhotoURL: nil
        )
        // The fixture defaults `coverPhotoURL` to the first photo, so
        // clear it to exercise the fallback the view relies on.
        var bare = folder
        bare.coverPhotoURL = nil
        let album = AlbumGridRules.makePhotosAlbum(
            for: bare,
            isLibraryRoot: false,
            libraryPhotoCount: 1
        )
        XCTAssertEqual(album?.coverURL, only.url)
    }
}

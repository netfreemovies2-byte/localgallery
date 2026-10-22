import SwiftUI

/// The album grid's pure decisions.
///
/// Deliberately a *plain* type rather than members of the `View`: the
/// rules below are pure functions of the folder tree, and the repo's
/// established pattern for a pure, testable decision that lives next to
/// the view that draws it is a top-level struct (`PhotoSection` for the
/// month grouping). Keeping them here also keeps them callable from a
/// test's non-isolated context without an actor hop.
enum AlbumGridRules {
    /// The tile that stands for "the photos here".
    struct PhotosAlbum: Sendable {
        let title: String
        let count: Int
        let coverURL: URL?
    }

    /// Where a subfolder tile leads. A folder with photos of its own and
    /// no subfolders opens straight into the photo grid; anything else
    /// opens its own browser, so a folder that holds both photos and
    /// subfolders shows both rather than hiding one behind a tap.
    enum Destination: Equatable {
        case grid
        case browser
    }

    /// The destination for a subfolder tile. Pure so the rule can be
    /// pinned in a test — it is the same rule the widget's folder
    /// deep-link applies, and a divergence between the two would send
    /// the user to a different screen depending on how they arrived.
    static func destination(for folder: PhotoFolder) -> Destination {
        folder.subfolders.isEmpty && !folder.photos.isEmpty ? .grid : .browser
    }

    /// The "Photos" album tile for a folder, or `nil` when the folder has
    /// no photos of its own (in which case the tile is not shown at all).
    ///
    /// At the library root the album stands for the *whole library* — the
    /// Photos tab already shows it — so it is titled "All Photos" and
    /// counted against the whole library rather than the root folder's
    /// own (usually empty) photos.
    ///
    /// An empty library gets no tile at all: "All Photos · 0 photos" is a
    /// dead end, and the folder's own empty state says the same thing
    /// better.
    ///
    /// The cover is the folder's `coverPhotoURL`, which the scan already
    /// resolved: the folder's first photo, or — for a folder whose photos
    /// all live in subfolders — the first subfolder that has one. Either
    /// way it is representative of what the tile opens.
    static func makePhotosAlbum(
        for folder: PhotoFolder,
        isLibraryRoot: Bool,
        libraryPhotoCount: Int
    ) -> PhotosAlbum? {
        if isLibraryRoot {
            guard libraryPhotoCount > 0 else { return nil }
            return PhotosAlbum(
                title: "All Photos",
                count: libraryPhotoCount,
                coverURL: folder.coverPhotoURL
            )
        }
        guard !folder.photos.isEmpty else { return nil }
        return PhotosAlbum(
            title: folder.name,
            count: folder.photos.count,
            coverURL: folder.coverPhotoURL ?? folder.photos.first?.url
        )
    }
}

/// Album-style tiles for the Folders tab.
///
/// The Folders tab used to be a plain `List` with a `Label("N photos in this
/// folder")` row and 72pt thumbnails. That is a *file browser*, not an
/// album browser: it gives no visual sense of what is in a folder, and the
/// folder's own photos were behind an extra tap with no preview at all.
///
/// This is the tile grid that replaces it: a cover thumbnail, the folder
/// name, the photo count, and — for a folder with its own photos — a direct
/// route into the grid. Subfolders and the folder's own photos are both
/// represented, so a folder that contains both is not split across two
/// disconnected lists.
struct AlbumTileGrid: View {
    /// The folder being browsed.
    let folder: PhotoFolder
    /// The "Photos" album tile: the photos this screen opens directly.
    /// `nil` when the folder holds no photos of its own.
    var photosAlbum: AlbumGridRules.PhotosAlbum? = nil
    /// Subfolders, already sorted by the Store's sort order.
    let subfolders: [PhotoFolder]
    /// True when this grid is the library root. The root's "Photos" album
    /// is the *whole library*, not the root folder's own (usually empty)
    /// photos — so it routes to the Photos tab instead of a grid.
    var isLibraryRoot: Bool = false

    @Environment(AppRouter.self) private var router

    /// Horizontal padding around the grid — matches the photo grid's own.
    private static let horizontalPadding: CGFloat = 16
    /// Gap between tiles.
    private static let spacing: CGFloat = 14
    /// Target tile width. The column count is derived from the available
    /// width, so the tiles stay a sensible size on a phone, an iPad and in
    /// a split view without three different layouts.
    private static let targetTileWidth: CGFloat = 165

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - Self.horizontalPadding * 2
            let columns = max(2, Int((available + Self.spacing) / (Self.targetTileWidth + Self.spacing)))
            // Rounded to whole points: the width is a decode size for the
            // thumbnail service, and a fractional one asks ImageIO for a
            // pixel size it will round anyway — while making the cover
            // cache key differ from the neighbouring tile's for no reason.
            let tileWidth = ((available - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
                .rounded()

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Self.spacing), count: columns),
                    alignment: .leading,
                    spacing: 18
                ) {
                    if let album = photosAlbum {
                        Section {
                            AlbumTile(
                                title: album.title,
                                subtitle: photoCountLabel(album.count),
                                coverURL: album.coverURL,
                                width: tileWidth
                            ) {
                                openPhotos()
                            }
                        } header: {
                            AlbumSectionHeader(title: "Photos")
                        }
                    }

                    if !subfolders.isEmpty {
                        Section {
                            ForEach(subfolders) { subfolder in
                                AlbumTile(
                                    title: subfolder.name,
                                    subtitle: photoCountLabel(subfolder.totalPhotoCount),
                                    coverURL: subfolder.coverPhotoURL,
                                    width: tileWidth
                                ) {
                                    open(subfolder)
                                }
                            }
                        } header: {
                            AlbumSectionHeader(title: "Folders")
                        }
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .softTopScrollEdge()
        }
    }

    /// Open the "Photos" album. At the library root that is the whole
    /// library, which the Photos tab already shows; deeper down it is the
    /// folder's own photos.
    private func openPhotos() {
        if isLibraryRoot {
            router.selectedTab = .photos
        } else {
            router.foldersPath.append(.grid(folder))
        }
    }

    /// Open a subfolder: straight into its grid when it is a leaf, and
    /// into its own browser when it has folders of its own. The same
    /// rule the widget's folder deep-link uses.
    private func open(_ subfolder: PhotoFolder) {
        switch AlbumGridRules.destination(for: subfolder) {
        case .grid:
            router.foldersPath.append(.grid(subfolder))
        case .browser:
            router.foldersPath.append(.browser(subfolder))
        }
    }
}

/// The tile itself: a square cover, the name, the count.
private struct AlbumTile: View {
    let title: String
    let subtitle: String
    let coverURL: URL?
    /// The resolved tile width. Passed in rather than measured: the grid
    /// item already knows it, and a per-tile `GeometryReader` would add a
    /// layout pass for every row.
    let width: CGFloat
    var action: () -> Void

    /// Square, matching the thumbnail decode exactly. The thumbnail service
    /// renders a square bitmap at the requested size, so a non-square frame
    /// would crop it — and the crop would differ per album, which is what
    /// makes a grid of mixed covers look ragged.
    private var coverHeight: CGFloat { width }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Design.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Design.ink3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        // One tap target for the whole tile, not just the thumbnail — a
        // 150pt-wide strip of tappable text is a missed tap.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        ZStack {
            if let coverURL {
                ThumbnailView(url: coverURL, size: width, cornerRadius: 12)
                    .frame(width: width, height: coverHeight)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Design.bgGrouped)
                    .frame(width: width, height: coverHeight)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Design.ink3)
                    }
            }
        }
        .frame(width: width, height: coverHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Design.separator, lineWidth: 0.5)
        }
    }
}

/// Section caption above a group of tiles ("Photos", "Folders").
private struct AlbumSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Design.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }
}

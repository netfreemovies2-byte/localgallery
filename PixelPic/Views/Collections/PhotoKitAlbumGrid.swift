import SwiftUI

/// The album grid for the device's own Photos library — the app's home
/// screen.
///
/// Its own view rather than a variant of a folder-tree tile grid: the
/// two show different things — PhotoKit albums have no folder tree, no
/// subfolders and no "All Photos" pseudo-album, and a tile's cover is a
/// `PHAsset` rather than a file URL.
///
/// The layout follows the QuickPic reference: two large columns
/// (three on request from the More menu), tight spacing, and each
/// tile's name and count overlaid on a gradient at the bottom of its
/// cover. Which albums appear — and in what order — is
/// `PhotoKitLibraryRules.homeAlbums`' pure derivation from the
/// service's list: empty user albums hidden unless the user turned
/// them on, system albums pinned first, the user's sort applied to
/// their own albums, and the search query applied across all of it.
struct PhotoKitAlbumGrid: View {
    @Environment(GalleryStore.self) private var store

    /// The home search query, owned by the library view's toolbar.
    var searchText: String = ""

    @AppStorage("showEmptyAlbums") private var showEmptyAlbums = false
    @AppStorage("albumSortMode") private var sortModeRaw = 0
    /// Home grid columns: 2 (the reference layout) or 3.
    @AppStorage("albumGridColumns") private var columnCount = 2

    /// Horizontal padding around the grid.
    private static let horizontalPadding: CGFloat = 10
    /// Gap between tiles.
    private static let spacing: CGFloat = 8

    private var visibleAlbums: [PhotoKitAlbum] {
        PhotoKitLibraryRules.homeAlbums(
            store.photoKit.albums,
            showEmptyAlbums: showEmptyAlbums,
            sort: PhotoKitLibraryRules.AlbumHomeSort(rawValue: sortModeRaw) ?? .serviceOrder,
            searchQuery: searchText
        )
    }

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - Self.horizontalPadding * 2
            let columns = max(2, min(3, columnCount))
            // Rounded to whole points: the width is a decode size for
            // the thumbnail service, and a fractional one would make
            // the cover cache key differ per tile for no reason.
            let tileWidth = ((available - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
                .rounded()

            ScrollView {
                if visibleAlbums.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView(
                        "No Albums Found",
                        systemImage: "magnifyingglass",
                        description: Text("No album matches “\(searchText)”.")
                    )
                    .padding(.top, 48)
                } else if visibleAlbums.isEmpty {
                    // Every user album is empty and hidden, and the
                    // system albums have nothing yet either.
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.stack",
                        description: Text("Albums with photos in them will appear here.")
                    )
                    .padding(.top, 48)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Self.spacing), count: columns),
                        alignment: .leading,
                        spacing: Self.spacing
                    ) {
                        ForEach(visibleAlbums) { album in
                            PhotoKitAlbumTile(
                                album: album,
                                width: tileWidth
                            )
                        }
                    }
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .refreshable {
                await store.photoKit.loadLibrary()
            }
            .softTopScrollEdge()
        }
    }
}

/// One album tile: a square cover with the album's name and count
/// overlaid at its bottom on a dark gradient, QuickPic-style.
private struct PhotoKitAlbumTile: View {
    let album: PhotoKitAlbum
    /// The resolved tile width, passed in rather than measured.
    let width: CGFloat

    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.photoLibraryPath.append(.album(album))
        } label: {
            ZStack(alignment: .bottomLeading) {
                cover
                // The name + count overlay: white on a gradient that
                // darkens the cover's bottom edge, so it stays
                // readable over any photo.
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(album.countLabel)
                        .font(.system(size: 12))
                        .opacity(0.85)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 56),
                    alignment: .bottom
                )
            }
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Design.separator, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        // One tap target for the whole tile.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let coverAssetID = album.coverAssetID {
            PhotoKitThumbnailView(
                assetID: coverAssetID,
                size: width,
                cornerRadius: 10
            )
            .frame(width: width, height: width)
        } else {
            Rectangle()
                .fill(Design.bgGrouped)
                .frame(width: width, height: width)
                .overlay {
                    Image(systemName: album.kind.iconName)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Design.ink3)
                }
        }
    }
}

/// Section caption above a group of tiles.
struct PhotoKitSectionHeader: View {
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

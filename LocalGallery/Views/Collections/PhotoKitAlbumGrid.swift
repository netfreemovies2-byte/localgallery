import SwiftUI

/// The album grid for the device's own Photos library — the app's home
/// screen.
///
/// Its own view rather than a variant of a folder-tree tile grid: the
/// two show different things — PhotoKit albums have no folder tree, no
/// subfolders and no "All Photos" pseudo-album, and a tile's cover is a
/// `PHAsset` rather than a file URL.
struct PhotoKitAlbumGrid: View {
    @Environment(GalleryStore.self) private var store

    /// Horizontal padding around the grid — matches the photo grid's own.
    private static let horizontalPadding: CGFloat = 16
    /// Gap between tiles.
    private static let spacing: CGFloat = 14
    /// Target tile width. Derived from the available width so the tiles
    /// stay a sensible size on a phone, an iPad and in a split view
    /// without three different layouts.
    private static let targetTileWidth: CGFloat = 165

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - Self.horizontalPadding * 2
            let columns = max(2, Int((available + Self.spacing) / (Self.targetTileWidth + Self.spacing)))
            // Rounded to whole points: the width is a decode size for the
            // thumbnail service, and a fractional one asks for a pixel
            // size it will round anyway — while making the cover cache
            // key differ from the neighbouring tile's for no reason.
            let tileWidth = ((available - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
                .rounded()

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Self.spacing), count: columns),
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(store.photoKit.albums) { album in
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
            .refreshable {
                await store.photoKit.loadLibrary()
            }
            .softTopScrollEdge()
        }
    }
}

/// One album tile: a square cover, the album's name, and its count.
private struct PhotoKitAlbumTile: View {
    let album: PhotoKitAlbum
    /// The resolved tile width, passed in rather than measured.
    let width: CGFloat

    @Environment(AppRouter.self) private var router

    /// Square, matching the thumbnail decode exactly — a non-square frame
    /// would crop it, and the crop would differ per album, which is what
    /// makes a grid of mixed covers look ragged.
    private var coverHeight: CGFloat { width }

    var body: some View {
        Button {
            router.photoLibraryPath.append(.album(album))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Design.ink)
                        .lineLimit(1)
                    Text(album.countLabel)
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
            if let coverAssetID = album.coverAssetID {
                PhotoKitThumbnailView(
                    assetID: coverAssetID,
                    size: width,
                    cornerRadius: 12
                )
                .frame(width: width, height: coverHeight)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Design.bgGrouped)
                    .frame(width: width, height: coverHeight)
                    .overlay {
                        Image(systemName: album.kind.iconName)
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

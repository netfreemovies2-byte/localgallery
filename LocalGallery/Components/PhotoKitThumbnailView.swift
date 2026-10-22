import SwiftUI
import Photos

/// A thumbnail for one photo-library asset.
///
/// A sibling of `ThumbnailView`, not a variant of it: `ThumbnailView`
/// reads a file on disk through the folder pipeline's thumbnail service
/// (with its disk cache, file-provider placeholders and QuickLook
/// fallback), and a `PHAsset` has no file to read. Sharing the component
/// would mean one of them growing a branch that can never be true.
struct PhotoKitThumbnailView: View {
    let assetID: String
    let size: CGFloat
    var isVideo: Bool = false
    var isLivePhoto: Bool = false
    var cornerRadius: CGFloat = 0

    @Environment(GalleryStore.self) private var store
    @State private var thumbnail: UIImage?
    @State private var isMissing = false

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .transition(.opacity)
            } else if isMissing {
                Rectangle()
                    .fill(Design.bgGrouped)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: max(16, size * 0.2)))
                            .foregroundStyle(Design.ink3)
                    )
                    .transition(.opacity)
            } else {
                ShimmerView()
                    .frame(width: size, height: size)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: max(10, size * 0.1)))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if isLivePhoto && !isVideo {
                Text("LIVE")
                    .font(.system(size: max(8, size * 0.08), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
        }
        .animation(.easeIn(duration: 0.2), value: thumbnail != nil)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // Keyed on size as well as asset: the grid's density tiers change
        // the cell size, and a cell that kept its old decode would render
        // soft until it was recycled.
        .task(id: ThumbKey(assetID: assetID, size: Int(size))) {
            let result = await store.photoKit.thumbnail(
                for: assetID,
                size: size
            )
            self.thumbnail = result
            self.isMissing = (result == nil)
        }
    }
}

/// Identity for the photo-library thumbnail task.
private struct ThumbKey: Hashable {
    let assetID: String
    let size: Int
}

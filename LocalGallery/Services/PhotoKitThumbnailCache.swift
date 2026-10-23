import Foundation
import Photos
import UIKit

/// The synthetic identifier of the "Camera Roll" album.
///
/// The Camera Roll is not a `PHAssetCollection` — it is "all assets" —
/// so it has no identifier to fetch by. The pseudo-album needs one to
/// be `Identifiable` and to be routed to, so it gets a constant.
enum PhotoKitAlbumID {
    static let cameraRoll = "photokit:camera-roll"
}

/// In-memory thumbnail cache for photo-library assets.
///
/// `NSCache` is thread-safe but not `Sendable`, and this is read from
/// the main actor while PhotoKit's callbacks write to it — so the holder
/// is explicitly unchecked-sendable and does nothing else.
final class PhotoKitThumbnailCache: @unchecked Sendable {
    static let shared = PhotoKitThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    /// Rough byte budget. A 200 pt cell at 3× is a 600×600 bitmap —
    /// about 1.4 MB — so this holds roughly 400 cells.
    private init() {
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    static func key(assetID: String, size: CGFloat, scale: CGFloat) -> NSString {
        "\(assetID)@\(Int(size.rounded()))x\(Int(scale.rounded()))" as NSString
    }

    func image(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func set(_ image: UIImage, forKey key: NSString) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key, cost: cost)
    }
}

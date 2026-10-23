import Foundation
import Photos
import UIKit

/// The synthetic identifier of the "Camera" album.
///
/// The Camera album is not a `PHAssetCollection` — it is a filtered
/// fetch over the whole library — so it has no identifier to fetch by.
/// The pseudo-album needs one to be `Identifiable` and to be routed to,
/// so it gets a constant.
enum PhotoKitAlbumID {
    static let camera = "photokit:camera"
}

/// In-memory thumbnail cache for photo-library assets.
///
/// `NSCache` is thread-safe but not `Sendable`, and this is read from
/// the main actor while PhotoKit's callbacks write to it — so the holder
/// is explicitly unchecked-sendable and does nothing else.
final class PhotoKitThumbnailCache: @unchecked Sendable {
    static let shared = PhotoKitThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    /// Which keys have been stored, per asset id — the seed index.
    ///
    /// The cache is keyed by (asset, size, scale), so a caller that
    /// wants a *different* size than the one already decoded cannot
    /// find the existing bitmap by key. The viewer hit exactly that:
    /// the grid caches at cell size (~196 pt), the viewer asked for
    /// 600 pt, missed, and cold-decoded ~1800 px while showing
    /// nothing — the device-reported black viewer. This index lets
    /// `anyImage(forAssetID:)` find whatever variant exists so the
    /// viewer can seed itself with the very image the user tapped.
    /// Guarded by a lock: writes arrive on PhotoKit callback threads.
    private var keysByAsset: [String: Set<NSString>] = [:]
    private let keysLock = NSLock()

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
        // The key's prefix before "@" is the asset id (see `key`).
        let assetID = (key as String).components(separatedBy: "@").first ?? ""
        if !assetID.isEmpty {
            keysLock.lock()
            keysByAsset[assetID, default: []].insert(key)
            keysLock.unlock()
        }
    }

    /// The largest cached variant of this asset's thumbnail, at
    /// whatever size it was decoded — or nil if nothing is cached.
    ///
    /// Synchronous and allocation-light: it exists so a view can
    /// seed itself *before* its first await, with the bitmap the
    /// user is already looking at in the grid. A key whose bitmap
    /// NSCache has since evicted simply misses and is skipped.
    func anyImage(forAssetID assetID: String) -> UIImage? {
        keysLock.lock()
        let keys = keysByAsset[assetID]
        keysLock.unlock()
        guard let keys else { return nil }
        var best: UIImage?
        var bestPixels = -1
        for key in keys {
            guard let image = cache.object(forKey: key) else { continue }
            let pixels = Int(image.size.width * image.scale)
                * Int(image.size.height * image.scale)
            if pixels > bestPixels {
                bestPixels = pixels
                best = image
            }
        }
        return best
    }
}

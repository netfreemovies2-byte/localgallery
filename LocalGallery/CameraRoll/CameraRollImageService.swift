import AVFoundation
import ImageIO
import Photos
import UIKit

/// Wraps a non-Sendable value so it can cross a continuation boundary.
/// Only used for values that are created and consumed once (UIImage, AVPlayerItem).
struct CameraRollUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Metadata shown in the viewer's info sheet. Built on demand, never for a whole grid.
struct CameraRollAssetInfo: Sendable, Equatable {
    var filename: String?
    var creationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var isVideo: Bool
    var duration: TimeInterval
    var isFavorite: Bool
    var latitude: Double?
    var longitude: Double?
}

enum CameraRollServiceError: Error, Equatable {
    case assetUnavailable
    case exportFailed
}

/// Thread-safe one-shot gate so a PhotoKit callback can never resume a
/// continuation twice.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Lets a task-cancellation handler cancel a PhotoKit request whose id only
/// exists after the request call returns.
private final class ImageRequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private let manager: PHImageManager
    private var requestID: PHImageRequestID?
    private var isCancelled = false

    init(manager: PHImageManager) { self.manager = manager }

    func attach(_ id: PHImageRequestID) {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            manager.cancelImageRequest(id)
        } else {
            requestID = id
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if let id = requestID { manager.cancelImageRequest(id) }
    }
}

/// All PhotoKit image/video/metadata work. Deliberately not main-actor
/// isolated: PhotoKit invokes result handlers on its own queues, and no
/// `PHAsset` ever crosses an isolation boundary — callers pass
/// `localIdentifier` strings and the PHAsset is resolved (and cached) in here.
final class CameraRollImageService: @unchecked Sendable {
    static let shared = CameraRollImageService()

    private let manager = PHCachingImageManager()
    /// Bounded: NSCache evicts under memory pressure and by count.
    private let assetCache: NSCache<NSString, PHAsset> = {
        let c = NSCache<NSString, PHAsset>()
        c.countLimit = 4000
        return c
    }()

    private init() {
        manager.allowsCachingHighQualityImages = false
    }

    // MARK: - Asset lookup

    func asset(for id: String) -> PHAsset? {
        if let cached = assetCache.object(forKey: id as NSString) { return cached }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = result.firstObject else { return nil }
        assetCache.setObject(asset, forKey: id as NSString)
        return asset
    }

    func clearCaches() {
        assetCache.removeAllObjects()
        manager.stopCachingImagesForAllAssets()
    }

    // MARK: - Listing

    /// Loads lightweight item records off the main thread. Sorting by
    /// creation date and the images-only predicate are done by PhotoKit.
    static func loadItems(albumID: String?, includeVideos: Bool, newestFirst: Bool) async -> [CameraRollItem] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
            if !includeVideos {
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            }
            let result: PHFetchResult<PHAsset>
            if let albumID {
                guard let collection = PHAssetCollection
                    .fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
                else { return [] }
                result = PHAsset.fetchAssets(in: collection, options: options)
            } else {
                result = PHAsset.fetchAssets(with: options)
            }
            var items: [CameraRollItem] = []
            items.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                items.append(CameraRollItem(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    isVideo: asset.mediaType == .video,
                    isAnimated: asset.playbackStyle == .imageAnimated,
                    isFavorite: asset.isFavorite,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    duration: asset.duration
                ))
            }
            return items
        }.value
    }

    static func loadAlbums(includeVideos: Bool) async -> [CameraRollAlbum] {
        await Task.detached(priority: .userInitiated) {
            let countOptions = PHFetchOptions()
            if !includeVideos {
                countOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            }
            let wantedSmart: [PHAssetCollectionSubtype] = [
                .smartAlbumUserLibrary, .smartAlbumFavorites, .smartAlbumVideos,
                .smartAlbumScreenshots, .smartAlbumSelfPortraits, .smartAlbumLivePhotos,
                .smartAlbumPanoramas, .smartAlbumAnimated, .smartAlbumBursts,
            ]
            var albums: [CameraRollAlbum] = []
            var seen = Set<String>()

            func add(_ collection: PHAssetCollection, source: CameraRollAlbum.Source) {
                guard seen.insert(collection.localIdentifier).inserted else { return }
                let count = PHAsset.fetchAssets(in: collection, options: countOptions).count
                albums.append(CameraRollAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled",
                    assetCount: count,
                    source: source,
                    subtypeRaw: source == .smart ? collection.assetCollectionSubtype.rawValue : 0
                ))
            }

            let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            smart.enumerateObjects { collection, _, _ in
                if wantedSmart.contains(collection.assetCollectionSubtype) { add(collection, source: .smart) }
            }
            let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            user.enumerateObjects { collection, _, _ in add(collection, source: .user) }

            // Smart albums first in a fixed order (All Photos on top), then
            // user albums alphabetically. Empty albums are kept: the count is honest.
            return albums.sorted { a, b in
                if a.source != b.source { return a.source == .smart }
                if a.source == .smart {
                    let ia = wantedSmart.firstIndex { $0.rawValue == a.subtypeRaw } ?? Int.max
                    let ib = wantedSmart.firstIndex { $0.rawValue == b.subtypeRaw } ?? Int.max
                    return ia < ib
                }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }.value
    }

    /// Newest asset id in an album, for the cover thumbnail.
    static func coverAssetID(albumID: String, includeVideos: Bool) async -> String? {
        await Task.detached(priority: .utility) {
            guard let collection = PHAssetCollection
                .fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
            else { return nil }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            if !includeVideos {
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            }
            return PHAsset.fetchAssets(in: collection, options: options).firstObject?.localIdentifier
        }.value
    }

    // MARK: - Images

    /// Small, fast image for grids. Never requests full resolution.
    func thumbnail(id: String, pixelSize: CGSize) async -> CameraRollUncheckedBox<UIImage?> {
        await requestImage(id: id, pixelSize: pixelSize, contentMode: .aspectFill, resize: .fast)
    }

    /// Screen-sized image for the viewer (not the full original).
    func displayImage(id: String, maxPixel: CGFloat) async -> CameraRollUncheckedBox<UIImage?> {
        await requestImage(id: id, pixelSize: CGSize(width: maxPixel, height: maxPixel), contentMode: .aspectFit, resize: .none)
    }

    private func requestImage(
        id: String,
        pixelSize: CGSize,
        contentMode: PHImageContentMode,
        resize: PHImageRequestOptionsResizeMode
    ) async -> CameraRollUncheckedBox<UIImage?> {
        guard let asset = asset(for: id) else { return CameraRollUncheckedBox(value: nil) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = resize
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let manager = self.manager
        let token = ImageRequestToken(manager: manager)
        let box: CameraRollUncheckedBox<UIImage?> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CameraRollUncheckedBox<UIImage?>, Never>) in
                let once = ResumeOnce()
                let requestID = manager.requestImage(
                    for: asset, targetSize: pixelSize, contentMode: contentMode, options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded && image != nil { return }   // wait for the final image
                    if once.claim() { continuation.resume(returning: CameraRollUncheckedBox(value: image)) }
                }
                token.attach(requestID)
            }
        } onCancel: {
            token.cancel()
        }
        return box
    }

    /// Decodes an animated GIF into a UIImage with frames and timing.
    func animatedImage(id: String, maxPixel: CGFloat) async -> CameraRollUncheckedBox<UIImage?> {
        guard let asset = asset(for: id) else { return CameraRollUncheckedBox(value: nil) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let manager = self.manager
        let token = ImageRequestToken(manager: manager)
        let data: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                let once = ResumeOnce()
                let requestID = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    if once.claim() { continuation.resume(returning: data) }
                }
                token.attach(requestID)
            }
        } onCancel: {
            token.cancel()
        }
        guard let data, !Task.isCancelled else { return CameraRollUncheckedBox(value: nil) }
        return CameraRollUncheckedBox(value: AnimatedImageDecoder.makeAnimatedImage(from: data, maxPixelSize: maxPixel))
    }

    // MARK: - Video

    func playerItem(id: String) async -> CameraRollUncheckedBox<AVPlayerItem>? {
        guard let asset = asset(for: id), asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let manager = self.manager
        let token = ImageRequestToken(manager: manager)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CameraRollUncheckedBox<AVPlayerItem>?, Never>) in
                let once = ResumeOnce()
                let requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                    if once.claim() {
                        continuation.resume(returning: item.map { CameraRollUncheckedBox(value: $0) })
                    }
                }
                token.attach(requestID)
            }
        } onCancel: {
            token.cancel()
        }
    }

    // MARK: - Metadata

    func info(id: String) -> CameraRollAssetInfo? {
        guard let asset = asset(for: id) else { return nil }
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
        return CameraRollAssetInfo(
            filename: filename,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isVideo: asset.mediaType == .video,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude
        )
    }

    // MARK: - Changes (need read/write authorization)

    func setFavorite(ids: [String], favorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            assets.enumerateObjects { asset, _, _ in
                let request = PHAssetChangeRequest(for: asset)
                request.isFavorite = favorite
            }
        }
    }

    /// Deletes assets. iOS shows its own system confirmation; if the user
    /// cancels it, this returns `false` instead of throwing.
    func delete(ids: [String]) async throws -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            }
            for id in ids { assetCache.removeObject(forKey: id as NSString) }
            return true
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return false
        }
    }

    // MARK: - Export for sharing

    /// Writes the original (or current edited version) to a temporary file
    /// so the system share sheet can send a real file.
    func exportForSharing(id: String) async throws -> URL {
        guard let asset = asset(for: id) else { throw CameraRollServiceError.assetUnavailable }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        guard let resource = preferred.compactMap({ type in resources.first { $0.type == type } }).first
                ?? resources.first
        else { throw CameraRollServiceError.exportFailed }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraRollShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }
}

// MARK: - GIF decoding

enum AnimatedImageDecoder {
    /// Caps decoded frames so a long GIF cannot exhaust memory; longer GIFs
    /// are sampled evenly and total duration is preserved.
    static let maxFrames = 120

    static func makeAnimatedImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        if count == 1 {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }

        let step = max(1, Int((Double(count) / Double(maxFrames)).rounded(.up)))
        var frames: [UIImage] = []
        var totalDuration = 0.0
        for index in 0..<count {
            totalDuration += frameDelay(at: index, in: source)
            guard index % step == 0 else { continue }
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, thumbOptions as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: cg))
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(totalDuration, 0.1))
    }

    /// Seconds. Browsers treat delays under ~10 ms as 100 ms; so do we.
    static func frameDelay(at index: Int, in source: CGImageSource) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }
}

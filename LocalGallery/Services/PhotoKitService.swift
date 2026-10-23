import Foundation
import UIKit
import Photos
import AVFoundation
import Observation
import os

/// The device's own Photos library, read through PhotoKit.
///
/// Deliberately a *separate* service from the folder-based library rather
/// than another source of `PhotoFile`s: a `PHAsset` has no file URL, no
/// stable SHA-256 identity, and no sidecar — the folder pipeline's whole
/// model (scan → sidecars → tags → memories) does not apply to it.
/// Folding Camera Roll into `allPhotos` would mean inventing a fake URL
/// for every asset and dragging the whole Rust scan pipeline over a
/// library the system already indexes.
///
/// What this service owns:
///
/// * **Access** — the read/write authorization state, with a request the
///   user can actually answer, and a way back into Settings when the
///   answer was no.
/// * **Albums** — Camera Roll, Recents, Screenshots, Videos, Favorites
///   and the user's own albums, each with a cover and a count.
/// * **Thumbnails** — requested at cell size through `PHImageManager` and
///   cached in memory. Full-resolution pixels are only ever requested for
///   the one photo the viewer is showing.
/// * **Export** — the original bytes written to a temporary file, so the
///   share sheet has something real to hand over.
///
/// The service is `@MainActor`: every screen that reads it is on the main
/// actor, and PhotoKit's own objects (`PHAsset`, `PHAssetCollection`) are
/// not `Sendable`, so they must not cross an actor boundary. The work
/// that can leave the main actor — enumerating a library of 100k assets
/// — lives in `nonisolated static` helpers that return only `Sendable`
/// values.
@MainActor
@Observable
final class PhotoKitService {
    /// The current access level.
    var authorization: PhotoKitAuthorization = .notDetermined
    /// The albums to show. Empty until the library has been read.
    var albums: [PhotoKitAlbum] = []
    /// The Camera Roll's assets, newest first. This is the timeline.
    var cameraRoll: [PhotoKitAsset] = []
    /// True while a load is in flight. The views use it to tell "no access
    /// yet" apart from "no photos".
    var isLoading = false
    /// Set when a load failed for a reason worth showing.
    var lastError: String?
    /// True once a load has completed at least once — so a *successful but
    /// empty* library is distinguishable from one that never loaded.
    var hasLoaded = false
    /// Set when a page came back empty, so the timeline stops asking for
    /// more. The total the paging compares against was read when the albums
    /// were enumerated, and the library can shrink in between.
    private var hasReachedTheEnd = false

    /// How many assets the timeline fetches up front.
    ///
    /// A device can hold 100k assets; fetching them all up front would
    /// stall the first paint. The timeline pages in more as the user
    /// scrolls (see `loadMoreCameraRoll`), and the *album* counts come
    /// from PhotoKit's own count, which is exact without loading the
    /// assets.
    static let initialCameraRollLimit = 600
    /// How many more assets each "load more" pass pulls in.
    static let cameraRollPageSize = 600

    /// Whether the timeline has more assets to pull in.
    ///
    /// The total comes from PhotoKit's own count, so this is exact
    /// without loading every asset — and it means the paging sentinel
    /// disappears by itself once the whole library is on screen.
    var hasMoreToLoad: Bool {
        !hasReachedTheEnd
            && PhotoKitLibraryRules.hasMore(fetched: cameraRoll.count, total: totalAssetCount)
    }

    /// How many assets the library holds in total.
    ///
    /// PhotoKit's own count for the whole library, so it is exact without
    /// loading every asset. The viewer's "N of M" readout uses it, so the
    /// number is the library's size rather than the number of assets that
    /// happen to have been paged in.
    var totalAssetCount: Int {
        albums.first { $0.kind == .cameraRoll }?.count ?? cameraRoll.count
    }

    // MARK: - Access

    /// Re-read the authorization status. Cheap; safe to call on every
    /// appearance of the Camera Roll tab, which is what makes the state
    /// recover after the user changes it in Settings and comes back.
    func refreshAuthorization() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let mapped = PhotoKitAuthorization.map(status)
        if mapped != authorization {
            Log.photokit.info("Photos access: \(mapped)")
        }
        authorization = mapped
    }

    /// Ask for access. Returns the resulting state.
    ///
    /// A *restricted* device never shows the prompt, and a denied user
    /// would be prompted again for nothing — so the request is only made
    /// from `.notDetermined`, and the caller is told which state it landed
    /// in.
    @discardableResult
    func requestAccess() async -> PhotoKitAuthorization {
        refreshAuthorization()
        guard authorization == .notDetermined else { return authorization }
        let status = await Self.requestAuthorizationStatus()
        authorization = PhotoKitAuthorization.map(status)
        Log.photokit.info("Photos access requested: \(authorization)")
        return authorization
    }

    /// The system prompt, wrapped. PhotoKit's request is callback-based.
    private static func requestAuthorizationStatus() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Library

    /// Load the albums and the Camera Roll timeline.
    ///
    /// A no-op when access has not been granted, so it is safe to call
    /// from a `.task` on a view the user has not answered the prompt on
    /// yet.
    func loadLibrary() async {
        refreshAuthorization()
        guard authorization.isReadable else {
            albums = []
            cameraRoll = []
            hasLoaded = false
            return
        }
        isLoading = true
        lastError = nil
        hasReachedTheEnd = false
        let fetchedAlbums = await Self.fetchAlbums()
        let assets = await Self.fetchCameraRoll(limit: Self.initialCameraRollLimit)
        albums = fetchedAlbums
        cameraRoll = assets
        hasLoaded = true
        Log.photokit.info("Loaded \(albums.count) albums, \(assets.count) timeline assets")
        isLoading = false
    }

    /// Pull the next page of the timeline. Called when the user scrolls to
    /// the end of what has been fetched.
    ///
    /// Offset-based rather than "fetch N again": the offset survives a
    /// photo being deleted (the page simply comes back short) and the
    /// fetch does not re-walk everything already on screen.
    func loadMoreCameraRoll() async {
        guard authorization.isReadable, !isLoading, !hasReachedTheEnd else { return }
        let fetched = cameraRoll.count
        guard fetched > 0 else { return }
        let offset = PhotoKitLibraryRules.nextOffset(fetched: fetched)
        let limit = PhotoKitLibraryRules.pageSize(
            fetched: fetched,
            total: totalAssetCount,
            page: Self.cameraRollPageSize
        )
        isLoading = true
        let page = await Self.fetchCameraRoll(offset: offset, limit: limit)
        isLoading = false
        guard !page.isEmpty else {
            // The library shrank since the albums were enumerated (a photo
            // deleted from another app), so the count the sentinel compares
            // against is stale. Stop asking — otherwise it would fetch an
            // empty page for ever.
            hasReachedTheEnd = true
            return
        }
        cameraRoll.append(contentsOf: page)
    }

    /// One page of an album's assets, newest first.
    ///
    /// Paged rather than fetched whole, because the Camera Roll album *is*
    /// the whole library — a device with 100k photos would otherwise hold
    /// 100k value structs in memory to render the first screen of a grid.
    ///
    /// The Camera Roll is fetched through `fetchCameraRoll(offset:limit:)`
    /// rather than through a `PHAssetCollection`, because it is "all
    /// assets" and has no collection to fetch from.
    func albumPage(
        _ album: PhotoKitAlbum,
        offset: Int,
        limit: Int
    ) async -> [PhotoKitAsset] {
        guard authorization.isReadable else { return [] }
        if album.kind == .cameraRoll {
            return await Self.fetchCameraRoll(offset: offset, limit: limit)
        }
        return await Self.fetchAssets(inAlbumWithID: album.id, offset: offset, limit: limit)
    }

    // MARK: - Images

    /// A thumbnail for a grid cell.
    ///
    /// Requested at the cell's own size — the system scales the source
    /// down rather than the app decoding a full-resolution photo into
    /// memory, which is the difference between a 200 MB spike and a 4 MB
    /// one on a device with 20k photos.
    func thumbnail(for assetID: String, size: CGFloat) async -> UIImage? {
        guard authorization.isReadable else { return nil }
        let scale = UIScreen.main.scale
        let key = PhotoKitThumbnailCache.key(assetID: assetID, size: size, scale: scale)
        if let cached = PhotoKitThumbnailCache.shared.image(forKey: key) {
            return cached
        }
        guard let image = await Self.requestImage(
            assetID: assetID,
            targetSize: CGSize(width: size * scale, height: size * scale),
            contentMode: .aspectFill
        ) else { return nil }
        PhotoKitThumbnailCache.shared.set(image, forKey: key)
        return image
    }

    /// A full-resolution image for the viewer.
    ///
    /// Capped at `maxPixelSize` so the viewer is not handed a
    /// 48-megapixel bitmap: the screen cannot show more than a couple of
    /// thousand points, and the memory cost of the difference is
    /// enormous.
    func fullImage(for assetID: String, maxPixelSize: CGFloat = 2000) async -> UIImage? {
        guard authorization.isReadable else { return nil }
        return await Self.requestImage(
            assetID: assetID,
            targetSize: CGSize(width: maxPixelSize, height: maxPixelSize),
            contentMode: .aspectFit
        )
    }

    /// A player item for a video asset.
    ///
    /// `AVPlayerItem(asset:)` streams from the photo library, so a video
    /// that only exists in iCloud plays without the app downloading it
    /// first.
    func playerItem(for assetID: String) async -> AVPlayerItem? {
        guard authorization.isReadable else { return nil }
        guard let asset = Self.fetchAsset(id: assetID) else { return nil }
        guard asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
        guard let avAsset else { return nil }
        return AVPlayerItem(asset: avAsset)
    }

    /// The paired video of a Live Photo, written to a temporary file so the
    /// viewer can play the motion part. `nil` for anything that is not a
    /// Live Photo.
    ///
    /// PhotoKit exposes the paired video as a *resource* of the still
    /// asset, not as an asset of its own — so it has to be written out
    /// before it can be handed to `AVPlayer`.
    func livePhotoVideoFile(for assetID: String) async -> URL? {
        guard authorization.isReadable else { return nil }
        guard let asset = Self.fetchAsset(id: assetID) else { return nil }
        guard asset.mediaSubtypes.contains(.photoLive) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        // The paired video is the *full* video resource; the paired still
        // image is a still.
        guard let video = resources.first(where: { $0.type == .fullSizeVideo }) else { return nil }
        guard let destination = Self.temporaryURL(
            directoryName: "PixelPicLivePhoto",
            filename: video.originalFilename
        ) else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            PHAssetResourceManager.default().writeData(for: video, toFile: destination, options: options) { error in
                if let error {
                    Log.photokit.error("Live photo export failed: \(Log.r.error(error))")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: destination)
                }
            }
        }
    }

    // MARK: - Export & delete

    /// Write the original bytes of an asset to a temporary file so the
    /// share sheet has something real to send.
    ///
    /// PhotoKit has no "give me a URL" call — the bytes are behind a
    /// resource manager, and the app needs a file on disk to hand to
    /// another app.
    func exportToTemporaryFile(for assetID: String) async -> URL? {
        guard authorization.isReadable else { return nil }
        guard let asset = Self.fetchAsset(id: assetID) else { return nil }
        guard let resource = PHAssetResource.assetResources(for: asset).first else { return nil }
        guard let destination = Self.temporaryURL(
            directoryName: "PixelPicExport",
            filename: resource.originalFilename
        ) else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    Log.photokit.error("Export failed: \(Log.r.error(error))")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: destination)
                }
            }
        }
    }

    /// Delete assets from the user's photo library.
    ///
    /// The system shows its own confirmation sheet for a delete, so the
    /// app's alert is the *first* of two confirmations, not the only one.
    func delete(assetIDs: [String]) async -> Bool {
        guard authorization.isReadable, !assetIDs.isEmpty else { return false }
        let ids = assetIDs
        let success: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // The change block captures only the identifiers — re-fetching
            // inside it keeps the non-`Sendable` `PHAsset` objects out of
            // the closure entirely.
            PHPhotoLibrary.shared().performChanges({
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                PHAssetChangeRequest.deleteAssets(fetched)
            }) { ok, error in
                if let error {
                    Log.photokit.error("Delete failed: \(Log.r.error(error))")
                }
                continuation.resume(returning: ok)
            }
        }
        if success {
            await loadLibrary()
        }
        return success
    }

    // MARK: - PhotoKit calls

    /// A path inside the temporary directory, for a file PhotoKit writes
    /// on our behalf.
    ///
    /// `nil` when the directory cannot be created — the caller then has
    /// nothing to hand over, which is better than writing to a path that
    /// does not exist.
    private static func temporaryURL(directoryName: String, filename: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.photokit.error("Could not create the export directory: \(Log.r.error(error))")
            return nil
        }
        // A filename can contain a path separator in principle; strip the
        // components so the write cannot escape the directory.
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        return directory.appendingPathComponent(safeName)
    }

    /// Fetch one asset by id.
    ///
    /// A single-id fetch is cheap, so it runs on the main actor and the
    /// `PHAsset` never crosses an isolation boundary.
    private static func fetchAsset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// The albums to show, in the order they should appear.
    ///
    /// The order is `PhotoKitLibraryRules.ordered(_:)`'s rule — see
    /// there for why the system albums come first and the user's own
    /// albums keep the system's order.
    nonisolated static func fetchAlbums() async -> [PhotoKitAlbum] {
        var result: [PhotoKitAlbum] = []

        // "All assets" — the Camera Roll pseudo-album.
        let all = PHAsset.fetchAssets(with: nil as PHFetchOptions?)
        result.append(PhotoKitAlbum(
            id: PhotoKitAlbumID.cameraRoll,
            title: "Camera Roll",
            kind: .cameraRoll,
            count: all.count,
            coverAssetID: newestAssetID()
        ))

        // "Recents" — the system's own recently-added collection.
        if let recents = fetchCollection(subtype: .smartAlbumRecentlyAdded, type: .smartAlbum) {
            let count = assetCount(in: recents)
            if count > 0 {
                result.append(PhotoKitAlbum(
                    id: recents.localIdentifier,
                    title: "Recents",
                    kind: .recents,
                    count: count,
                    coverAssetID: firstAssetID(in: recents)
                ))
            }
        }

        // Screenshots / Videos / Favorites — smart albums that exist only
        // if the user has something to put in them.
        let filters: [(PhotoKitAlbum.Kind, PHAssetCollectionSubtype, String)] = [
            (.screenshots, .smartAlbumScreenshots, "Screenshots"),
            (.videos, .smartAlbumVideos, "Videos"),
            (.favorites, .smartAlbumFavorites, "Favorites"),
        ]
        for (kind, subtype, title) in filters {
            guard let collection = fetchCollection(subtype: subtype, type: .smartAlbum) else { continue }
            let count = assetCount(in: collection)
            guard count > 0 else { continue }
            result.append(PhotoKitAlbum(
                id: collection.localIdentifier,
                title: title,
                kind: kind,
                count: count,
                coverAssetID: firstAssetID(in: collection)
            ))
        }

        // The user's own albums.
        let userCollections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        )
        for index in 0..<userCollections.count {
            let collection = userCollections.object(at: index)
            result.append(PhotoKitAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Album",
                kind: .user,
                count: assetCount(in: collection),
                coverAssetID: firstAssetID(in: collection)
            ))
        }

        return PhotoKitLibraryRules.ordered(result)
    }

    /// The Camera Roll's assets, newest first.
    nonisolated static func fetchCameraRoll(limit: Int) async -> [PhotoKitAsset] {
        await fetchCameraRoll(offset: 0, limit: limit)
    }

    /// The Camera Roll's assets, newest first, starting at `offset`.
    nonisolated static func fetchCameraRoll(offset: Int, limit: Int) async -> [PhotoKitAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if limit != Int.max {
            options.fetchLimit = offset + limit
        }
        let result = PHAsset.fetchAssets(with: options)
        guard offset < result.count else { return [] }
        let end = min(result.count, offset + limit)
        var assets: [PhotoKitAsset] = []
        assets.reserveCapacity(end - offset)
        for index in offset..<end {
            assets.append(PhotoKitAsset(asset: result.object(at: index)))
        }
        return assets
    }

    /// One page of an album's assets, newest first.
    nonisolated static func fetchAssets(
        inAlbumWithID id: String,
        offset: Int,
        limit: Int
    ) async -> [PhotoKitAsset] {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        ).firstObject else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if limit != Int.max {
            options.fetchLimit = offset + limit
        }
        let result = PHAsset.fetchAssets(in: collection, options: options)
        guard offset < result.count else { return [] }
        let end = min(result.count, offset + limit)
        var assets: [PhotoKitAsset] = []
        assets.reserveCapacity(end - offset)
        for index in offset..<end {
            assets.append(PhotoKitAsset(asset: result.object(at: index)))
        }
        return assets
    }

    /// The first smart album of a given subtype, if the system has one.
    private nonisolated static func fetchCollection(
        subtype: PHAssetCollectionSubtype,
        type: PHAssetCollectionType
    ) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            with: type, subtype: subtype, options: nil
        ).firstObject
    }

    /// The number of assets in a collection.
    private nonisolated static func assetCount(in collection: PHAssetCollection) -> Int {
        PHAsset.fetchAssets(in: collection, options: nil).count
    }

    /// The local id of a collection's first asset — the album's cover.
    ///
    /// The *first* by the system's own ordering, which for an album is
    /// the order the user arranged it in, not the newest photo. That is
    /// right for a user album (the cover is the one they put there) and
    /// close enough for a smart album.
    private nonisolated static func firstAssetID(in collection: PHAssetCollection) -> String? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(in: collection, options: options).firstObject?.localIdentifier
    }

    /// The local id of the library's newest asset — the Camera Roll's
    /// cover.
    ///
    /// The Camera Roll is not a collection, so it cannot go through
    /// `firstAssetID(in:)`; the whole library is fetched with a sort
    /// descriptor and the first object taken.
    private nonisolated static func newestAssetID() -> String? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).firstObject?.localIdentifier
    }

    /// Request one image from the photo library.
    ///
    /// PhotoKit does the decoding on its own threads — this only issues
    /// the request and hands the result back — so the method is
    /// `@MainActor` because `UIImage` is not `Sendable` and must not
    /// cross an actor boundary.
    ///
    /// The request is cancelled when the surrounding task is: a fast
    /// scroll through 200 cells would otherwise queue 200 image requests
    /// nobody is waiting for.
    private static func requestImage(
        assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) async -> UIImage? {
        guard let asset = fetchAsset(id: assetID) else { return nil }
        let options = PHImageRequestOptions()
        // Opportunistic delivery: PhotoKit may hand over a small, degraded
        // image first and the good one a moment later. The box keeps the
        // degraded one as a fallback and resumes on the good one, so a
        // cell never shows a 100-pixel blur.
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let box = PhotoKitRequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                box.attach(continuation)
                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    let failed = info?[PHImageErrorKey] != nil
                    box.deliver(image, degraded: degraded, failed: failed)
                }
                box.setRequestID(requestID)
                // The task may have been cancelled between the check in
                // `withTaskCancellationHandler` and the request being
                // issued.
                if Task.isCancelled {
                    box.cancel()
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}


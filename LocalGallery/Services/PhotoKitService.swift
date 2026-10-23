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
/// Folding the device library into `allPhotos` would mean inventing a
/// fake URL for every asset and dragging the whole Rust scan pipeline
/// over a library the system already indexes.
///
/// What this service owns:
///
/// * **Access** — the read/write authorization state, with a request the
///   user can actually answer, and a way back into Settings when the
///   answer was no.
/// * **Albums** — Camera, Screenshots, Videos, Favorites and the user's
///   own albums, each with a cover and a count.
/// * **Live updates** — a `PHPhotoLibraryChangeObserver` registration, so
///   a photo or screenshot taken while the app is open appears without
///   the user closing and reopening the app.
/// * **Thumbnails** — requested at cell size through `PHImageManager`
///   and cached in memory. Full-resolution pixels are only ever
///   requested for the one photo the viewer is showing.
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
    /// True while a load is in flight. The views use it to tell "no access
    /// yet" apart from "no photos".
    var isLoading = false
    /// Set when a load failed for a reason worth showing.
    var lastError: String?
    /// True once a load has completed at least once — so a *successful but
    /// empty* library is distinguishable from one that never loaded.
    var hasLoaded = false
    /// Bumped every time a Photos-library change has been applied to
    /// `albums`. Album grids observe it to reload their visible page, so
    /// a new screenshot shows up in an open album without a manual
    /// refresh. Starts at 0; the initial load does not bump it.
    var libraryChangeToken = 0

    /// The change-observer bridge, once registered. Registration is for
    /// the app's lifetime: this service is owned by `GalleryStore`,
    /// which the app root holds as `@State`, so there is no teardown
    /// moment to unregister at.
    @ObservationIgnored
    private var changeObserver: PhotoKitLibraryChangeObserver?
    /// True while a change-driven refresh is running. A burst of changes
    /// (a burst of screenshots, an import) coalesces into at most one
    /// extra pass instead of a queue of full refreshes.
    @ObservationIgnored
    private var isRefreshingAfterChange = false
    /// Set when a change arrives during a change-driven refresh.
    @ObservationIgnored
    private var needsRefreshAfterChange = false

    /// How many assets an album grid fetches up front.
    ///
    /// An album can hold 100k assets; fetching them all up front would
    /// stall the first paint. The grid pages in more as the user scrolls
    /// (see `PhotoKitAlbumDetailView`), and the *album* counts come from
    /// PhotoKit's own counts, which are exact without loading the
    /// assets.
    static let initialAlbumLimit = 600
    /// How many more assets each "load more" pass pulls in.
    static let albumPageSize = 600

    // MARK: - Access

    /// Re-read the authorization status. Cheap; safe to call on every
    /// appearance of the gallery, which is what makes the state recover
    /// after the user changes it in Settings and comes back.
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

    // MARK: - Live updates

    /// Register for Photos-library change notifications. Idempotent.
    ///
    /// This is what makes a new screenshot appear while the app is open:
    /// PhotoKit calls the observer as soon as the library changes — the
    /// user does not have to relaunch, pull to refresh, or re-open the
    /// album.
    func startObservingLibraryChanges() {
        guard changeObserver == nil else { return }
        let observer = PhotoKitLibraryChangeObserver()
        observer.onChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleLibraryChange()
            }
        }
        changeObserver = observer
        PHPhotoLibrary.shared().register(observer)
        Log.photokit.info("Observing Photos library changes")
    }

    /// Apply one Photos-library change: re-read the album list (counts
    /// and covers) and bump `libraryChangeToken` so any open album grid
    /// reloads its page.
    ///
    /// Deliberately *not* a full reload of every album's assets: the
    /// album list is counts and covers (cheap fetches), and each open
    /// grid reloads only its own first page in response to the token.
    private func handleLibraryChange() async {
        refreshAuthorization()
        guard authorization.isReadable else { return }
        if isRefreshingAfterChange {
            needsRefreshAfterChange = true
            return
        }
        isRefreshingAfterChange = true
        while true {
            needsRefreshAfterChange = false
            albums = await Self.fetchAlbums()
            hasLoaded = true
            libraryChangeToken += 1
            if !needsRefreshAfterChange { break }
        }
        isRefreshingAfterChange = false
        Log.photokit.info("Applied a Photos library change (token \(self.libraryChangeToken))")
    }

    // MARK: - Library

    /// Load the albums.
    ///
    /// A no-op when access has not been granted, so it is safe to call
    /// from a `.task` on a view the user has not answered the prompt on
    /// yet.
    func loadLibrary() async {
        refreshAuthorization()
        guard authorization.isReadable else {
            albums = []
            hasLoaded = false
            return
        }
        startObservingLibraryChanges()
        isLoading = true
        lastError = nil
        let fetchedAlbums = await Self.fetchAlbums()
        albums = fetchedAlbums
        hasLoaded = true
        Log.photokit.info("Loaded \(albums.count) albums")
        isLoading = false
    }

    /// One page of an album's assets, newest first.
    ///
    /// Paged rather than fetched whole, because an album can hold the
    /// better part of a 100k-photo library — fetching it whole would
    /// hold 100k value structs in memory to render the first screen of
    /// a grid.
    ///
    /// The Camera album is fetched through `fetchCameraAssets` rather
    /// than through a `PHAssetCollection`, because it is a filtered view
    /// of the whole library and has no collection to fetch from.
    func albumPage(
        _ album: PhotoKitAlbum,
        offset: Int,
        limit: Int
    ) async -> [PhotoKitAsset] {
        guard authorization.isReadable else { return [] }
        if album.kind == .camera {
            return await Self.fetchCameraAssets(offset: offset, limit: limit)
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

    /// Warm the thumbnail cache for a page of assets an album grid is
    /// about to show, at the grid's cell size.
    ///
    /// Each warm goes through the ordinary `thumbnail(for:size:)` path,
    /// so a warmed cell later hits the in-memory cache instead of paying
    /// a cold decode as it scrolls into view. Sequential on purpose: the
    /// point is to get *ahead* of the scroll, not to contend with it —
    /// and a cell that scrolls into view first issues its own request
    /// anyway, which the cache then serves to both.
    func preheatThumbnails(for assetIDs: [String], size: CGFloat) async {
        guard authorization.isReadable else { return }
        for assetID in assetIDs {
            if Task.isCancelled { return }
            _ = await thumbnail(for: assetID, size: size)
        }
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
                // PhotoKit delivers the asset on its own queue, outside
                // this type's main-actor isolation. `AVAsset` is immutable
                // and documented thread-safe, so hand it across explicitly
                // instead of letting the region checker treat the resume
                // as a racy send of a main-actor-isolated value.
                nonisolated(unsafe) let deliveredAsset = avAsset
                continuation.resume(returning: deliveredAsset)
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
    /// share sheet has something real to hand over.
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

    /// Save an edited image as a **new** photo in the library.
    ///
    /// Edits never overwrite the original: the rendered pixels become a
    /// new asset (the Photos change observer then refreshes the albums,
    /// so the copy appears alongside the original). Saving needs the
    /// same read/write access the gallery already holds; when the
    /// system refuses — the user revoked write access — this returns
    /// `false` and the editor says so rather than claiming a save that
    /// did not happen.
    func saveEditedImage(_ image: UIImage) async -> Bool {
        guard authorization.isReadable else { return false }
        guard let data = image.jpegData(compressionQuality: 0.92) else { return false }
        let success: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // The change block captures only the image data — the
            // creation request is built inside it, so no PhotoKit
            // object crosses into the closure.
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }) { ok, error in
                if let error {
                    Log.photokit.error("Edited photo save failed: \(Log.r.error(error))")
                }
                continuation.resume(returning: ok)
            }
        }
        return success
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
    /// there for why Camera and the other system filters come first and
    /// the user's own albums keep the system's order.
    nonisolated static func fetchAlbums() async -> [PhotoKitAlbum] {
        var result: [PhotoKitAlbum] = []

        // "Camera" — the device's own camera captures, as a filtered
        // fetch over the library (see `cameraFetchResult()` for the
        // rule). Always present, even when empty: it is the primary
        // album, and an empty Camera tile with a 0 count is a truer
        // picture than no tile at all.
        let camera = cameraAlbumSummary()
        result.append(PhotoKitAlbum(
            id: PhotoKitAlbumID.camera,
            title: "Camera",
            kind: .camera,
            count: camera.count,
            coverAssetID: camera.coverAssetID
        ))

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

    // MARK: - Camera filtering

    /// Whether album grids sort oldest-first, from the user's Settings
    /// choice. Newest-first (`false`) is the default and the classic
    /// gallery order. Read from `UserDefaults` directly because the
    /// fetches that use it are `nonisolated static` — there is no store
    /// to ask down here.
    nonisolated static var userSortAscending: Bool {
        UserDefaults.standard.bool(forKey: "albumSortOldestFirst")
    }

    /// The fetch the Camera album is built from: the whole library,
    /// with screenshots already excluded by predicate.
    ///
    /// **How "captured by the camera" is decided — and its limits.**
    /// PhotoKit exposes no "shot on this iPhone" flag, so membership is
    /// a rule over the metadata it *does* expose
    /// (`PhotoKitLibraryRules.isCameraCapture`):
    ///
    /// * screenshots are excluded — by this fetch's predicate, and again
    ///   by the rule, so the grid and the count can never disagree;
    /// * assets synced from a computer (iTunes/Finder) are excluded —
    ///   their `sourceType` carries `.typeITunesSynced`;
    /// * assets from shared albums are excluded — `.typeCloudShared`.
    ///
    /// What remains is media that originated on this device. The honest
    /// limit: an image another app *saved on the device* (a WhatsApp or
    /// browser download) is, to PhotoKit, indistinguishable from a
    /// camera photo — same source type, no distinguishing subtype — so
    /// it can still appear in Camera. No metadata PhotoKit offers can
    /// separate the two, and pretending otherwise would mean silently
    /// presenting a guess as a fact. What the rule does guarantee is
    /// that Camera is never the whole library under a new name:
    /// screenshots, synced and shared media are always out, and the
    /// count, cover and grid all come from this same filtered fetch.
    private nonisolated static func cameraFetchResult(sortAscending: Bool) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: sortAscending)]
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) == 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        return PHAsset.fetchAssets(with: options)
    }

    /// The Camera rule applied to one asset.
    private nonisolated static func isCameraCapture(_ asset: PHAsset) -> Bool {
        PhotoKitLibraryRules.isCameraCapture(
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isSyncedFromComputer: asset.sourceType.contains(.typeITunesSynced),
            isCloudShared: asset.sourceType.contains(.typeCloudShared)
        )
    }

    /// The Camera album's count and cover, from the same filtered fetch
    /// the grid pages from — so the tile can never promise a count the
    /// grid then fails to show.
    private nonisolated static func cameraAlbumSummary() -> (count: Int, coverAssetID: String?) {
        // Newest-first regardless of the grid sort preference: the
        // tile's cover is the album's newest capture, the way every
        // gallery app presents it.
        let result = cameraFetchResult(sortAscending: false)
        var count = 0
        var coverAssetID: String?
        for index in 0..<result.count {
            let asset = result.object(at: index)
            guard isCameraCapture(asset) else { continue }
            if coverAssetID == nil {
                coverAssetID = asset.localIdentifier
            }
            count += 1
        }
        return (count, coverAssetID)
    }

    /// One page of the Camera album's assets, in the user's chosen
    /// order (newest first unless they picked oldest-first).
    ///
    /// The fetch is walked rather than sliced: membership is a filter,
    /// not a range, so "page 2" means "the next `limit` assets that
    /// pass the rule after the first `offset` that did". The walk stops
    /// as soon as the page is full.
    nonisolated static func fetchCameraAssets(offset: Int, limit: Int) async -> [PhotoKitAsset] {
        let result = cameraFetchResult(sortAscending: userSortAscending)
        var assets: [PhotoKitAsset] = []
        assets.reserveCapacity(min(limit, 1024))
        var matched = 0
        for index in 0..<result.count {
            let asset = result.object(at: index)
            guard isCameraCapture(asset) else { continue }
            if matched >= offset {
                assets.append(PhotoKitAsset(asset: asset))
                if assets.count >= limit { break }
            }
            matched += 1
        }
        return assets
    }

    /// One page of an album's assets, in the user's chosen order.
    nonisolated static func fetchAssets(
        inAlbumWithID id: String,
        offset: Int,
        limit: Int
    ) async -> [PhotoKitAsset] {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        ).firstObject else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: userSortAscending)]
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

    /// The request options shared by thumbnail requests and preheating.
    private static func imageRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        // Opportunistic delivery: PhotoKit may hand over a small, degraded
        // image first and the good one a moment later. The box keeps the
        // degraded one as a fallback and resumes on the good one, so a
        // cell never shows a 100-pixel blur.
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
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
        let options = imageRequestOptions()

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

/// Bridges PhotoKit's library-change callback into `PhotoKitService`.
///
/// A separate object because the service is `@MainActor @Observable`:
/// the callback arrives off the main actor, and the bridge's one job is
/// to hand the event to the service's main-actor task without carrying
/// any `PHChange` state across with it (the service re-reads what it
/// needs, which is simpler and always current).
private final class PhotoKitLibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    /// Called on an arbitrary queue when the library changes.
    var onChange: (() -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }
}

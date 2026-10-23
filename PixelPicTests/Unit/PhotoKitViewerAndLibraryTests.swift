import XCTest
import Photos
import UIKit
@testable import PixelPic

/// Regression tests for the two device-reported P0 bugs (October
/// 2026), plus the library features built on the same foundations.
///
/// The black viewer was, at its root, a request that could wait
/// forever: a PhotoKit cancellation arrives as a final delivery with
/// no image and no error, and the request box used to file that under
/// "keep waiting". Every test here that awaits the box would hang —
/// not fail, hang — against that implementation, which is exactly
/// the behaviour the user saw on the device.
final class PhotoKitRequestBoxTests: XCTestCase {

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func attach(_ box: PhotoKitRequestBox) -> Task<UIImage?, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                box.attach(continuation)
            }
        }
    }

    /// P0-2 regression: a PhotoKit-cancelled delivery terminates.
    func testCancelledDeliveryTerminatesTheWait() async {
        let box = PhotoKitRequestBox()
        let task = attach(box)
        box.deliver(nil, degraded: false, failed: false, cancelled: true)
        let result = await task.value
        XCTAssertNil(result)
    }

    /// P0-2 regression: a final delivery with no image and no error
    /// keys at all is still final — nothing more is coming.
    func testEmptyFinalDeliveryTerminatesTheWait() async {
        let box = PhotoKitRequestBox()
        let task = attach(box)
        box.deliver(nil, degraded: false, failed: false, cancelled: false)
        let result = await task.value
        XCTAssertNil(result)
    }

    /// Degraded first (published as a preview, not a finish), then
    /// the final image resumes with the final image.
    func testDegradedPreviewPublishedThenFinalImageResumes() async {
        let box = PhotoKitRequestBox()
        let task = attach(box)
        let degraded = makeImage()
        let final = makeImage()
        var published: UIImage?
        box.onDegradedImage = { published = $0 }
        box.deliver(degraded, degraded: true, failed: false)
        XCTAssertTrue(published === degraded)
        box.deliver(final, degraded: false, failed: false)
        let result = await task.value
        XCTAssertTrue(result === final)
    }

    /// A failure after a degraded preview finishes with the preview
    /// as the fallback — a small picture beats none.
    func testFailureFallsBackToDegradedPreview() async {
        let box = PhotoKitRequestBox()
        let task = attach(box)
        let degraded = makeImage()
        box.deliver(degraded, degraded: true, failed: false)
        box.deliver(nil, degraded: false, failed: true)
        let result = await task.value
        XCTAssertTrue(result === degraded)
    }

    /// The continuation resumes exactly once: a second final
    /// delivery changes nothing (and cannot crash the resume).
    func testSecondFinalDeliveryDoesNotResumeAgain() async {
        let box = PhotoKitRequestBox()
        let task = attach(box)
        let first = makeImage()
        let second = makeImage()
        box.deliver(first, degraded: false, failed: false)
        box.deliver(second, degraded: false, failed: false)
        let result = await task.value
        XCTAssertTrue(result === first)
    }

    /// Task-level cancellation releases the waiter with `nil`.
    func testBoxCancelReleasesTheWaiter() async {
        let box = PhotoKitRequestBox()
        let task = attach(box)
        box.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    /// The pure decision matrix, including the rows that used to
    /// keep waiting.
    func testDeliveryDecisionMatrix() {
        XCTAssertEqual(
            PhotoKitDeliveryOutcome.decide(imagePresent: true, degraded: true, failed: false, cancelled: false),
            .publishDegraded
        )
        XCTAssertEqual(
            PhotoKitDeliveryOutcome.decide(imagePresent: false, degraded: true, failed: false, cancelled: false),
            .keepWaiting
        )
        XCTAssertEqual(
            PhotoKitDeliveryOutcome.decide(imagePresent: true, degraded: false, failed: false, cancelled: false),
            .finishWithImage
        )
        XCTAssertEqual(
            PhotoKitDeliveryOutcome.decide(imagePresent: false, degraded: false, failed: true, cancelled: false),
            .finishWithFallback
        )
        XCTAssertEqual(
            PhotoKitDeliveryOutcome.decide(imagePresent: false, degraded: false, failed: false, cancelled: true),
            .finishWithFallback
        )
        XCTAssertEqual(
            PhotoKitDeliveryOutcome.decide(imagePresent: false, degraded: false, failed: false, cancelled: false),
            .finishWithFallback
        )
    }
}

/// The selection model: IDs, not indexes, so scrolling and reloads
/// cannot retarget it.
final class PhotoKitSelectionTests: XCTestCase {

    func testBeginToggleSelectAllCancel() {
        var selection = PhotoSelectionModel()
        XCTAssertFalse(selection.isActive)

        selection.begin(with: "a")
        XCTAssertTrue(selection.isActive)
        XCTAssertEqual(selection.selectedIDs, ["a"])

        selection.toggle("b")
        XCTAssertEqual(selection.selectedIDs, ["a", "b"])
        selection.toggle("a")
        XCTAssertEqual(selection.selectedIDs, ["b"])
        // Toggling the last one off keeps the mode on.
        selection.toggle("b")
        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.isEmpty)

        selection.selectAll(["x", "y", "z"])
        XCTAssertEqual(selection.selectedIDs, ["x", "y", "z"])

        selection.cancel()
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    /// The selection survives the list being reloaded in a different
    /// order, and pruning drops ids that left the album.
    func testSelectionIsStableAcrossReloadAndPrunes() {
        var selection = PhotoSelectionModel()
        selection.begin(with: "b")
        selection.toggle("d")

        let reloaded = [
            PhotoKitAsset(id: "d"),
            PhotoKitAsset(id: "c"),
            PhotoKitAsset(id: "b"),
        ]
        XCTAssertEqual(selection.orderedSelection(from: reloaded).map(\.id), ["d", "b"])

        selection.prune(toPresentIDs: ["d", "c"])
        XCTAssertEqual(selection.selectedIDs, ["d"])
    }

    /// Inactive selection ignores toggles (a stray tap handler
    /// outside selection mode must not start one).
    func testToggleWhileInactiveDoesNothing() {
        var selection = PhotoSelectionModel()
        selection.toggle("a")
        selection.selectAll(["a"])
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }
}

/// The home grid's visibility + sort derivation.
final class PhotoKitHomeAlbumsTests: XCTestCase {

    private func album(_ id: String, _ title: String, _ kind: PhotoKitAlbum.Kind, _ count: Int) -> PhotoKitAlbum {
        PhotoKitAlbum(id: id, title: title, kind: kind, count: count, coverAssetID: nil)
    }

    private var library: [PhotoKitAlbum] {
        [
            album("user-empty", "Empty One", .user, 0),
            album("camera", "Camera", .camera, 10),
            album("user-b", "Beach", .user, 3),
            album("shots", "Screenshots", .screenshots, 5),
            album("user-a", "Zoo Trip", .user, 40),
        ]
    }

    func testEmptyUserAlbumsHiddenByDefaultShownOnRequest() {
        let hidden = PhotoKitLibraryRules.homeAlbums(library, showEmptyAlbums: false, sort: .serviceOrder)
        XCTAssertFalse(hidden.contains { $0.id == "user-empty" })
        // System albums are never hidden by this rule.
        XCTAssertTrue(hidden.contains { $0.id == "camera" })

        let shown = PhotoKitLibraryRules.homeAlbums(library, showEmptyAlbums: true, sort: .serviceOrder)
        XCTAssertTrue(shown.contains { $0.id == "user-empty" })
    }

    func testSystemAlbumsStayPinnedFirstUnderSorts() {
        let byName = PhotoKitLibraryRules.homeAlbums(library, showEmptyAlbums: true, sort: .name)
        XCTAssertEqual(Array(byName.prefix(2)).map(\.id), ["camera", "shots"])
        XCTAssertEqual(byName.dropFirst(2).map(\.id), ["user-b", "user-empty", "user-a"])

        let bySize = PhotoKitLibraryRules.homeAlbums(library, showEmptyAlbums: true, sort: .mostItems)
        XCTAssertEqual(bySize.dropFirst(2).map(\.id), ["user-a", "user-b", "user-empty"])
    }

    func testSearchFiltersByTitleAcrossBlocks() {
        let found = PhotoKitLibraryRules.homeAlbums(library, showEmptyAlbums: true, sort: .serviceOrder, searchQuery: "zoo")
        XCTAssertEqual(found.map(\.id), ["user-a"])
        let none = PhotoKitLibraryRules.homeAlbums(library, showEmptyAlbums: true, sort: .serviceOrder, searchQuery: "nope")
        XCTAssertTrue(none.isEmpty)
    }
}

/// Media-operation error mapping.
final class PhotoKitOperationResultTests: XCTestCase {

    func testSuccessPassesThrough() {
        XCTAssertEqual(PhotoKitOperationResult.from(error: nil, succeeded: true), .success)
    }

    func testDeniedMapsToPermissionMessage() {
        let error = NSError(domain: PHPhotosErrorDomain, code: 3311)
        let result = PhotoKitOperationResult.from(error: error, succeeded: false)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.failureMessage?.contains("permission") == true)
    }

    func testNetworkMapsToNetworkMessage() {
        let error = NSError(domain: PHPhotosErrorDomain, code: 3302)
        let result = PhotoKitOperationResult.from(error: error, succeeded: false)
        XCTAssertTrue(result.failureMessage?.contains("network") == true)
    }

    func testSilentFailureStillGetsAnHonestMessage() {
        let result = PhotoKitOperationResult.from(error: nil, succeeded: false)
        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.failureMessage)
    }

    func testForeignErrorUsesItsDescription() {
        let error = NSError(domain: "com.example", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        let result = PhotoKitOperationResult.from(error: error, succeeded: false)
        XCTAssertEqual(result.failureMessage, "Boom")
    }
}

// MARK: - Viewer seed: the thumbnail cache's any-variant lookup

/// Regression coverage for the device-reported black viewer
/// (October 2026): the grid had the tapped photo decoded at cell
/// size, but the viewer's exact-size lookup missed and the page
/// cold-decoded in the dark. The viewer now seeds from
/// `anyImage(forAssetID:)` — these tests pin that lookup down.
final class PhotoKitThumbnailCacheSeedTests: XCTestCase {

    private func makeImage(side: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    func testAnyImageFindsVariantCachedAtADifferentSize() {
        let cache = PhotoKitThumbnailCache.shared
        let assetID = "seed-test-\(UUID().uuidString)"
        // Cached the way the GRID caches: cell size, not the
        // viewer's 600 pt — the exact-size key must not be the
        // only way back to this bitmap.
        cache.set(
            makeImage(side: 120),
            forKey: PhotoKitThumbnailCache.key(assetID: assetID, size: 196, scale: 3)
        )
        XCTAssertNotNil(
            cache.anyImage(forAssetID: assetID),
            "the viewer must be able to seed from the grid's decode"
        )
    }

    func testAnyImageMissesForAnAssetNeverCached() {
        XCTAssertNil(
            PhotoKitThumbnailCache.shared.anyImage(
                forAssetID: "seed-test-absent-\(UUID().uuidString)"
            )
        )
    }

    func testAnyImagePrefersTheLargestCachedVariant() {
        let cache = PhotoKitThumbnailCache.shared
        let assetID = "seed-test-\(UUID().uuidString)"
        let small = makeImage(side: 60)
        let large = makeImage(side: 240)
        cache.set(small, forKey: PhotoKitThumbnailCache.key(assetID: assetID, size: 100, scale: 2))
        cache.set(large, forKey: PhotoKitThumbnailCache.key(assetID: assetID, size: 600, scale: 2))
        XCTAssertTrue(
            cache.anyImage(forAssetID: assetID) === large,
            "the seed should be the sharpest variant already decoded"
        )
    }
}

// MARK: - Resume guard: the video-play crash regression

/// Regression coverage for the device-reproduced crash on Play
/// (October 2026): `playerItemResult` resumed its continuation
/// unguarded inside the `requestAVAsset` callback, and PhotoKit
/// callbacks may fire more than once — a second resume of a checked
/// continuation is a fatal runtime error. The path now claims a
/// `ProbeResumeGuard` per delivery, first delivery wins; these
/// tests pin the claim semantics that guarantee it.
final class ProbeResumeGuardTests: XCTestCase {

    func testFirstClaimWinsAndLaterClaimsLose() {
        let guardBox = ProbeResumeGuard()
        XCTAssertTrue(guardBox.claim(), "the first delivery must resume the continuation")
        XCTAssertFalse(guardBox.claim(), "a second delivery must be dropped, not resumed")
        XCTAssertFalse(guardBox.claim())
    }

    func testConcurrentClaimsHaveExactlyOneWinner() {
        let guardBox = ProbeResumeGuard()
        let lock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if guardBox.claim() {
                lock.lock()
                winners += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(winners, 1, "exactly one of many racing deliveries may resume")
    }
}

// MARK: - Selection gesture timing

/// The long-press duration is user-specified at one second; pin it
/// so a future "responsiveness" tweak can't silently change the
/// selection feel again (the stacked-gesture composition it
/// replaced registered in ~2s on device despite a 0.4 value).
final class PhotoKitSelectionGestureTests: XCTestCase {

    func testLongPressDurationIsOneSecond() {
        XCTAssertEqual(PhotoKitSelectionGesture.longPressDuration, 1.0, accuracy: 0.0001)
    }
}

// MARK: - Selection model semantics

/// Behavioural pins for the value-type selection model the grid
/// and the delete flow rely on.
final class PhotoSelectionModelBehaviourTests: XCTestCase {

    func testBeginSelectsExactlyThePressedAsset() {
        var model = PhotoSelectionModel()
        model.begin(with: "a")
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.selectedIDs, ["a"])
        XCTAssertEqual(model.count, 1)
    }

    func testToggleAddsAndRemovesButNeverLeavesMode() {
        var model = PhotoSelectionModel()
        model.begin(with: "a")
        model.toggle("b")
        XCTAssertEqual(model.selectedIDs, ["a", "b"])
        model.toggle("a")
        model.toggle("b")
        XCTAssertTrue(model.isActive, "emptying the selection must not exit selection mode")
        XCTAssertTrue(model.isEmpty)
    }

    func testToggleAndSelectAllAreInertWhileInactive() {
        var model = PhotoSelectionModel()
        model.toggle("a")
        model.selectAll(["a", "b"])
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.isEmpty)
    }

    func testSelectAllUnionsWithExistingSelection() {
        var model = PhotoSelectionModel()
        model.begin(with: "a")
        model.selectAll(["b", "c"])
        XCTAssertEqual(model.selectedIDs, ["a", "b", "c"])
    }

    func testPruneDropsOnlyDepartedIDs() {
        var model = PhotoSelectionModel()
        model.begin(with: "a")
        model.selectAll(["b", "gone"])
        model.prune(toPresentIDs: ["a", "b"])
        XCTAssertEqual(model.selectedIDs, ["a", "b"])
    }

    func testCancelClearsEverything() {
        var model = PhotoSelectionModel()
        model.begin(with: "a")
        model.cancel()
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.isEmpty)
    }
}

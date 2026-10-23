import Foundation
import Photos
import UIKit

/// What one PhotoKit delivery means for a request, decided purely
/// from the delivery's flags.
///
/// Extracted as a pure function so the state machine can be pinned in
/// unit tests without PhotoKit: the box below is a thin, locked shell
/// around this decision.
enum PhotoKitDeliveryOutcome: Equatable {
    /// A degraded image arrived: publish it as a preview, keep waiting
    /// for the final one.
    case publishDegraded
    /// The final image arrived: finish with it.
    case finishWithImage
    /// The request is over and there is no final image: finish with
    /// the degraded fallback (or `nil` when there was none).
    case finishWithFallback
    /// Nothing actionable yet (a degraded signal with no image).
    case keepWaiting

    /// Decide from one delivery.
    ///
    /// The rule that matters: **every non-degraded delivery is
    /// terminal.** PhotoKit's result handler for `requestImage` fires
    /// either with `PHImageResultIsDegradedKey` set (a preview, more
    /// coming) or as the final answer. A final delivery can carry no
    /// image and *no error* — most importantly when the request was
    /// cancelled at the PhotoKit level (`PHImageCancelledKey`), which
    /// arrives exactly like that. The previous implementation treated
    /// "no image, no error" as "keep waiting", so a cancelled final
    /// delivery left the continuation unresumed forever and the
    /// viewer sat on a black screen (device-reported, October 2026).
    static func decide(
        imagePresent: Bool,
        degraded: Bool,
        failed: Bool,
        cancelled: Bool
    ) -> PhotoKitDeliveryOutcome {
        if degraded {
            return imagePresent ? .publishDegraded : .keepWaiting
        }
        if imagePresent {
            return .finishWithImage
        }
        // Final delivery, no image. Failed, cancelled, or simply empty:
        // all three are terminal — nothing more is coming.
        return .finishWithFallback
    }
}

/// Bookkeeping for one in-flight image request.
///
/// PhotoKit's result handler may fire more than once for an
/// opportunistic request — first with a degraded image, then the good
/// one — and the continuation must be resumed exactly once. The box
/// makes that explicit, and carries the request id so a cancellation
/// can reach PhotoKit.
///
/// Beyond the final image, the box surfaces two things the caller
/// used to never see: the degraded preview (so the viewer can show
/// *something* the moment it arrives instead of a spinner) and the
/// download progress (so an iCloud fetch can say so instead of
/// looking hung).
///
/// Every field is guarded by a lock: PhotoKit calls the result
/// handler on its own queue, and the cancellation handler runs on
/// whichever thread cancelled the task. `@unchecked Sendable`
/// because the lock is what makes it safe, and Swift cannot see that
/// through a class.
///
/// The continuation is resumed **outside** the lock, and the
/// callbacks are invoked outside it too. `resume` can run the
/// awaiting task inline on the calling thread, and that task may call
/// back into the box — holding the lock across a `resume` is a
/// deadlock waiting for the right interleaving.
///
/// Implementation note: the lock is taken with explicit `lock()` /
/// `unlock()` pairs and plain local variables instead of
/// value-returning `withLock` closures. The previous formulation —
/// generic `withLock` closures returning an enum with an associated
/// value, in this specific combination of `NSLock`,
/// `CheckedContinuation` and a `UIImage?` payload — sent the Swift
/// compiler's post-type-check phases into a non-terminating loop on
/// the Xcode 26.6 toolchain (diagnosed by file-level bisection in
/// CI, October 2026). The behaviour is unchanged.
final class PhotoKitRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    /// The degraded image, kept as a fallback in case the good one
    /// never arrives.
    private var degradedImage: UIImage?
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var resumed = false
    /// Set by `cancel()``. Kept separately from `resumed` because a
    /// cancellation can arrive *before* the continuation is attached,
    /// and the request id still has to be cancelled once it is known.
    private var cancelled = false

    /// Called (outside the lock) whenever a degraded preview arrives.
    /// Set before the request is issued.
    var onDegradedImage: ((UIImage) -> Void)?
    /// Called (outside the lock) with download progress 0...1 while
    /// PhotoKit fetches the asset (iCloud). Set before the request is
    /// issued.
    var onProgress: ((Double) -> Void)?

    /// Hand the continuation over before the request is issued, so a
    /// result that arrives immediately still finds one.
    func attach(_ continuation: CheckedContinuation<UIImage?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Record the request id. If the request was already cancelled,
    /// the id is cancelled right away rather than leaked.
    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            PHImageManager.default().cancelImageRequest(id)
        }
    }

    /// Forward a progress update from PhotoKit's progress handler.
    func updateProgress(_ progress: Double) {
        let handler = onProgress
        handler?(progress)
    }

    /// Hand a delivery to the continuation — at most once.
    func deliver(_ image: UIImage?, degraded: Bool, failed: Bool, cancelled: Bool = false) {
        let outcome = PhotoKitDeliveryOutcome.decide(
            imagePresent: image != nil,
            degraded: degraded,
            failed: failed,
            cancelled: cancelled
        )
        // The state update happens under the lock; the resume and the
        // preview callback happen after it is released.
        lock.lock()
        var shouldResume = false
        var resumeImage: UIImage?
        var degradedToPublish: UIImage?
        switch outcome {
        case .publishDegraded:
            if let image {
                degradedImage = image
                degradedToPublish = image
            }
        case .finishWithImage:
            shouldResume = true
            resumeImage = image
        case .finishWithFallback:
            shouldResume = true
            resumeImage = degradedImage
        case .keepWaiting:
            break
        }
        lock.unlock()
        if let degradedToPublish {
            onDegradedImage?(degradedToPublish)
        }
        if shouldResume {
            resume(with: resumeImage)
        }
    }

    /// Cancel the request and release the continuation.
    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        resume(with: nil)
        if id != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(id)
        }
    }

    /// Resume exactly once, outside the lock.
    private func resume(with image: UIImage?) {
        lock.lock()
        var toResume: CheckedContinuation<UIImage?, Never>?
        if !resumed, let continuation {
            resumed = true
            self.continuation = nil
            toResume = continuation
        }
        lock.unlock()
        toResume?.resume(returning: image)
    }
}

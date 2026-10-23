import Foundation
import Photos
import UIKit

/// Bookkeeping for one in-flight image request.
///
/// PhotoKit's result handler may fire more than once for an opportunistic
/// request — first with a degraded image, then the good one — and the
/// continuation must be resumed exactly once. The box makes that
/// explicit, and carries the request id so a cancellation can reach
/// PhotoKit.
///
/// Every field is guarded by a lock: PhotoKit calls the result handler on
/// its own queue, and the cancellation handler runs on whichever thread
/// cancelled the task. `@unchecked Sendable` because the lock is what
/// makes it safe, and Swift cannot see that through a class.
///
/// The continuation is resumed **outside** the lock. `resume` can run the
/// awaiting task inline on the calling thread, and that task may call back
/// into the box (a second PhotoKit delivery arriving on another thread
/// would block on the lock, while the inline task waits for it) — so
/// holding the lock across a `resume` is a deadlock waiting for the right
/// interleaving.
final class PhotoKitRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    /// The degraded image, kept as a fallback in case the good one never
    /// arrives.
    private var degradedImage: UIImage?
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var resumed = false
    /// Set by `cancel()`. Kept separately from `resumed` because a
    /// cancellation can arrive *before* the continuation is attached, and
    /// the request id still has to be cancelled once it is known.
    private var cancelled = false

    /// Hand the continuation over before the request is issued, so a
    /// result that arrives immediately still finds one.
    func attach(_ continuation: CheckedContinuation<UIImage?, Never>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    /// Record the request id. If the request was already cancelled, the
    /// id is cancelled right away rather than leaked.
    func setRequestID(_ id: PHImageRequestID) {
        let shouldCancel: Bool = lock.withLock {
            requestID = id
            return cancelled
        }
        if shouldCancel {
            PHImageManager.default().cancelImageRequest(id)
        }
    }

    /// Hand a delivery to the continuation — at most once.
    func deliver(_ image: UIImage?, degraded: Bool, failed: Bool) {
        // The decision is made under the lock; the resume happens after it
        // is released.
        let decision: Decision = lock.withLock {
            if degraded {
                // A degraded delivery is a placeholder — the good one is
                // still coming. Keep it as a fallback, but do not resume:
                // resuming here would hand the caller the small image and
                // never the real one.
                if let image { degradedImage = image }
                return .keepWaiting
            }
            if failed, image == nil {
                // Nothing more is coming. Fall back to the degraded image if
                // there was one, so a cell shows a small picture rather than
                // nothing at all.
                return .finish(degradedImage)
            }
            guard let image else { return .keepWaiting }
            return .finish(image)
        }
        if case .finish(let image) = decision {
            resume(with: image)
        }
    }

    /// Cancel the request and release the continuation.
    func cancel() {
        let id: PHImageRequestID = lock.withLock {
            cancelled = true
            return requestID
        }
        resume(with: nil)
        if id != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(id)
        }
    }

    /// Resume exactly once, outside the lock.
    private func resume(with image: UIImage?) {
        let continuation: CheckedContinuation<UIImage?, Never>? = lock.withLock {
            guard !resumed, let continuation else { return nil }
            resumed = true
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: image)
    }

    /// What a PhotoKit delivery means for the pending continuation.
    private enum Decision {
        /// Keep waiting — a degraded image arrived, or a delivery carried
        /// no image and no error.
        case keepWaiting
        /// This is the last delivery; resume with the given image (which
        /// may be `nil`).
        case finish(UIImage?)
    }
}


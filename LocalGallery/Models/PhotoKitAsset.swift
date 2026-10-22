import Foundation
import Photos

/// One item in the device's own Photos library ("Camera Roll").
///
/// A plain value rather than a `PHAsset`: the PhotoKit object is neither
/// `Sendable` nor safe to carry across an actor boundary, and every screen
/// that draws an asset lives on the main actor. The value carries
/// everything the UI needs; `PhotoKitService` resolves the underlying
/// `PHAsset` by `localIdentifier` when it needs pixels.
struct PhotoKitAsset: Identifiable, Hashable, Sendable {
    /// `PHAsset.localIdentifier` — stable for the life of the asset.
    let id: String
    /// The original filename, when PhotoKit knows one.
    let filename: String
    let isVideo: Bool
    /// True for a Live Photo (an image with a paired video part).
    let isLivePhoto: Bool
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    /// Seconds. Zero for stills.
    let duration: Double

    /// Build from a PhotoKit object.
    ///
    /// A struct member is not actor-isolated, so this can be called from
    /// the background fetch that produces the library's asset list — which
    /// is where it is called from, because walking 20k PhotoKit objects on
    /// the main thread is a visible stall.
    init(asset: PHAsset) {
        id = asset.localIdentifier
        // `PHAsset` has no filename of its own — the original name lives on
        // the primary `PHAssetResource`. Fall back to the local identifier's
        // name component so the field is never empty.
        filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
            ?? asset.localIdentifier
        isVideo = asset.mediaType == .video
        isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        creationDate = asset.creationDate
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
        duration = asset.duration
    }

    /// Build one directly.
    ///
    /// PhotoKit cannot be faked in a unit test, so the pure parts of the
    /// timeline (grouping, ordering) are pinned against assets made this
    /// way rather than against a real library.
    init(
        id: String,
        filename: String = "IMG_0001.JPG",
        isVideo: Bool = false,
        isLivePhoto: Bool = false,
        creationDate: Date? = nil,
        pixelWidth: Int = 4032,
        pixelHeight: Int = 3024,
        duration: Double = 0
    ) {
        self.id = id
        self.filename = filename
        self.isVideo = isVideo
        self.isLivePhoto = isLivePhoto
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }

    /// The video's duration as "m:ss" / "h:mm:ss".
    var durationLabel: String {
        isVideo ? VideoTimeFormat.string(duration) : ""
    }
}

/// The device's Photos-library access level, as the UI reasons about it.
///
/// A top-level type rather than a nested one so a test can reach it
/// without an actor hop — `PhotoKitService` is `@MainActor`, and a nested
/// type inside it inherits that isolation.
enum PhotoKitAuthorization: Equatable, Sendable {
    /// The user has not been asked yet.
    case notDetermined
    /// Blocked by device policy (Screen Time, MDM). The app cannot ask.
    case restricted
    /// The user said no.
    case denied
    /// The user picked a subset of the library. The library is readable,
    /// but only the selected assets.
    case limited
    /// Full access.
    case authorized

    /// Whether the library can be read at all.
    var isReadable: Bool {
        self == .authorized || self == .limited
    }

    /// Map PhotoKit's status onto the states above.
    ///
    /// `nonisolated` because it is called from a `@MainActor` service *and*
    /// from a test; keeping it free of isolation makes both trivial.
    nonisolated static func map(_ status: PHAuthorizationStatus) -> PhotoKitAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .limited: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }
}

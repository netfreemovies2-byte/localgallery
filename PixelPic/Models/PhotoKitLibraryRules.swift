import Foundation

/// The rules the photo-library screens follow, as pure functions.
///
/// The rules themselves are simple — an album's place in the grid, when
/// an album has more to load, how a section is titled — but they are
/// the parts a screenshot cannot pin. PhotoKit cannot be faked in a unit
/// test, so the *shapes* it produces (albums, assets) are ordinary value
/// types, and the rules that consume them are ordinary functions over
/// those values.
///
/// A top-level type rather than a member of `PhotoKitService`, because
/// the service is `@MainActor` and a nested type inherits that
/// isolation — which would make these rules unreachable from a test
/// without an actor hop. The repo's convention is the same: `PhotoSection`
/// (the folder grid's) is a top-level struct for exactly this reason.
enum PhotoKitLibraryRules {

    // MARK: - Album order

    /// The order albums appear in.
    ///
    /// A rule rather than an accident: Camera first, then the other
    /// filters over the library (Screenshots, Videos, Favorites), then
    /// the user's own albums — which are the only ones whose order is
    /// meaningful to them, so they keep the order the system gave them.
    ///
    /// Stable within each rank: the user's albums are not re-sorted, only
    /// moved as a block.
    static func ordered(_ albums: [PhotoKitAlbum]) -> [PhotoKitAlbum] {
        let rank: [PhotoKitAlbum.Kind: Int] = [
            .camera: 0,
            .screenshots: 1,
            .videos: 2,
            .favorites: 3,
            .user: 4,
        ]
        return albums.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.kind] ?? 5
                let rhsRank = rank[rhs.element.kind] ?? 5
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                // Same rank — keep the original order. `enumerated()`'s
                // offset is the tiebreaker, and it is unique, so the sort
                // is total and stable.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Camera membership

    /// Whether an asset belongs in the Camera album, decided from the
    /// metadata PhotoKit exposes.
    ///
    /// Pure and value-based so the rule can be pinned in a test: the
    /// service extracts the three inputs from each `PHAsset` and this
    /// function decides. See `PhotoKitService` for why these are the
    /// signals used, and for the limits of what iOS can tell us.
    static func isCameraCapture(
        isScreenshot: Bool,
        isSyncedFromComputer: Bool,
        isCloudShared: Bool
    ) -> Bool {
        !isScreenshot && !isSyncedFromComputer && !isCloudShared
    }

    // MARK: - Camera membership, EXIF tier

    /// Whether an asset is a **confirmed** Camera capture.
    ///
    /// Two tiers, both required:
    ///
    /// 1. the PhotoKit tier above (`isCameraCapture`) — not a
    ///    screenshot, not synced from a computer, not from a shared
    ///    album;
    /// 2. positive camera evidence in the asset's own metadata
    ///    (`CameraMetadataEvidence.hasAppleCameraEvidence`) — the
    ///    file itself says an Apple camera wrote it.
    ///
    /// Tier 2 is what keeps app-saved images (WhatsApp and browser
    /// downloads, which arrive with camera EXIF stripped) out of
    /// Camera: they pass tier 1 but carry no evidence. The honest
    /// limits of tier 2, documented in `PhotoKitService` as well:
    /// AirDrop media from another iPhone keeps its Apple EXIF and
    /// *will* classify as Camera (it is an iPhone camera capture —
    /// EXIF carries no device identity, so "captured by *this*
    /// iPhone" cannot be proven); Pixel Pic's own edited copies are
    /// written without camera EXIF and will *not* appear in Camera.
    static func isConfirmedCameraCapture(
        isScreenshot: Bool,
        isSyncedFromComputer: Bool,
        isCloudShared: Bool,
        evidence: CameraMetadataEvidence
    ) -> Bool {
        isCameraCapture(
            isScreenshot: isScreenshot,
            isSyncedFromComputer: isSyncedFromComputer,
            isCloudShared: isCloudShared
        ) && evidence.hasAppleCameraEvidence
    }

    // MARK: - Home grid (visibility + sort)

    /// How the user's own albums are ordered on the home grid.
    enum AlbumHomeSort: Int, CaseIterable {
        /// The order the service produced (system order).
        case serviceOrder = 0
        case name = 1
        case mostItems = 2
    }

    /// The albums the home grid shows, from the service's list.
    ///
    /// One pure derivation so the grid, the count of what's hidden,
    /// and the tests all agree:
    ///
    /// * **Visibility:** empty *user* albums are hidden unless
    ///   `showEmptyAlbums` is on. System albums are never hidden by
    ///   this rule — Camera is the primary album and stays visible at
    ///   zero, and the other system filters only exist in the list
    ///   when they have content.
    /// * **Order:** system albums keep their ranked places first
    ///   (`ordered(_:)`), and only the user albums are re-sorted —
    ///   by name or by size when the user picked a sort, never
    ///   disturbing the pinned system block.
    /// * **Search:** a non-empty query filters by title
    ///   (case-insensitive substring) across both blocks.
    static func homeAlbums(
        _ albums: [PhotoKitAlbum],
        showEmptyAlbums: Bool,
        sort: AlbumHomeSort,
        searchQuery: String = ""
    ) -> [PhotoKitAlbum] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = ordered(albums).filter { album in
            if !showEmptyAlbums, album.kind == .user, album.count == 0 {
                return false
            }
            if !query.isEmpty, !album.title.lowercased().contains(query) {
                return false
            }
            return true
        }
        let system = visible.filter { $0.kind != .user }
        var user = visible.filter { $0.kind == .user }
        switch sort {
        case .serviceOrder:
            break
        case .name:
            user.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .mostItems:
            user.sort { $0.count > $1.count }
        }
        return system + user
    }

    // MARK: - Paging

    /// Whether an album grid has more assets to pull in.
    ///
    /// The total comes from PhotoKit's own count, so this is exact
    /// without loading every asset — and the paging sentinel disappears
    /// by itself once the whole album is on screen.
    static func hasMore(fetched: Int, total: Int) -> Bool {
        fetched < total
    }

    /// The offset the next page starts at.
    ///
    /// Offset-based rather than "fetch N again": the offset survives a
    /// photo being deleted (the page simply comes back short) and the
    /// fetch does not re-walk everything already on screen.
    static func nextOffset(fetched: Int) -> Int {
        max(0, fetched)
    }

    /// How many assets a page fetches.
    static func pageSize(fetched: Int, total: Int, page: Int) -> Int {
        let remaining = max(0, total - fetched)
        return max(1, min(page, remaining))
    }

    // MARK: - Readout

    /// The viewer's "N of M" label.
    ///
    /// `total` is the size of the *collection* being browsed — one album
    /// for a drill-in — and it is deliberately separate from the number
    /// of assets that have been paged in. An album grid pages in 600 at
    /// a time, so using the paged count would read "12 of 600" in an
    /// album that holds 12,043 photos: a number that looks plausible
    /// and is wrong.
    ///
    /// A `total` below the current position would be nonsense (the user
    /// swiped past the end), so the browsed count is used as the floor —
    /// the readout then degrades to "N of N" rather than "N of 3" while
    /// the fourth photo is showing.
    static func positionLabel(index: Int, total: Int?, browsed: Int) -> String {
        let count = max(browsed, total ?? 0)
        let position = max(1, index + 1)
        return "\(position) of \(count)"
    }
}

/// The camera evidence found in one asset's own metadata, extracted
/// from the file (EXIF/TIFF for photos, QuickTime metadata for
/// videos) by `PhotoKitService`'s probe.
///
/// A plain value type on purpose: extraction needs PhotoKit and
/// ImageIO, but the *decision* — `hasAppleCameraEvidence` — is pure
/// and unit-testable over these fields.
struct CameraMetadataEvidence: Equatable {
    /// TIFF Make (photos) — the camera manufacturer string.
    var tiffMake: String?
    /// TIFF Model (photos) — the camera model string.
    var tiffModel: String?
    /// Whether a MakerApple dictionary is present. Only Apple
    /// devices write one, so on its own (with exposure data) it is
    /// strong evidence even when the TIFF Make went missing.
    var hasMakerAppleDictionary = false
    /// Whether real exposure fields (exposure time, f-number, ISO)
    /// are present — something a camera writes and a screenshot or
    /// an app re-save does not invent.
    var hasExposureFields = false
    /// QuickTime Make (videos).
    var quickTimeMake: String?
    /// QuickTime Model (videos).
    var quickTimeModel: String?

    /// No evidence found (extraction failed, the asset is not on the
    /// device, or the file carries no camera metadata at all).
    static let none = CameraMetadataEvidence()

    /// Whether the metadata positively identifies an Apple camera
    /// as the origin:
    ///
    /// * the Make (TIFF or QuickTime) is "Apple" (case-insensitive)
    ///   **and** at least one corroborating field is present — a
    ///   model string, a MakerApple dictionary, or exposure data; or
    /// * a MakerApple dictionary **and** exposure data are both
    ///   present (the Make string alone went missing, but only an
    ///   Apple camera writes either of these).
    ///
    /// Anything weaker — a bare model name, exposure data from a
    /// non-Apple camera — is not evidence *for this album*: Camera
    /// means iPhone captures, and a Canon file is not one.
    var hasAppleCameraEvidence: Bool {
        let makes = [tiffMake, quickTimeMake]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let models = [tiffModel, quickTimeModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let makeIsApple = makes.contains("apple")
        let hasModel = models.contains { !$0.isEmpty }
        if makeIsApple && (hasModel || hasMakerAppleDictionary || hasExposureFields) {
            return true
        }
        return hasMakerAppleDictionary && hasExposureFields
    }
}

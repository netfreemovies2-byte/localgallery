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

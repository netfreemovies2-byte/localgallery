import Foundation

/// The rules the photo-library screens follow, as pure functions.
///
/// The rules themselves are simple — an album's place in the grid, when
/// the timeline has more to load, how a section is titled — but they are
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
    /// A rule rather than an accident: the system albums a user reaches
    /// for come first (Camera Roll, Recents), then the ones that are
    /// filters over the library (Screenshots, Videos, Favorites), then
    /// the user's own albums — which are the only ones whose order is
    /// meaningful to them, so they keep the order the system gave them.
    ///
    /// Stable within each rank: the user's albums are not re-sorted, only
    /// moved as a block.
    static func ordered(_ albums: [PhotoKitAlbum]) -> [PhotoKitAlbum] {
        let rank: [PhotoKitAlbum.Kind: Int] = [
            .cameraRoll: 0,
            .recents: 1,
            .screenshots: 2,
            .videos: 3,
            .favorites: 4,
            .user: 5,
        ]
        return albums.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.kind] ?? 6
                let rhsRank = rank[rhs.element.kind] ?? 6
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                // Same rank — keep the original order. `enumerated()`'s
                // offset is the tiebreaker, and it is unique, so the sort
                // is total and stable.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Paging

    /// Whether the timeline has more assets to pull in.
    ///
    /// The total comes from PhotoKit's own count, so this is exact
    /// without loading every asset — and the paging sentinel disappears
    /// by itself once the whole library is on screen.
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
    /// `total` is the size of the *collection* being browsed — the whole
    /// library for the timeline, one album for a drill-in — and it is
    /// deliberately separate from the number of assets that have been
    /// paged in. The timeline pages in 600 at a time, so using the paged
    /// count would read "12 of 600" on a library that holds 12,043
    /// photos: a number that looks plausible and is wrong.
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

import Foundation

/// Selection state for an album grid, as a value type.
///
/// The selection is a set of asset *identifiers*, never indexes or
/// asset objects: grid cells are recycled as the user scrolls, and
/// the underlying list can be reloaded (a library change, a page
/// landing) while a selection is in progress. IDs survive both —
/// an index would silently point at a different photo after either.
///
/// Pure value semantics so the behaviour (toggle, select-all,
/// cancel, pruning ids that left the album) is unit-testable without
/// a view.
struct PhotoSelectionModel: Equatable {
    /// Whether selection mode is on. Entering always starts from a
    /// long-press on one cell, so a fresh selection has one member.
    private(set) var isActive = false
    /// The selected asset identifiers.
    private(set) var selectedIDs: Set<String> = []

    var count: Int { selectedIDs.count }
    var isEmpty: Bool { selectedIDs.isEmpty }

    func contains(_ assetID: String) -> Bool {
        selectedIDs.contains(assetID)
    }

    /// Enter selection mode with `assetID` selected (the long-press).
    mutating func begin(with assetID: String) {
        isActive = true
        selectedIDs = [assetID]
    }

    /// Toggle one asset. Toggling the last one off leaves selection
    /// mode *on* (with an empty selection) — the system Photos app
    /// behaves the same way; only Cancel (or finishing an action)
    /// leaves the mode.
    mutating func toggle(_ assetID: String) {
        guard isActive else { return }
        if selectedIDs.contains(assetID) {
            selectedIDs.remove(assetID)
        } else {
            selectedIDs.insert(assetID)
        }
    }

    /// Select everything currently in the album.
    mutating func selectAll(_ assetIDs: [String]) {
        guard isActive else { return }
        selectedIDs.formUnion(assetIDs)
    }

    /// Leave selection mode and forget the selection.
    mutating func cancel() {
        isActive = false
        selectedIDs = []
    }

    /// Drop ids that are no longer in the album (deleted elsewhere,
    /// removed by a move). Keeps the toolbar count honest after a
    /// reload replaces the grid's list.
    mutating func prune(toPresentIDs presentIDs: Set<String>) {
        selectedIDs.formIntersection(presentIDs)
    }

    /// The selection in the album's own order, for actions that
    /// present or export the items in grid order.
    func orderedSelection(from albumAssets: [PhotoKitAsset]) -> [PhotoKitAsset] {
        albumAssets.filter { selectedIDs.contains($0.id) }
    }
}

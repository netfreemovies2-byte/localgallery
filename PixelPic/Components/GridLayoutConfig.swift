import SwiftUI

struct GridLayoutConfig {
    let sizeTier: Int
    let isLandscape: Bool

    static let tierCount = 4

    private static let portraitColumns = [2, 3, 4, 5]
    private static let landscapeColumns = [3, 5, 7, 9]

    var columnCount: Int {
        let table = isLandscape ? Self.landscapeColumns : Self.portraitColumns
        let idx = min(max(sizeTier, 0), table.count - 1)
        return table[idx]
    }

    func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    func cellSize(for width: CGFloat) -> CGFloat {
        let cols = columnCount
        return max(1, (width - CGFloat(cols - 1) * 2) / CGFloat(cols))
    }

    var gridIconName: String {
        switch sizeTier {
        case 0: return "square.grid.2x2"
        case 1: return "square.grid.3x3"
        case 2: return "square.grid.3x3.fill"
        default: return "square.grid.4x3.fill"
        }
    }

    /// The name of the tier the *next* tap lands on.
    ///
    /// The button shows the density you will get, not the one you have —
    /// the way the iOS Photos grid button works, and the only way the icon
    /// can be unambiguous: "2×2" next to a 3-column grid means "tap for 2
    /// columns", which reads backwards on its own. The accessibility label
    /// names the same *next* density, so the spoken form and the icon agree.
    static func nextTier(from tier: Int) -> Int {
        let clamped = min(max(tier, 0), GridLayoutConfig.tierCount - 1)
        return (clamped + 1) % GridLayoutConfig.tierCount
    }

    /// The icon for the density the next tap lands on.
    var nextTierIconName: String {
        GridLayoutConfig(sizeTier: Self.nextTier(from: sizeTier), isLandscape: isLandscape).gridIconName
    }

    /// Spoken description of the button, so the icon is not the only way
    /// the action is described.
    var nextTierAccessibilityLabel: String {
        let next = Self.nextTier(from: sizeTier)
        let columns = GridLayoutConfig(sizeTier: next, isLandscape: isLandscape).columnCount
        return "Grid size, \(columns) columns"
    }
}

import Foundation

// Pure value types and logic for the Camera Roll (PhotoKit) feature.
//
// Nothing here imports Photos or UIKit, so it is unit-testable without a
// photo library. The folder-backed `PhotoFile` model is deliberately NOT
// touched: Photos assets are identified by `PHAsset.localIdentifier`, not by
// a file URL, so they live in their own small model.

/// One photo or video in the user's Photos library.
struct CameraRollItem: Identifiable, Hashable, Sendable {
    /// `PHAsset.localIdentifier`.
    let id: String
    var creationDate: Date?
    var isVideo: Bool
    /// True for animated images (GIF). Maps to `PHAsset.playbackStyle == .imageAnimated`.
    var isAnimated: Bool
    var isFavorite: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    /// Seconds; 0 for stills.
    var duration: TimeInterval

    init(
        id: String,
        creationDate: Date? = nil,
        isVideo: Bool = false,
        isAnimated: Bool = false,
        isFavorite: Bool = false,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.creationDate = creationDate
        self.isVideo = isVideo
        self.isAnimated = isAnimated
        self.isFavorite = isFavorite
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }
}

/// A real Photos album (user album, shared album, or a system smart album).
/// App-defined groupings are not albums and are not represented here.
struct CameraRollAlbum: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        case smart
        case user
    }

    /// `PHAssetCollection.localIdentifier`.
    let id: String
    var title: String
    var assetCount: Int
    var source: Source
    /// `PHAssetCollection.assetCollectionSubtype.rawValue` — used to order
    /// system albums; 0 for user albums.
    var subtypeRaw: Int = 0
}

enum CameraRollMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case photos
    case videos
    case animated
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .animated: "GIFs"
        case .favorites: "Favorites"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .photos: "photo"
        case .videos: "video"
        case .animated: "livephoto"
        case .favorites: "heart"
        }
    }

    func matches(_ item: CameraRollItem) -> Bool {
        switch self {
        case .all: true
        case .photos: !item.isVideo
        case .videos: item.isVideo
        case .animated: item.isAnimated
        case .favorites: item.isFavorite
        }
    }
}

enum CameraRollGrouping: String, CaseIterable, Identifiable, Sendable {
    case day
    case month

    var id: String { rawValue }
    var title: String { self == .day ? "By day" : "By month" }
}

struct CameraRollSection: Identifiable, Hashable, Sendable {
    /// Stable key, e.g. `2026-10-21` or `2026-10`; `undated` for items with no date.
    let id: String
    var title: String
    var items: [CameraRollItem]
}

/// Filtering, sorting, searching and date grouping. Pure functions.
enum CameraRollQuery {

    /// Applies the persistent "include videos" setting, the filter chip, the
    /// search text, and the sort order — in that order.
    ///
    /// Sorting is by creation date only. PhotoKit does not expose file names
    /// or sizes cheaply for a whole library, so name/size sorting is not offered.
    /// Items with no date sort last in either direction.
    static func apply(
        to items: [CameraRollItem],
        includeVideos: Bool,
        filter: CameraRollMediaFilter,
        searchText: String,
        newestFirst: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [CameraRollItem] {
        var result = items
        if !includeVideos {
            result = result.filter { !$0.isVideo }
        }
        if filter != .all {
            result = result.filter(filter.matches)
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let needle = trimmed.lowercased()
            let formatters = DateSearchFormatters(calendar: calendar, locale: locale)
            result = result.filter { matches($0, needle: needle, formatters: formatters) }
        }
        return sorted(result, newestFirst: newestFirst)
    }

    static func sorted(_ items: [CameraRollItem], newestFirst: Bool) -> [CameraRollItem] {
        items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.creationDate, rhs.element.creationDate) {
            case let (a?, b?):
                if a == b { return lhs.offset < rhs.offset }   // stable
                return newestFirst ? a > b : a < b
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }.map(\.element)
    }

    /// Case-insensitive match against media keywords ("video", "gif",
    /// "favorite") and the date spelled several ways: year, month name,
    /// "October 2026", ISO date, and numeric `yyyy-MM`.
    static func matches(
        _ item: CameraRollItem,
        search: String,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Bool {
        matches(item, needle: search.lowercased(), formatters: DateSearchFormatters(calendar: calendar, locale: locale))
    }

    fileprivate static func matches(
        _ item: CameraRollItem,
        needle: String,
        formatters: DateSearchFormatters
    ) -> Bool {
        var haystack: [String] = []
        haystack.append(item.isVideo ? "video" : "photo")
        if item.isAnimated { haystack.append("gif animated") }
        if item.isFavorite { haystack.append("favorite favourite") }
        if let date = item.creationDate {
            haystack.append(contentsOf: formatters.strings(for: date))
        }
        return haystack.contains { $0.lowercased().contains(needle) }
    }

    /// Splits an already-sorted array into consecutive sections. Order of
    /// items is preserved; a new section starts whenever the key changes, so
    /// both newest-first and oldest-first input group correctly.
    static func sections(
        from items: [CameraRollItem],
        grouping: CameraRollGrouping,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [CameraRollSection] {
        let keyFormatter = DateFormatter()
        keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.calendar = calendar
        keyFormatter.timeZone = calendar.timeZone
        keyFormatter.dateFormat = grouping == .day ? "yyyy-MM-dd" : "yyyy-MM"

        let titleFormatter = DateFormatter()
        titleFormatter.locale = locale
        titleFormatter.calendar = calendar
        titleFormatter.timeZone = calendar.timeZone
        titleFormatter.setLocalizedDateFormatFromTemplate(grouping == .day ? "EEEEdMMMMyyyy" : "MMMMyyyy")

        var sections: [CameraRollSection] = []
        for item in items {
            let key: String
            let title: String
            if let date = item.creationDate {
                key = keyFormatter.string(from: date)
                title = titleFormatter.string(from: date)
            } else {
                key = "undated"
                title = "Unknown date"
            }
            if let last = sections.last, last.id == key {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(CameraRollSection(id: key, title: title, items: [item]))
            }
        }
        return sections
    }
}

/// Which albums the user sees. Hiding is an app-level preference keyed by
/// the album's `localIdentifier`; it never changes anything in Photos.
enum CameraRollAlbumVisibility {
    static func visible(
        _ albums: [CameraRollAlbum],
        hiddenIDs: Set<String>,
        showHidden: Bool
    ) -> [CameraRollAlbum] {
        showHidden ? albums : albums.filter { !hiddenIDs.contains($0.id) }
    }
}

/// Multi-select state for the grid.
struct CameraRollSelection: Equatable, Sendable {
    private(set) var ids: Set<String> = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    mutating func selectAll(_ items: [CameraRollItem]) {
        ids = Set(items.map(\.id))
    }

    mutating func clear() { ids.removeAll() }

    /// Drops ids that no longer exist (after a library change or delete).
    mutating func prune(keeping items: [CameraRollItem]) {
        let live = Set(items.map(\.id))
        ids.formIntersection(live)
    }

    /// Selected items in the order they appear in `items`.
    func resolve(in items: [CameraRollItem]) -> [CameraRollItem] {
        items.filter { ids.contains($0.id) }
    }
}

/// Built once per search so filtering a large library does not allocate
/// formatters per item.
private struct DateSearchFormatters {
    private let formatters: [DateFormatter]

    init(calendar: Calendar, locale: Locale) {
        let patterns = ["yyyy", "MMMM", "MMM", "MMMM yyyy", "MMMM d yyyy", "d MMMM yyyy", "yyyy-MM", "yyyy-MM-dd"]
        formatters = patterns.map { pattern in
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = pattern
            return f
        }
    }

    func strings(for date: Date) -> [String] {
        formatters.map { $0.string(from: date) }
    }
}

import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import LocalGallery

/// Logic tests for the Camera Roll (PhotoKit) feature. These do not touch the
/// real Photos library: authorization prompts and live asset loading need a
/// device or a simulator with a seeded library and are covered by the manual
/// checklist in docs/camera-roll.md.
final class CameraRollQueryTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private let posix = Locale(identifier: "en_US_POSIX")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return utc.date(from: comps)!
    }

    private func sample() -> [CameraRollItem] {
        [
            CameraRollItem(id: "a", creationDate: date(2026, 1, 5), isVideo: false),
            CameraRollItem(id: "b", creationDate: date(2026, 3, 9), isVideo: true, duration: 12),
            CameraRollItem(id: "c", creationDate: date(2025, 12, 31), isAnimated: true),
            CameraRollItem(id: "d", creationDate: nil, isFavorite: true),
            CameraRollItem(id: "e", creationDate: date(2026, 3, 9, 18), isVideo: false),
        ]
    }

    private func run(
        includeVideos: Bool = true,
        filter: CameraRollMediaFilter = .all,
        search: String = "",
        newestFirst: Bool = true
    ) -> [String] {
        CameraRollQuery.apply(
            to: sample(), includeVideos: includeVideos, filter: filter,
            searchText: search, newestFirst: newestFirst, calendar: utc, locale: posix
        ).map(\.id)
    }

    func testNewestFirstPutsUndatedLast() {
        XCTAssertEqual(run(newestFirst: true), ["e", "b", "a", "c", "d"])
    }

    func testOldestFirstReversesDatedItemsAndKeepsUndatedLast() {
        XCTAssertEqual(run(newestFirst: false), ["c", "a", "b", "e", "d"])
    }

    func testExcludingVideosRemovesThemEverywhere() {
        XCTAssertFalse(run(includeVideos: false).contains("b"))
        XCTAssertTrue(run(includeVideos: false, filter: .videos).isEmpty)
    }

    func testFilters() {
        XCTAssertEqual(Set(run(filter: .videos)), ["b"])
        XCTAssertEqual(Set(run(filter: .photos)), ["a", "c", "d", "e"])
        XCTAssertEqual(Set(run(filter: .animated)), ["c"])
        XCTAssertEqual(Set(run(filter: .favorites)), ["d"])
    }

    func testSearchMatchesMonthYearAndISODate() {
        XCTAssertEqual(Set(run(search: "march")), ["b", "e"])
        XCTAssertEqual(Set(run(search: "2025")), ["c"])
        XCTAssertEqual(Set(run(search: "2026-01-05")), ["a"])
        XCTAssertEqual(Set(run(search: "March 2026")), ["b", "e"])
    }

    func testSearchMatchesMediaKeywords() {
        XCTAssertEqual(Set(run(search: "video")), ["b"])
        XCTAssertEqual(Set(run(search: "gif")), ["c"])
        XCTAssertEqual(Set(run(search: "favorite")), ["d"])
    }

    func testBlankSearchReturnsEverything() {
        XCTAssertEqual(run(search: "   ").count, 5)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(run(search: "zzzz").isEmpty)
    }

    func testSortIsStableForEqualDates() {
        let same = date(2026, 5, 1)
        let items = (0..<5).map { CameraRollItem(id: "i\($0)", creationDate: same) }
        XCTAssertEqual(CameraRollQuery.sorted(items, newestFirst: true).map(\.id), items.map(\.id))
        XCTAssertEqual(CameraRollQuery.sorted(items, newestFirst: false).map(\.id), items.map(\.id))
    }

    // MARK: Date grouping

    func testMonthGroupingNewestFirst() {
        let sorted = CameraRollQuery.apply(
            to: sample(), includeVideos: true, filter: .all, searchText: "",
            newestFirst: true, calendar: utc, locale: posix)
        let sections = CameraRollQuery.sections(from: sorted, grouping: .month, calendar: utc, locale: posix)
        XCTAssertEqual(sections.map(\.id), ["2026-03", "2026-01", "2025-12", "undated"])
        XCTAssertEqual(sections[0].items.map(\.id), ["e", "b"])
        XCTAssertEqual(sections.last?.title, "Unknown date")
    }

    func testDayGroupingSplitsSameMonth() {
        let items = [
            CameraRollItem(id: "1", creationDate: date(2026, 3, 9)),
            CameraRollItem(id: "2", creationDate: date(2026, 3, 8)),
        ]
        let sections = CameraRollQuery.sections(from: items, grouping: .day, calendar: utc, locale: posix)
        XCTAssertEqual(sections.map(\.id), ["2026-03-09", "2026-03-08"])
    }

    func testGroupingOldestFirstKeepsOrder() {
        let sorted = CameraRollQuery.apply(
            to: sample(), includeVideos: true, filter: .all, searchText: "",
            newestFirst: false, calendar: utc, locale: posix)
        let sections = CameraRollQuery.sections(from: sorted, grouping: .month, calendar: utc, locale: posix)
        XCTAssertEqual(sections.map(\.id), ["2025-12", "2026-01", "2026-03", "undated"])
    }

    func testGroupingEmptyInput() {
        XCTAssertTrue(CameraRollQuery.sections(from: [], grouping: .month).isEmpty)
    }
}

final class CameraRollSelectionTests: XCTestCase {
    private func items(_ ids: [String]) -> [CameraRollItem] { ids.map { CameraRollItem(id: $0) } }

    func testToggleAndCount() {
        var s = CameraRollSelection()
        s.toggle("a"); s.toggle("b")
        XCTAssertEqual(s.count, 2)
        s.toggle("a")
        XCTAssertFalse(s.contains("a"))
        XCTAssertTrue(s.contains("b"))
    }

    func testSelectAllAndClear() {
        var s = CameraRollSelection()
        s.selectAll(items(["a", "b", "c"]))
        XCTAssertEqual(s.count, 3)
        s.clear()
        XCTAssertTrue(s.isEmpty)
    }

    func testPruneDropsVanishedAssets() {
        var s = CameraRollSelection()
        s.selectAll(items(["a", "b", "c"]))
        s.prune(keeping: items(["b", "c", "d"]))
        XCTAssertEqual(s.ids, ["b", "c"])
    }

    func testResolveKeepsLibraryOrder() {
        var s = CameraRollSelection()
        s.toggle("c"); s.toggle("a")
        XCTAssertEqual(s.resolve(in: items(["a", "b", "c"])).map(\.id), ["a", "c"])
    }
}

final class CameraRollAlbumVisibilityTests: XCTestCase {
    private let albums = [
        CameraRollAlbum(id: "1", title: "Recents", assetCount: 5, source: .smart),
        CameraRollAlbum(id: "2", title: "Trip", assetCount: 0, source: .user),
        CameraRollAlbum(id: "3", title: "Work", assetCount: 2, source: .user),
    ]

    func testHiddenAlbumsAreFilteredOut() {
        let v = CameraRollAlbumVisibility.visible(albums, hiddenIDs: ["2"], showHidden: false)
        XCTAssertEqual(v.map(\.id), ["1", "3"])
    }

    func testShowHiddenRevealsEverything() {
        let v = CameraRollAlbumVisibility.visible(albums, hiddenIDs: ["2"], showHidden: true)
        XCTAssertEqual(v.count, 3)
    }

    func testEmptyAlbumIsKeptWhenNotHidden() {
        let v = CameraRollAlbumVisibility.visible(albums, hiddenIDs: [], showHidden: false)
        XCTAssertTrue(v.contains { $0.assetCount == 0 })
    }
}

@MainActor
final class CameraRollSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "CameraRollSettingsTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testDefaults() {
        let s = CameraRollSettings(defaults: freshDefaults())
        XCTAssertTrue(s.includeVideos)
        XCTAssertTrue(s.newestFirst)
        XCTAssertEqual(s.grouping, .month)
        XCTAssertTrue(s.hiddenAlbumIDs.isEmpty)
    }

    func testSettingsPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = CameraRollSettings(defaults: defaults)
        first.includeVideos = false
        first.newestFirst = false
        first.grouping = .day
        first.setHidden(true, albumID: "album-1")

        let second = CameraRollSettings(defaults: defaults)
        XCTAssertFalse(second.includeVideos)
        XCTAssertFalse(second.newestFirst)
        XCTAssertEqual(second.grouping, .day)
        XCTAssertTrue(second.isHidden("album-1"))
    }

    func testUnhideRemovesAlbum() {
        let s = CameraRollSettings(defaults: freshDefaults())
        s.setHidden(true, albumID: "x")
        s.setHidden(false, albumID: "x")
        XCTAssertFalse(s.isHidden("x"))
    }
}

@MainActor
final class CameraRollCollectionStoreTests: XCTestCase {
    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collections-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCreateRejectsBlankNames() {
        let store = CameraRollCollectionStore(fileURL: tempURL())
        XCTAssertNil(store.create(name: "   "))
        XCTAssertTrue(store.collections.isEmpty)
    }

    func testAddDoesNotDuplicateAndReportsCount() {
        let store = CameraRollCollectionStore(fileURL: tempURL())
        let c = store.create(name: "Trip")!
        XCTAssertEqual(store.add(assetIDs: ["a", "b", "a"], to: c.id), 2)
        XCTAssertEqual(store.add(assetIDs: ["b", "c"], to: c.id), 1)
        XCTAssertEqual(store.collections[0].assetIDs, ["a", "b", "c"])
    }

    func testMembershipPersistsAcrossLaunches() {
        let url = tempURL()
        let first = CameraRollCollectionStore(fileURL: url)
        let c = first.create(name: "Family")!
        first.add(assetIDs: ["a", "b"], to: c.id)

        let second = CameraRollCollectionStore(fileURL: url)
        XCTAssertEqual(second.collections.map(\.name), ["Family"])
        XCTAssertEqual(second.collections[0].assetIDs, ["a", "b"])
    }

    func testRemoveForgetRenameDelete() {
        let store = CameraRollCollectionStore(fileURL: tempURL())
        let c = store.create(name: "A")!
        store.add(assetIDs: ["a", "b", "c"], to: c.id)
        store.remove(assetIDs: ["a"], from: c.id)
        XCTAssertEqual(store.collections[0].assetIDs, ["b", "c"])
        store.forget(assetIDs: ["c"])
        XCTAssertEqual(store.collections[0].assetIDs, ["b"])
        store.rename(c.id, to: "  B  ")
        XCTAssertEqual(store.collections[0].name, "B")
        store.delete(c.id)
        XCTAssertTrue(store.collections.isEmpty)
    }

    func testAddToUnknownCollectionIsNoOp() {
        let store = CameraRollCollectionStore(fileURL: tempURL())
        XCTAssertEqual(store.add(assetIDs: ["a"], to: UUID()), 0)
    }
}

final class AnimatedImageDecoderTests: XCTestCase {

    /// Builds a small in-memory GIF with `frames` frames, each `delay` seconds.
    private func makeGIF(frames: Int, delay: Double) throws -> Data {
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for i in 0..<frames {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
            let image = renderer.image { ctx in
                UIColor(hue: CGFloat(i) / CGFloat(max(frames, 1)), saturation: 1, brightness: 1, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            CGImageDestinationAddImage(dest, try XCTUnwrap(image.cgImage), frameProps)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testDecodesFramesAndDuration() throws {
        let gif = try makeGIF(frames: 4, delay: 0.2)
        let image = try XCTUnwrap(AnimatedImageDecoder.makeAnimatedImage(from: gif, maxPixelSize: 64))
        XCTAssertEqual(image.images?.count, 4)
        XCTAssertEqual(image.duration, 0.8, accuracy: 0.05)
    }

    func testVeryShortDelaysAreClampedToTenthOfASecond() throws {
        let gif = try makeGIF(frames: 2, delay: 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        XCTAssertEqual(AnimatedImageDecoder.frameDelay(at: 0, in: source), 0.1, accuracy: 0.001)
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(AnimatedImageDecoder.makeAnimatedImage(from: Data([1, 2, 3, 4]), maxPixelSize: 64))
    }

    func testLongGIFIsSampledToFrameCap() throws {
        let gif = try makeGIF(frames: AnimatedImageDecoder.maxFrames * 2 + 10, delay: 0.05)
        let image = try XCTUnwrap(AnimatedImageDecoder.makeAnimatedImage(from: gif, maxPixelSize: 32))
        XCTAssertLessThanOrEqual(image.images?.count ?? .max, AnimatedImageDecoder.maxFrames)
    }
}

final class CameraRollThumbnailFormatTests: XCTestCase {
    func testDurationText() {
        XCTAssertEqual(CameraRollThumbnailView.durationText(0), "0:00")
        XCTAssertEqual(CameraRollThumbnailView.durationText(65), "1:05")
        XCTAssertEqual(CameraRollThumbnailView.durationText(3725), "1:02:05")
    }
}

import XCTest
import Photos
@testable import LocalGallery

/// The photo-library (Camera Roll) integration.
///
/// PhotoKit itself cannot be faked — a `PHAsset` only exists on a
/// device with a photo library — so what is pinned here is everything
/// the integration *decides* rather than reads: how the system's
/// authorization states map onto the app's own, how albums are ordered
/// and counted, how the timeline is grouped into months, when there is
/// more to page in, and what the navigation route looks like.
///
/// The value types (`PhotoKitAsset`, `PhotoKitAlbum`) are plain structs
/// precisely so this is possible: the rules consume values, not
/// PhotoKit objects.
final class PhotoKitTests: XCTestCase {

    // MARK: - Permission states

    /// The mapping from the system's status to the app's.
    ///
    /// Every case is distinct because the UI branches on it: "ask",
    /// "policy says no", "the user said no", "readable but partial",
    /// "readable".
    func testEveryAuthorizationStatusMapsToItsOwnState() {
        XCTAssertEqual(PhotoKitAuthorization.map(.notDetermined), .notDetermined)
        XCTAssertEqual(PhotoKitAuthorization.map(.restricted), .restricted)
        XCTAssertEqual(PhotoKitAuthorization.map(.denied), .denied)
        XCTAssertEqual(PhotoKitAuthorization.map(.limited), .limited)
        XCTAssertEqual(PhotoKitAuthorization.map(.authorized), .authorized)
    }

    /// Only "limited" and "authorized" can actually be read.
    ///
    /// This is the single predicate the whole Camera Roll tab hinges on:
    /// a grid that renders before access is granted would show an empty
    /// library and look broken rather than unauthorized.
    func testOnlyGrantedStatesAreReadable() {
        XCTAssertTrue(PhotoKitAuthorization.authorized.isReadable)
        XCTAssertTrue(PhotoKitAuthorization.limited.isReadable)
        XCTAssertFalse(PhotoKitAuthorization.notDetermined.isReadable)
        XCTAssertFalse(PhotoKitAuthorization.restricted.isReadable)
        XCTAssertFalse(PhotoKitAuthorization.denied.isReadable)
    }

    /// Limited access is *readable*.
    ///
    /// The system shows a subset the user picked; the app can still show
    /// what it was given. Treating "limited" as "denied" would hide a
    /// library the user deliberately shared.
    func testLimitedAccessIsReadableNotDenied() {
        XCTAssertNotEqual(PhotoKitAuthorization.limited, .denied)
        XCTAssertTrue(PhotoKitAuthorization.limited.isReadable)
    }

    /// The states the UI distinguishes are all distinct values.
    func testTheAuthorizationStatesAreDistinguishable() {
        let all: [PhotoKitAuthorization] = [
            .notDetermined, .restricted, .denied, .limited, .authorized,
        ]
        for (i, lhs) in all.enumerated() {
            for rhs in all[(i + 1)...] {
                XCTAssertNotEqual(lhs, rhs, "\(lhs) and \(rhs) must be distinguishable")
            }
        }
    }

    // MARK: - Album mapping

    /// The Camera Roll's synthetic identifier.
    ///
    /// The Camera Roll is "all assets", not one `PHAssetCollection`, so
    /// it has no identifier to fetch by — it needs a stable stand-in to
    /// be `Identifiable` and to be routed to.
    func testTheCameraRollHasAStableSyntheticIdentifier() {
        XCTAssertEqual(PhotoKitAlbumID.cameraRoll, "photokit:camera-roll")
        XCTAssertFalse(PhotoKitAlbumID.cameraRoll.isEmpty)
    }

    /// The count label is pluralised.
    func testAlbumCountLabelIsPluralised() {
        func album(_ count: Int) -> PhotoKitAlbum {
            PhotoKitAlbum(
                id: "a",
                title: "Album",
                kind: .user,
                count: count,
                coverAssetID: nil
            )
        }
        XCTAssertEqual(album(1).countLabel, "1 photo")
        XCTAssertEqual(album(0).countLabel, "0 photos")
        XCTAssertEqual(album(12).countLabel, "12 photos")
    }

    /// The album order puts the ones a user reaches for first.
    func testAlbumsAreOrderedSystemFirstThenTheUsersOwn() {
        let userA = PhotoKitAlbum(id: "u1", title: "Holidays", kind: .user, count: 3, coverAssetID: nil)
        let userB = PhotoKitAlbum(id: "u2", title: "Family", kind: .user, count: 4, coverAssetID: nil)
        let shots = PhotoKitAlbum(id: "s", title: "Screenshots", kind: .screenshots, count: 9, coverAssetID: nil)
        let roll = PhotoKitAlbum(id: PhotoKitAlbumID.cameraRoll, title: "Camera Roll", kind: .cameraRoll, count: 100, coverAssetID: nil)
        let recents = PhotoKitAlbum(id: "r", title: "Recents", kind: .recents, count: 20, coverAssetID: nil)
        let videos = PhotoKitAlbum(id: "v", title: "Videos", kind: .videos, count: 7, coverAssetID: nil)
        let favorites = PhotoKitAlbum(id: "f", title: "Favorites", kind: .favorites, count: 2, coverAssetID: nil)

        let ordered = PhotoKitLibraryRules.ordered([
            userA, videos, userB, favorites, shots, recents, roll,
        ])

        XCTAssertEqual(ordered.map(\.kind), [
            .cameraRoll, .recents, .screenshots, .videos, .favorites, .user, .user,
        ])
    }

    /// The user's own albums keep the order the system gave them.
    ///
    /// Their order is meaningful to the user (they arranged it), so it is
    /// not re-sorted — only moved as a block behind the system albums.
    func testUserAlbumsKeepTheirRelativeOrder() {
        let first = PhotoKitAlbum(id: "u1", title: "First", kind: .user, count: 1, coverAssetID: nil)
        let second = PhotoKitAlbum(id: "u2", title: "Second", kind: .user, count: 1, coverAssetID: nil)
        let third = PhotoKitAlbum(id: "u3", title: "Third", kind: .user, count: 1, coverAssetID: nil)
        let roll = PhotoKitAlbum(id: PhotoKitAlbumID.cameraRoll, title: "Camera Roll", kind: .cameraRoll, count: 1, coverAssetID: nil)

        let ordered = PhotoKitLibraryRules.ordered([first, second, third, roll])

        XCTAssertEqual(ordered.map(\.id), [PhotoKitAlbumID.cameraRoll, "u1", "u2", "u3"])
    }

    /// Ordering is a pure permutation — no album is lost or duplicated.
    func testOrderingKeepsEveryAlbumExactlyOnce() {
        let albums = [
            PhotoKitAlbum(id: "a", title: "A", kind: .cameraRoll, count: 1, coverAssetID: nil),
            PhotoKitAlbum(id: "b", title: "B", kind: .user, count: 1, coverAssetID: nil),
            PhotoKitAlbum(id: "c", title: "C", kind: .screenshots, count: 1, coverAssetID: nil),
            PhotoKitAlbum(id: "d", title: "D", kind: .user, count: 1, coverAssetID: nil),
        ]
        let ordered = PhotoKitLibraryRules.ordered(albums)
        XCTAssertEqual(ordered.count, albums.count)
        XCTAssertEqual(Set(ordered.map(\.id)), Set(albums.map(\.id)))
    }

    /// Every album kind has an icon — a blank tile would look like a
    /// rendering failure.
    func testEveryAlbumKindHasAnIcon() {
        let kinds: [PhotoKitAlbum.Kind] = [
            .cameraRoll, .recents, .screenshots, .videos, .favorites, .user,
        ]
        for kind in kinds {
            XCTAssertFalse(kind.iconName.isEmpty, "\(kind) must have an icon")
        }
        // The icons must be distinct, or three different albums would be
        // indistinguishable in a grid.
        let icons = kinds.map(\.iconName)
        XCTAssertEqual(Set(icons).count, kinds.count)
    }

    // MARK: - Timeline grouping

    func testEmptyTimelineProducesNoSections() {
        XCTAssertEqual(group([]).count, 0)
    }

    func testSameMonthAssetsBucketTogether() {
        let assets = [
            PhotoKitAsset(id: "a", creationDate: date(2024, 3, 5)),
            PhotoKitAsset(id: "b", creationDate: date(2024, 3, 18)),
            PhotoKitAsset(id: "c", creationDate: date(2024, 3, 25)),
        ]
        let sections = group(assets)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "2024-03")
        XCTAssertEqual(sections.first?.assets.count, 3)
    }

    /// The section key is zero-padded, so "2024-03" and "2024-11" are
    /// both four-and-two digits.
    ///
    /// The key is built by interpolation rather than
    /// `String(format: "%04d-%02d", …)` — `%d` is a 32-bit conversion and
    /// `Int` is 64-bit, so the varargs width and the argument width
    /// disagree. It reads the right bytes below 2^31, but a section key
    /// is not the place to rely on that.
    func testSectionKeysAreZeroPadded() {
        let assets = [
            PhotoKitAsset(id: "a", creationDate: date(2024, 3, 5)),
            PhotoKitAsset(id: "b", creationDate: date(2024, 11, 5)),
        ]
        let sections = group(assets)
        XCTAssertEqual(sections.map(\.id), ["2024-11", "2024-03"])
        XCTAssertEqual(sections.first?.id.count, 7)
    }

    /// Months come out newest-first — the timeline is sorted that way by
    /// PhotoKit, and the grouping preserves it.
    func testSectionsAreNewestFirst() {
        let assets = [
            PhotoKitAsset(id: "a", creationDate: date(2024, 6, 4)),
            PhotoKitAsset(id: "b", creationDate: date(2023, 1, 10)),
        ]
        XCTAssertEqual(group(assets).map(\.id), ["2024-06", "2023-01"])
    }

    /// An asset with no date lands in its own bucket rather than being
    /// dropped.
    func testUndatedAssetsLandInTheUnknownBucket() {
        let assets = [
            PhotoKitAsset(id: "a", creationDate: date(2024, 3, 5)),
            PhotoKitAsset(id: "b", creationDate: nil),
        ]
        let sections = group(assets)
        XCTAssertEqual(Set(sections.map(\.id)), ["2024-03", "unknown"])
        XCTAssertEqual(sections.first { $0.id == "unknown" }?.title, "Unknown Date")
    }

    /// Every asset ends up in exactly one section — a lost asset is a
    /// photo the user can see in Photos but not in Pixel Pic.
    func testGroupingLosesNoAssets() {
        let assets = [
            PhotoKitAsset(id: "a", creationDate: date(2024, 3, 5)),
            PhotoKitAsset(id: "b", creationDate: date(2024, 4, 5)),
            PhotoKitAsset(id: "c", creationDate: date(2024, 3, 6)),
            PhotoKitAsset(id: "d", creationDate: nil),
        ]
        let sections = group(assets)
        let grouped = sections.flatMap(\.assets).map(\.id)
        XCTAssertEqual(grouped.count, assets.count)
        XCTAssertEqual(Set(grouped), Set(assets.map(\.id)))
    }

    // MARK: - Paging

    /// The paging sentinel appears while there is more to fetch and
    /// disappears once the whole library is on screen.
    func testPagingStopsWhenTheWholeLibraryIsLoaded() {
        XCTAssertTrue(PhotoKitLibraryRules.hasMore(fetched: 600, total: 1000))
        XCTAssertFalse(PhotoKitLibraryRules.hasMore(fetched: 1000, total: 1000))
        XCTAssertFalse(PhotoKitLibraryRules.hasMore(fetched: 1200, total: 1000))
    }

    /// The next page starts where the last one stopped.
    func testTheNextPageOffsetFollowsTheFetchedCount() {
        XCTAssertEqual(PhotoKitLibraryRules.nextOffset(fetched: 600), 600)
        XCTAssertEqual(PhotoKitLibraryRules.nextOffset(fetched: 0), 0)
    }

    /// The last page is trimmed to what is actually left, so the fetch
    /// does not ask for 600 assets when only 12 remain.
    func testTheLastPageIsTrimmedToWhatIsLeft() {
        XCTAssertEqual(
            PhotoKitLibraryRules.pageSize(fetched: 600, total: 1000, page: 600),
            400
        )
        XCTAssertEqual(
            PhotoKitLibraryRules.pageSize(fetched: 600, total: 1200, page: 600),
            600
        )
    }

    /// A page size of zero would make the fetch ask for nothing and the
    /// paging sentinel would spin forever.
    func testThePageSizeIsNeverZero() {
        XCTAssertEqual(
            PhotoKitLibraryRules.pageSize(fetched: 1000, total: 1000, page: 600),
            1
        )
    }

    /// The album drill-in pages the same way the timeline does.
    ///
    /// The Camera Roll album *is* the whole library, so its tile counts
    /// every asset — and the drill-in has to be able to reach all of them,
    /// which means paging rather than one unbounded fetch.
    func testAlbumPagingUsesTheSameRuleAsTheTimeline() {
        XCTAssertTrue(PhotoKitLibraryRules.hasMore(fetched: 600, total: 12_043))
        XCTAssertEqual(
            PhotoKitLibraryRules.pageSize(fetched: 600, total: 12_043, page: 600),
            600
        )
        // The last page is trimmed to what is left.
        XCTAssertEqual(
            PhotoKitLibraryRules.pageSize(fetched: 12_000, total: 12_043, page: 600),
            43
        )
    }

    // MARK: - Readout

    /// The "N of M" readout must report the *collection's* size, not the
    /// size of the page that was paged in.
    ///
    /// The timeline pages in 600 at a time. Using the paged count would
    /// read "12 of 600" on a library holding 12,043 photos — a number
    /// that looks plausible and is wrong.
    func testTheReadoutReportsTheCollectionsSizeNotThePagedCount() {
        XCTAssertEqual(
            PhotoKitLibraryRules.positionLabel(index: 11, total: 12_043, browsed: 600),
            "12 of 12043"
        )
    }

    /// An album drill-in reports the *album's* size, not the library's.
    func testTheReadoutUsesTheAlbumsOwnCount() {
        XCTAssertEqual(
            PhotoKitLibraryRules.positionLabel(index: 0, total: 12, browsed: 12),
            "1 of 12"
        )
    }

    /// With no total (a collection whose size is unknown) the readout
    /// falls back to the browsed count rather than showing nothing.
    func testTheReadoutFallsBackToTheBrowsedCount() {
        XCTAssertEqual(
            PhotoKitLibraryRules.positionLabel(index: 2, total: nil, browsed: 9),
            "3 of 9"
        )
    }

    /// A total below the current position would read "5 of 3". The
    /// browsed count is the floor, so the readout degrades to "N of N"
    /// rather than to nonsense.
    func testTheReadoutNeverCountsPastItsOwnTotal() {
        XCTAssertEqual(
            PhotoKitLibraryRules.positionLabel(index: 5, total: 3, browsed: 8),
            "6 of 8"
        )
    }

    /// The position is one-based — "1 of N", never "0 of N".
    func testTheReadoutIsOneBased() {
        XCTAssertEqual(
            PhotoKitLibraryRules.positionLabel(index: 0, total: 10, browsed: 10),
            "1 of 10"
        )
    }

    // MARK: - Navigation

    /// The album route carries the album, so the detail screen knows
    /// which one it is showing.
    func testTheAlbumRouteCarriesTheAlbum() {
        let album = PhotoKitAlbum(
            id: "u1",
            title: "Holidays",
            kind: .user,
            count: 12,
            coverAssetID: "asset-1"
        )
        let route = PhotoLibraryRoute.album(album)
        guard case .album(let routed) = route else {
            return XCTFail("The route must carry the album")
        }
        XCTAssertEqual(routed.id, "u1")
        XCTAssertEqual(routed.title, "Holidays")
        XCTAssertEqual(routed.coverAssetID, "asset-1")
    }

    /// Two albums with the same title but different ids are different
    /// routes — otherwise the drill-in would show the wrong album.
    func testTwoAlbumsWithTheSameTitleAreDifferentRoutes() {
        func route(_ id: String) -> PhotoLibraryRoute {
            .album(PhotoKitAlbum(id: id, title: "Holidays", kind: .user, count: 1, coverAssetID: nil))
        }
        XCTAssertNotEqual(route("a"), route("b"))
    }

    // MARK: - Asset values

    /// A still has no duration label; a video does.
    func testDurationLabelOnlyAppliesToVideos() {
        let still = PhotoKitAsset(id: "a", isVideo: false, duration: 12)
        XCTAssertEqual(still.durationLabel, "")

        let video = PhotoKitAsset(id: "b", isVideo: true, duration: 61)
        XCTAssertEqual(video.durationLabel, "1:01")
    }

    /// The asset identity is its PhotoKit identifier.
    func testAssetsAreIdentifiedByTheirPhotoKitIdentifier() {
        let a = PhotoKitAsset(id: "asset-1")
        let b = PhotoKitAsset(id: "asset-1", filename: "OTHER.JPG")
        XCTAssertEqual(a.id, b.id)
        // The identifier is the identity; the rest is presentation.
        XCTAssertEqual(a.id, "asset-1")
    }

    // MARK: - Helpers

    /// The grouping is asked to use this calendar, so the month a photo
    /// lands in does not depend on the machine the test runs on.
    ///
    /// The `date(_:_:_:)` builder in the test support file is already
    /// UTC-based, so the two agree.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Group with the fixed calendar.
    private func group(_ assets: [PhotoKitAsset]) -> [PhotoKitSection] {
        PhotoKitSection.group(assets, calendar: utcCalendar)
    }
}

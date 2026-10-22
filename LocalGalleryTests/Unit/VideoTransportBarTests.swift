import XCTest
@testable import LocalGallery

/// The transport bar's time formatting.
///
/// Pure and pinned because the format is what the user reads to know where
/// they are in a clip, and because it is the one part of the transport that
/// has no UIKit dependency — so it can be tested without a player.
final class VideoTransportBarTests: XCTestCase {

    func testShortClipsAreMinutesAndSeconds() {
        XCTAssertEqual(VideoTimeFormat.string(0), "0:00")
        XCTAssertEqual(VideoTimeFormat.string(9), "0:09")
        XCTAssertEqual(VideoTimeFormat.string(61), "1:01")
        XCTAssertEqual(VideoTimeFormat.string(599), "9:59")
    }

    func testLongClipsGetAnHoursComponent() {
        XCTAssertEqual(VideoTimeFormat.string(3600), "1:00:00")
        XCTAssertEqual(VideoTimeFormat.string(3661), "1:01:01")
        // Over an hour, the minutes are still two digits.
        XCTAssertEqual(VideoTimeFormat.string(7325), "2:02:05")
    }

    func testFractionalSecondsRoundToTheNearestSecond() {
        // 59.6s rounds to 60s, which must carry into the minutes rather
        // than rendering as "0:60".
        XCTAssertEqual(VideoTimeFormat.string(59.6), "1:00")
        XCTAssertEqual(VideoTimeFormat.string(0.4), "0:00")
        XCTAssertEqual(VideoTimeFormat.string(1.5), "0:02")
    }

    func testNonFiniteAndNegativeDurationsAreRejected() {
        // `CMTime.seconds` is NaN for an indefinite duration and infinity
        // for an unknown one. Neither may reach the label.
        XCTAssertEqual(VideoTimeFormat.string(.nan), "0:00")
        XCTAssertEqual(VideoTimeFormat.string(.infinity), "0:00")
        XCTAssertEqual(VideoTimeFormat.string(-5), "0:00")
    }
}

import XCTest
import SwiftUI
@testable import PixelPic

/// The appearance preference.
///
/// The app's palette is a designed light/dark pair, so the control that
/// chooses between them is user-visible behaviour — and the "System"
/// case is the one that is easy to get wrong: it must *follow* the
/// device, not force light.
final class AppAppearanceTests: XCTestCase {

    /// The defaults instance the cases write to. A fresh suite per test,
    /// so the "System" default is not shadowed by a value another case
    /// left behind.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = TestUserDefaults.make()
    }

    override func tearDown() {
        TestUserDefaults.cleanup(defaults)
        defaults = nil
        super.tearDown()
    }

    /// "System" means "no forced scheme".
    ///
    /// A forced `.light` would be a different behaviour — it would ignore
    /// the device's own dark-mode setting, which is exactly what the user
    /// chose "System" to avoid.
    func testSystemFollowsTheDeviceRatherThanForcingAScheme() {
        XCTAssertNil(AppAppearance.system.colorScheme)
    }

    /// The two forced cases do force.
    func testLightAndDarkForceTheirScheme() {
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }

    /// Every case has a label — an empty picker entry reads as a bug.
    func testEveryAppearanceHasALabel() {
        for appearance in AppAppearance.allCases {
            XCTAssertFalse(appearance.label.isEmpty, "\(appearance) must have a label")
        }
        // The labels must be distinct, or the picker would show two
        // identical entries.
        XCTAssertEqual(Set(AppAppearance.allCases.map(\.label)).count, AppAppearance.allCases.count)
    }

    /// An absent key means "System" — the app must not launch with no
    /// appearance at all on a fresh install.
    func testAMissingPreferenceReadsAsSystem() {
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
    }

    /// A stored value round-trips.
    func testAStoredPreferenceIsReadBack() {
        for appearance in AppAppearance.allCases {
            defaults.set(appearance.rawValue, forKey: AppAppearance.defaultsKey)
            XCTAssertEqual(AppAppearance.stored(in: defaults), appearance)
        }
    }

    /// A value this version does not know — written by a newer build, or
    /// edited by hand — must degrade to "System" rather than leaving the
    /// app with no scheme.
    func testAnUnknownStoredValueFallsBackToSystem() {
        defaults.set("sepia", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
    }
}

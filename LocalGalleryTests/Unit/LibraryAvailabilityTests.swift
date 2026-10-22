import XCTest
@testable import LocalGallery

/// The library-availability state machine.
///
/// `LibraryAvailability` is what decides *which* empty state the user sees
/// and *which* recovery we offer them. The distinction it exists for: a
/// folder that is gone or offline (a retry may fix it) versus a folder we
/// are not allowed to read (only the user can fix it, by picking it
/// again). Before the split, both were `.unavailable`, so the app told
/// people to retry a scan that could not possibly succeed.
///
/// The mapping is a pure function so it can be pinned here rather than
/// only through a real scan pass — a real refusal needs the OS to deny a
/// security scope, which a test cannot arrange.
final class LibraryAvailabilityTests: XCTestCase {

    // MARK: - Which state a finished pass implies

    func testAGoneRootIsUnavailable() {
        // The folder was deleted or unmounted. A retry may find it again.
        XCTAssertEqual(
            LibraryAvailability.afterScan(
                rootIsGone: true,
                rootIsUnlistable: false,
                accessDenied: false
            ),
            .unavailable
        )
    }

    func testAnUnlistableRootIsUnavailableWhenAccessWasNotRefused() {
        // The folder is there but something transient went wrong — a
        // provider is offline, an I/O error. Retry is the right answer.
        XCTAssertEqual(
            LibraryAvailability.afterScan(
                rootIsGone: false,
                rootIsUnlistable: true,
                accessDenied: false
            ),
            .unavailable
        )
    }

    func testAnUnlistableRootWithARefusedScopeIsPermissionDenied() {
        // The OS refused our security scope. No retry can fix that; the
        // user has to pick the folder again.
        XCTAssertEqual(
            LibraryAvailability.afterScan(
                rootIsGone: false,
                rootIsUnlistable: true,
                accessDenied: true
            ),
            .permissionDenied
        )
    }

    func testAGoneRootOutranksARefusedScope() {
        // A refused scope on a folder that no longer exists is still just
        // "gone" — there is nothing to re-grant access to.
        XCTAssertEqual(
            LibraryAvailability.afterScan(
                rootIsGone: true,
                rootIsUnlistable: true,
                accessDenied: true
            ),
            .unavailable
        )
    }

    func testASuccessfulPassIsReady() {
        XCTAssertEqual(
            LibraryAvailability.afterScan(
                rootIsGone: false,
                rootIsUnlistable: false,
                accessDenied: false
            ),
            .ready
        )
    }

    // MARK: - What each state does to the UI

    func testTheTwoFailureModesKeepTheCachedLibrary() {
        // The photos on disk are fine — only the *listing* failed — so the
        // scan's carry-forward kept them and the app must not throw them
        // away.
        XCTAssertTrue(LibraryAvailability.unavailable.keepsCachedLibrary)
        XCTAssertTrue(LibraryAvailability.permissionDenied.keepsCachedLibrary)
    }

    func testTheTwoFailureModesHideTheLibrary() {
        // A grid that still renders while the folder cannot be read looks
        // like a working library, which is the wrong impression.
        XCTAssertTrue(LibraryAvailability.unavailable.hidesLibrary)
        XCTAssertTrue(LibraryAvailability.permissionDenied.hidesLibrary)
    }

    func testTheHealthyStatesNeitherKeepNorHide() {
        for state in [LibraryAvailability.noneSelected, .empty, .ready] {
            XCTAssertFalse(state.keepsCachedLibrary, "\(state) must not claim to keep a library")
            XCTAssertFalse(state.hidesLibrary, "\(state) must not hide the library")
        }
    }

    func testTheStatesAreDistinguishableFromEachOther() {
        // A view switches on the state; two cases collapsing to the same
        // value would make one of the branches unreachable.
        let all: [LibraryAvailability] = [.noneSelected, .unavailable, .permissionDenied, .empty, .ready]
        for (i, lhs) in all.enumerated() {
            for rhs in all[(i + 1)...] {
                XCTAssertNotEqual(lhs, rhs, "\(lhs) and \(rhs) must be distinguishable")
            }
        }
    }
}

import SwiftUI

/// Navigation state for the app's one main screen.
///
/// The app has a single top-level experience — the Albums gallery over
/// the device's Photos library — so the router owns exactly one path:
/// the gallery's navigation stack, which carries album drill-ins.
/// There is no tab state: the Folders, Collections and Photos tabs the
/// app used to have were removed, and with them every route into those
/// screens.
///
/// Widget deep links used to land on those removed screens (a memory,
/// a folder, a tag filter). Those destinations no longer exist, so a
/// deep link now simply opens the gallery at its root. The widget
/// snapshot itself is untouched — a tap still brings the user into the
/// app, just to the one screen the app has.
@Observable
@MainActor
final class AppRouter {
    /// The gallery's navigation stack — an album grid's drill-in (an
    /// album → its assets) pushes onto it.
    var photoLibraryPath: [PhotoLibraryRoute] = []

    /// Handle a widget deep link by opening the gallery at its root.
    ///
    /// Any *recognized* link lands there, whatever it originally pointed
    /// at — the memory, folder and tag screens it named were removed
    /// with their tabs, and dropping the user at the gallery root is
    /// the honest fallback rather than a dead end.
    func handle(_ url: URL) {
        guard WidgetDeepLink.parse(url) != nil else { return }
        photoLibraryPath = []
    }
}

/// Typed navigation values for the gallery — the device's own Photos
/// library.
enum PhotoLibraryRoute: Hashable {
    /// One album's assets.
    case album(PhotoKitAlbum)
}

/// Typed nav stack values for the Collections screens.
///
/// The Collections tab was removed with the other tabs, so nothing in
/// the app's navigation pushes these routes any more. The type stays
/// because the (now unreachable) Collections views still reference it,
/// and their shared services — memories, people, tagging — remain part
/// of the app's background machinery.
enum CollectionsRoute: Hashable {
    case slideshow(Memory)
    case memoryGrid(Memory)
    case peopleList
    case personGrid(TagSuggestion)
    /// The on-device face review queue — unlabeled clusters waiting for a name.
    case peopleReview
    /// One cluster's faces, with Name / Not a person.
    case clusterReview(Int64)
    /// A suggested merge: every face in the paired groups, with Select to
    /// pick which clusters actually merge.
    case mergeProposal([Int64])
}

/// Whether Collections shows a People section.
///
/// Named people are the usual reason. Unlabeled face groups are the other:
/// they live on the People list, so hiding the section until someone is named
/// made that list — and its review row — unreachable on a fresh library. A
/// scan in flight is the third, so the header exists as a destination while
/// faces are still being found.
enum PeopleSectionVisibility {
    static func shouldShow(namedPeople: Int, reviewableClusters: Int, scanning: Bool) -> Bool {
        namedPeople > 0 || reviewableClusters > 0 || scanning
    }
}

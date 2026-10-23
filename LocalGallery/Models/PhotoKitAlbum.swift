import Foundation

/// One album in the device's Photos library.
struct PhotoKitAlbum: Identifiable, Hashable, Sendable {
    /// The kind of album, which decides where it sits in the grid and
    /// which icon it gets.
    enum Kind: String, Hashable, Sendable {
        /// Media captured by the device's own camera. A filtered view of
        /// the library, not the whole library — see
        /// `PhotoKitService.fetchAlbums()` for the exact rule and its
        /// limits.
        case camera
        case screenshots
        case videos
        case favorites
        /// An album the user made.
        case user

        /// SF Symbol for the album tile's placeholder.
        var iconName: String {
            switch self {
            case .camera: return "camera.aperture"
            case .screenshots: return "iphone.gen3"
            case .videos: return "play.rectangle"
            case .favorites: return "heart"
            case .user: return "rectangle.stack"
            }
        }
    }

    /// The collection's `localIdentifier`, or a synthetic id for the
    /// Camera album — which is a filtered fetch, not one collection, so
    /// it has no identifier to fetch by.
    let id: String
    let title: String
    let kind: Kind
    /// How many assets the album holds.
    let count: Int
    /// `localIdentifier` of the asset used as the tile's cover. `nil`
    /// when the album is empty.
    let coverAssetID: String?

    /// "12 photos" — the count under the album's name.
    var countLabel: String {
        "\(count) \(count == 1 ? "photo" : "photos")"
    }
}

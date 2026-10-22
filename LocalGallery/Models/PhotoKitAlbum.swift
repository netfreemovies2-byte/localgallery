import Foundation

/// One album in the device's Photos library.
struct PhotoKitAlbum: Identifiable, Hashable, Sendable {
    /// The kind of album, which decides where it sits in the grid and
    /// which icon it gets.
    enum Kind: String, Hashable, Sendable {
        /// "All assets" — the device's whole library.
        case cameraRoll
        /// "Recents".
        case recents
        case screenshots
        case videos
        case favorites
        /// An album the user made.
        case user

        /// SF Symbol for the album tile's placeholder.
        var iconName: String {
            switch self {
            case .cameraRoll: return "camera.aperture"
            case .recents: return "clock.arrow.circlepath"
            case .screenshots: return "iphone.gen3"
            case .videos: return "play.rectangle"
            case .favorites: return "heart"
            case .user: return "rectangle.stack"
            }
        }
    }

    /// The collection's `localIdentifier`, or a synthetic id for the
    /// Camera Roll — which is "all assets", not one collection, so it has
    /// no identifier to fetch by.
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

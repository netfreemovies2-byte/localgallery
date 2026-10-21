import Observation
import Photos
import SwiftUI
import UIKit

// MARK: - Authorization

enum CameraRollAccess: Hashable, Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .limited: self = .limited
        case .authorized: self = .authorized
        @unknown default: self = .denied
        }
    }

    var canRead: Bool { self == .authorized || self == .limited }
}

// MARK: - Settings

/// App-level Camera Roll preferences. Hiding an album only affects this app.
@Observable
@MainActor
final class CameraRollSettings {
    enum Key {
        static let includeVideos = "cameraRoll.includeVideos"
        static let hiddenAlbums = "cameraRoll.hiddenAlbumIDs"
        static let newestFirst = "cameraRoll.newestFirst"
        static let grouping = "cameraRoll.grouping"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // Computed + manual observation tracking: avoids relying on property
    // observers (`didSet`) inside an `@Observable` class.
    var includeVideos: Bool {
        get { access(keyPath: \.includeVideos); return defaults.object(forKey: Key.includeVideos) as? Bool ?? true }
        set { withMutation(keyPath: \.includeVideos) { defaults.set(newValue, forKey: Key.includeVideos) } }
    }
    var newestFirst: Bool {
        get { access(keyPath: \.newestFirst); return defaults.object(forKey: Key.newestFirst) as? Bool ?? true }
        set { withMutation(keyPath: \.newestFirst) { defaults.set(newValue, forKey: Key.newestFirst) } }
    }
    var grouping: CameraRollGrouping {
        get {
            access(keyPath: \.grouping)
            return defaults.string(forKey: Key.grouping).flatMap(CameraRollGrouping.init(rawValue:)) ?? .month
        }
        set { withMutation(keyPath: \.grouping) { defaults.set(newValue.rawValue, forKey: Key.grouping) } }
    }
    private(set) var hiddenAlbumIDs: Set<String>
    /// Session-only: lets the user review hidden albums so they can unhide them.
    var showHiddenAlbums = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenAlbumIDs = Set(defaults.stringArray(forKey: Key.hiddenAlbums) ?? [])
    }

    func isHidden(_ albumID: String) -> Bool { hiddenAlbumIDs.contains(albumID) }

    func setHidden(_ hidden: Bool, albumID: String) {
        if hidden { hiddenAlbumIDs.insert(albumID) } else { hiddenAlbumIDs.remove(albumID) }
        defaults.set(Array(hiddenAlbumIDs).sorted(), forKey: Key.hiddenAlbums)
    }
}

// MARK: - Library

private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}

/// Owns authorization state, the album list, and a change counter that grids
/// watch to reload when the Photos library changes.
@Observable
@MainActor
final class CameraRollLibrary {
    private(set) var access: CameraRollAccess
    private(set) var albums: [CameraRollAlbum] = []
    private(set) var isLoadingAlbums = false
    /// Bumped whenever the library changes (assets added/removed/edited) or access changes.
    private(set) var changeToken = 0

    let settings: CameraRollSettings

    @ObservationIgnored private var observer: LibraryChangeObserver?
    @ObservationIgnored private var albumReload: Task<Void, Never>?

    init(settings: CameraRollSettings = CameraRollSettings()) {
        self.settings = settings
        self.access = CameraRollAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Call once when the Camera Roll tab first appears. Does NOT prompt:
    /// the system prompt is shown only when the user taps the button.
    func start() {
        refreshAccess()
        guard observer == nil else { return }
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.libraryDidChange() }
        }
        self.observer = observer
        PHPhotoLibrary.shared().register(observer)
        if access.canRead { reloadAlbums() }
    }

    func refreshAccess() {
        let latest = CameraRollAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if latest != access {
            access = latest
            changeToken += 1
            if latest.canRead { reloadAlbums() } else { albums = [] }
        }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = CameraRollAccess(status)
        changeToken += 1
        if access.canRead { reloadAlbums() }
    }

    func reloadAlbums() {
        albumReload?.cancel()
        isLoadingAlbums = true
        let includeVideos = settings.includeVideos
        albumReload = Task { [weak self] in
            let loaded = await CameraRollImageService.loadAlbums(includeVideos: includeVideos)
            guard !Task.isCancelled, let self else { return }
            self.albums = loaded
            self.isLoadingAlbums = false
        }
    }

    private func libraryDidChange() {
        refreshAccess()
        changeToken += 1
        if access.canRead { reloadAlbums() }
    }

    /// Albums respecting the user's hidden-album choices.
    var visibleAlbums: [CameraRollAlbum] {
        CameraRollAlbumVisibility.visible(
            albums,
            hiddenIDs: settings.hiddenAlbumIDs,
            showHidden: settings.showHiddenAlbums
        )
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Shows the system picker that lets the user change which photos this app can see.
    func presentLimitedLibraryPicker() {
        guard let controller = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - User collections (app-defined, NOT Photos albums)

struct CameraRollCollection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// `PHAsset.localIdentifier`s, in the order they were added.
    var assetIDs: [String]
}

/// Persistent app-defined groupings of Photos assets. Membership lives in a
/// JSON file in Application Support; nothing is written to the Photos library.
@Observable
@MainActor
final class CameraRollCollectionStore {
    private(set) var collections: [CameraRollCollection] = []
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = CameraRollCollectionStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent("CameraRollCollections.json")
    }

    @discardableResult
    func create(name: String) -> CameraRollCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = CameraRollCollection(id: UUID(), name: trimmed, assetIDs: [])
        collections.append(collection)
        save()
        return collection
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].name = trimmed
        save()
    }

    func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        save()
    }

    /// Adds without duplicating; returns how many were newly added.
    @discardableResult
    func add(assetIDs: [String], to id: UUID) -> Int {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return 0 }
        let existing = Set(collections[i].assetIDs)
        let fresh = assetIDs.filter { !existing.contains($0) }
        let unique = fresh.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        collections[i].assetIDs.append(contentsOf: unique)
        save()
        return unique.count
    }

    func remove(assetIDs: [String], from id: UUID) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        let drop = Set(assetIDs)
        collections[i].assetIDs.removeAll { drop.contains($0) }
        save()
    }

    /// Forget assets that were deleted from Photos.
    func forget(assetIDs: [String]) {
        let drop = Set(assetIDs)
        for i in collections.indices { collections[i].assetIDs.removeAll { drop.contains($0) } }
        save()
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([CameraRollCollection].self, from: data) {
            collections = decoded
        }
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

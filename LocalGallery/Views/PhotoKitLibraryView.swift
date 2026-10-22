import SwiftUI
import Photos
import UIKit

/// The Camera Roll tab: the device's own photo library.
///
/// Two top-level screens, switched by a segmented control, the way the
/// system Photos app splits "Library" (the timeline) from "Albums":
///
/// * **Library** — every asset, newest first, grouped by month.
/// * **Albums** — Camera Roll, Recents, Screenshots, Videos, Favorites
///   and the user's own albums, each with a cover and a count.
///
/// Underneath both, three states that have to be told apart because
/// their *recovery* differs: the user has not been asked yet (ask), the
/// user said no (open Settings), and the device is restricted (nothing
/// the app can do). The states are the *only* thing the tab shows until
/// access is granted — a grid rendered before the prompt is answered
/// would look like an empty library rather than an unauthorized one.
///
/// The folder-based library lives in the Photos tab and is untouched by
/// any of this.
struct PhotoKitLibraryView: View {
    /// The two halves of the tab.
    enum Mode: String, CaseIterable, Identifiable {
        case library = "Library"
        case albums = "Albums"
        var id: String { rawValue }
    }

    @Environment(GalleryStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var mode: Mode = .library
    @State private var viewerAssets: [PhotoKitAsset] = []
    @State private var viewerAsset: PhotoKitAsset?
    /// How many assets the browsed collection holds in total, for the
    /// viewer's "N of M" readout. `nil` means "fall back to the list".
    @State private var viewerTotalCount: Int?

    var body: some View {
        Group {
            switch store.photoKit.authorization {
            case .notDetermined:
                notDeterminedState
            case .restricted:
                restrictedState
            case .denied:
                deniedState
            case .limited, .authorized:
                readyBody
            }
        }
        .background(Design.bg)
        // Attached inside the tab's `NavigationStack` (see
        // `LocalGalleryApp`), so the album drill-in pushes onto the
        // router's photo-library path rather than onto a second stack of
        // this view's own.
        .navigationDestination(for: PhotoLibraryRoute.self) { route in
            switch route {
            case .album(let album):
                PhotoKitAlbumDetailView(album: album) { asset, assets, count in
                    openViewer(at: asset, in: assets, total: count)
                }
            }
        }
        .navigationTitle("Camera Roll")
        .navigationBarTitleDisplayMode(.large)
        .task {
            // Only the first load. The pull-to-refresh and the
            // after-a-delete reload both call `loadLibrary()` directly, and
            // re-reading the whole library on every tab switch would be
            // wasted work.
            if !store.photoKit.hasLoaded {
                await store.photoKit.loadLibrary()
            }
        }
        // The user can grant access in Settings while the app is in the
        // background. The tab's `.task` has already run by then, so the
        // state would still read "denied" until the app is killed. This
        // re-reads the status whenever the app comes back to the front.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                let before = store.photoKit.authorization
                store.photoKit.refreshAuthorization()
                if before != store.photoKit.authorization,
                   store.photoKit.authorization.isReadable {
                    await store.photoKit.loadLibrary()
                }
            }
        }
        .fullScreenCover(item: $viewerAsset) { asset in
            PhotoKitViewerView(
                assets: viewerAssets,
                currentAssetID: asset.id,
                // The browsed collection's own count, so "N of M" is the
                // library's (or the album's) size and not the size of the
                // page that was paged in.
                totalCount: viewerTotalCount,
                onDelete: { ids in
                    await store.photoKit.delete(assetIDs: ids)
                }
            )
        }
    }

    // MARK: - Ready

    @ViewBuilder
    private var readyBody: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if store.photoKit.isLoading && store.photoKit.albums.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch mode {
                case .library:
                    PhotoKitTimelineView { asset in
                        openViewer(
                            at: asset,
                            in: store.photoKit.cameraRoll,
                            total: store.photoKit.totalAssetCount
                        )
                    }
                case .albums:
                    PhotoKitAlbumGrid()
                }
            }
        }
    }

    // MARK: - States

    private var notDeterminedState: some View {
        LibraryEmptyState(
            icon: "photo.on.rectangle.angled",
            title: "Access Your Photos",
            message: "Pixel Pic can show the photos already on this device — the camera roll, screenshots and your own albums. Nothing is uploaded.",
            retryTitle: "Continue",
            onRetry: {
                Task {
                    let result = await store.photoKit.requestAccess()
                    if result.isReadable {
                        await store.photoKit.loadLibrary()
                    }
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var restrictedState: some View {
        LibraryEmptyState(
            icon: "lock.trianglebadge.exclamationmark",
            title: "Photos Unavailable",
            message: "Photo access is turned off for this device by a screen-time or device-management policy. Pixel Pic can’t change that."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The user said no. The only way forward is Settings — asking again
    /// would either do nothing (the system no longer shows the prompt for
    /// a denied app) or look like the app is nagging.
    private var deniedState: some View {
        LibraryEmptyState(
            icon: "photo.badge.exclamationmark",
            title: "No Photos Access",
            message: "Pixel Pic doesn’t have permission to read your photo library. You can turn it on in Settings.",
            retryTitle: "Open Settings",
            onRetry: {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Open the viewer on `asset`, browsing `assets`.
    ///
    /// `total` is the size of the *collection* being browsed — the whole
    /// library for the timeline, one album for the drill-in. It is separate
    /// from `assets.count` because the browsed list is usually a page of a
    /// much larger collection, and "12 of 600" when the library holds
    /// 12,043 photos would be a lie.
    private func openViewer(at asset: PhotoKitAsset, in assets: [PhotoKitAsset], total: Int?) {
        viewerAssets = assets.isEmpty ? [asset] : assets
        viewerTotalCount = total
        viewerAsset = asset
    }
}

// MARK: - Timeline

/// Every asset, newest first, grouped by month.
///
/// The month grouping is the same shape as the folder grid's: a caption
/// per month, then a dense grid of cells. Grouping happens over the
/// *fetched* assets only, so a library that has not been paged in yet
/// shows the months that have arrived — which is what the user sees
/// anyway.
struct PhotoKitTimelineView: View {
    /// Called when the user taps an asset.
    let onOpen: (PhotoKitAsset) -> Void

    @Environment(GalleryStore.self) private var store

    @AppStorage("gridSizeTier") private var sizeTier: Int = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var sections: [PhotoKitSection] = []

    private var grid: GridLayoutConfig {
        GridLayoutConfig(sizeTier: sizeTier, isLandscape: verticalSizeClass == .compact)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let cell = grid.cellSize(for: width)

            ScrollView {
                if store.photoKit.cameraRoll.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.stack",
                        description: Text("There are no photos on this device yet.")
                    )
                    .padding(.top, 48)
                } else {
                    LazyVGrid(columns: grid.columns(for: width), spacing: 2) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.assets) { asset in
                                    PhotoKitThumbnailView(
                                        assetID: asset.id,
                                        size: cell,
                                        isVideo: asset.isVideo,
                                        isLivePhoto: asset.isLivePhoto
                                    )
                                    .frame(width: cell, height: cell)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onOpen(asset) }
                                }
                            } header: {
                                PhotoKitSectionHeader(title: section.title)
                                    .id(section.id)
                            }
                        }
                    }
                    // Paging: the last cell of the last section pulls the
                    // next page in when it appears. A device can hold
                    // 100k assets, and fetching them all up front would
                    // stall the first paint for seconds.
                    if store.photoKit.hasMoreToLoad {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await store.photoKit.loadMoreCameraRoll() }
                            }
                    }
                }
            }
            .refreshable {
                await store.photoKit.loadLibrary()
            }
            .overlay(alignment: .bottom) {
                if store.photoKit.isLoading {
                    ProgressView()
                        .padding(.bottom, 12)
                }
            }
        }
        // Keyed on the *asset list*, not its count: a library where one
        // photo was deleted and another added keeps its count, and the
        // sections would then be stale — a deleted photo would still be
        // listed and a new one missing.
        .task(id: store.photoKit.cameraRoll) {
            sections = PhotoKitSection.group(store.photoKit.cameraRoll)
        }
    }
}

/// One month of the timeline.
struct PhotoKitSection: Identifiable {
    let id: String
    let title: String
    let assets: [PhotoKitAsset]

    /// Group a newest-first asset list by month.
    ///
    /// A top-level type rather than a member of the view so a test can
    /// pin the grouping without an actor hop — the same reason
    /// `PhotoSection` (the folder grid's) is a top-level struct.
    ///
    /// The calendar is a parameter because "which month" is a question
    /// with a time-zone answer: the section headings must follow the
    /// *device's* calendar (a photo taken at 11pm on 31 March belongs to
    /// March on the user's phone), but a test needs a fixed one to be
    /// reproducible. The default is the device's.
    static func group(
        _ assets: [PhotoKitAsset],
        calendar: Calendar = .current
    ) -> [PhotoKitSection] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        var out: [PhotoKitSection] = []
        var currentKey = ""
        var currentTitle = ""
        var bucket: [PhotoKitAsset] = []
        for asset in assets {
            let key: String
            let title: String
            if let date = asset.creationDate {
                let components = calendar.dateComponents([.year, .month], from: date)
                // Interpolated rather than `String(format: "%04d-%02d", …)`:
                // `%d` is a 32-bit conversion and `Int` is 64-bit, so the
                // varargs width and the argument width disagree. It reads
                // the right bytes below 2^31, but a section key is not the
                // place to rely on that.
                let year = components.year ?? 0
                let month = components.month ?? 0
                key = "\(year)-\(Self.twoDigits(month))"
                title = formatter.string(from: date)
            } else {
                key = "unknown"
                title = "Unknown Date"
            }
            if key != currentKey {
                if !bucket.isEmpty {
                    out.append(PhotoKitSection(id: currentKey, title: currentTitle, assets: bucket))
                }
                currentKey = key
                currentTitle = title
                bucket = [asset]
            } else {
                bucket.append(asset)
            }
        }
        if !bucket.isEmpty {
            out.append(PhotoKitSection(id: currentKey, title: currentTitle, assets: bucket))
        }
        return out
    }

    /// Zero-padded to two digits.
    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

// MARK: - Album detail (one album's assets)

/// One album's assets, in chronological order.
struct PhotoKitAlbumDetailView: View {
    let album: PhotoKitAlbum
    /// Called when the user taps an asset to open the viewer. The album's
    /// own asset list is passed along so the viewer pages through *this
    /// album*, not through the whole timeline, and the album's own count
    /// so the viewer's "N of M" is the album's size rather than the size
    /// of the page that was paged in.
    let onOpen: (PhotoKitAsset, [PhotoKitAsset], Int) -> Void

    @Environment(GalleryStore.self) private var store

    @State private var assets: [PhotoKitAsset] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    /// Set when a page came back empty.
    ///
    /// The album's count was read when the albums were enumerated, and the
    /// library can shrink in between (the user deletes a photo from another
    /// app). The count would then stay above the number of assets actually
    /// reachable, and the paging sentinel would keep asking for a page
    /// that no longer exists. An empty page ends the paging instead.
    @State private var hasReachedTheEnd = false

    /// Grid density tier, shared with the folder grid's convention.
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var grid: GridLayoutConfig {
        GridLayoutConfig(sizeTier: sizeTier, isLandscape: verticalSizeClass == .compact)
    }

    /// Whether the album has more assets than have been fetched.
    ///
    /// The album's tile carries PhotoKit's own count, which is exact without
    /// loading the assets — so the sentinel knows when to disappear
    /// without having the whole library in memory.
    private var hasMore: Bool {
        !hasReachedTheEnd && assets.count < album.count
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let cell = grid.cellSize(for: width)

            ScrollView {
                if isLoading {
                    ProgressView("Loading…")
                        .padding(.top, 60)
                } else if assets.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.stack",
                        description: Text("This album is empty.")
                    )
                    .padding(.top, 48)
                } else {
                    LazyVGrid(columns: grid.columns(for: width), spacing: 2) {
                        ForEach(assets) { asset in
                            PhotoKitThumbnailView(
                                assetID: asset.id,
                                size: cell,
                                isVideo: asset.isVideo,
                                isLivePhoto: asset.isLivePhoto
                            )
                            .frame(width: cell, height: cell)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(asset, assets, album.count) }
                        }
                    }
                    // Paging: the last cell pulls the next page in. The
                    // Camera Roll album is the whole library, so without
                    // this a 100k-photo device would have to hold every
                    // asset to render its first screen.
                    if hasMore {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { Task { await loadMore() } }
                    }
                }
            }
            .refreshable {
                await load()
            }
            .overlay(alignment: .bottom) {
                if isLoadingMore {
                    ProgressView()
                        .padding(.bottom, 12)
                }
            }
        }
        .background(Design.bg)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sizeTier = GridLayoutConfig.nextTier(from: sizeTier)
                } label: {
                    Image(systemName: grid.nextTierIconName)
                }
                .accessibilityLabel(grid.nextTierAccessibilityLabel)
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        hasReachedTheEnd = false
        assets = await store.photoKit.albumPage(
            album,
            offset: 0,
            limit: PhotoKitService.initialCameraRollLimit
        )
        if assets.count < album.count, assets.isEmpty {
            hasReachedTheEnd = true
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, !isLoading, !hasReachedTheEnd else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let page = await store.photoKit.albumPage(
            album,
            offset: assets.count,
            limit: PhotoKitService.cameraRollPageSize
        )
        if page.isEmpty {
            // Nothing left to fetch — the count the album tile carries is
            // stale. Stop asking, or the sentinel would spin forever.
            hasReachedTheEnd = true
            return
        }
        assets.append(contentsOf: page)
    }
}

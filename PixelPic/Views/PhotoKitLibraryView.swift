import SwiftUI
import Photos
import UIKit

/// The app's one main screen: the device's own photo library, as an
/// Albums grid.
///
/// This is the screen the app opens to. There is no tab bar and no
/// other top-level section: one grid of albums — Camera, Screenshots,
/// Videos, Favorites and the user's own albums — each tile a cover, a
/// name and a count, and tapping a tile opens that album's photos and
/// videos in a grid. The look follows the classic QuickPic layout the
/// redesign is modelled on, in Pixel Pic's own dark appearance with its
/// orange accent.
///
/// Underneath the grid, three states that have to be told apart because
/// their *recovery* differs: the user has not been asked yet (ask), the
/// user said no (open Settings), and the device is restricted (nothing
/// the app can do). The states are the *only* thing the screen shows
/// until access is granted — a grid rendered before the prompt is
/// answered would look like an empty library rather than an
/// unauthorized one.
///
/// New media appears on its own: `PhotoKitService` observes the Photos
/// library, so a screenshot taken while the app is open updates the
/// album counts here and reloads an open album's grid — no relaunch,
/// no pull-to-refresh.
struct PhotoKitLibraryView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewerAssets: [PhotoKitAsset] = []
    @State private var viewerAsset: PhotoKitAsset?
    /// How many assets the browsed collection holds in total, for the
    /// viewer's "N of M" readout. `nil` means "fall back to the list".
    @State private var viewerTotalCount: Int?
    @State private var showSettings = false

    // QuickPic-style home chrome state.
    @State private var showDrawer = false
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var showCreateAlbum = false
    @State private var newAlbumName = ""
    @State private var operationError: String?
    /// The home grid's sort + empty-album visibility (the same keys
    /// Settings writes).
    @AppStorage("albumSortMode") private var sortModeRaw = 0
    @AppStorage("showEmptyAlbums") private var showEmptyAlbums = false
    @AppStorage("albumGridColumns") private var columnCount = 2

    var body: some View {
        ZStack {
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

            if showDrawer {
                drawerOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showDrawer)
        .background(Design.bg)
        .searchable(text: $searchText, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search albums")
        .alert("New Album", isPresented: $showCreateAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") {
                Task { await createAlbum() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Albums are lists in your photo library — creating one doesn't copy or move any photos.")
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        // Attached inside the app's one `NavigationStack` (see
        // `PixelPicApp`), so the album drill-in pushes onto the
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // The reference's blue toolbar, in both appearances.
        .toolbarBackground(Design.toolbarBlue, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 14) {
                    Button {
                        showDrawer = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Menu")
                    Text("Albums")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .foregroundStyle(.white)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                Button {
                    searchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search albums")
                moreMenu
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            // Only the first load. Pull-to-refresh, the library-change
            // observer and the after-a-delete reload all refresh after
            // this, and re-reading the whole library on every appearance
            // would be wasted work.
            if !store.photoKit.hasLoaded {
                await store.photoKit.loadLibrary()
            }
        }
        // The user can grant access in Settings while the app is in the
        // background. The view's `.task` has already run by then, so the
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
                // album's size and not the size of the page that was
                // paged in.
                totalCount: viewerTotalCount,
                onDelete: { ids in
                    await store.photoKit.delete(assetIDs: ids)
                }
            )
        }
    }

    // MARK: - Home chrome (menus, drawer)

    /// Sort + filter, both real: the sort reorders the user's own
    /// albums (system albums stay pinned first), and the toggle is
    /// the same "Show Empty Albums" setting found in Settings.
    private var sortMenu: some View {
        Menu {
            Picker("Sort Albums", selection: $sortModeRaw) {
                Text("Default Order").tag(0)
                Text("Name").tag(1)
                Text("Most Items").tag(2)
            }
            Divider()
            Toggle("Show Empty Albums", isOn: $showEmptyAlbums)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort and filter albums")
    }

    /// The three-dot menu: only actions that exist.
    private var moreMenu: some View {
        Menu {
            Button {
                Task { await store.photoKit.loadLibrary() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                columnCount = columnCount == 2 ? 3 : 2
            } label: {
                Label(columnCount == 2 ? "3 Columns" : "2 Columns", systemImage: "square.grid.3x3")
            }
            Button {
                newAlbumName = ""
                showCreateAlbum = true
            } label: {
                Label("New Album", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// The navigation drawer. Only destinations that exist: the
    /// system albums that are actually in the library, New Album,
    /// and Settings. (The reference's Moments and Wi-Fi Transfer are
    /// not features of this app, so they are not faked here.)
    private var drawerOverlay: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { showDrawer = false }

            VStack(alignment: .leading, spacing: 0) {
                Text("Pixel Pic")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                    .background(Design.toolbarBlue)

                drawerRow(icon: "photo.on.rectangle.angled", title: "Albums") {
                    showDrawer = false
                }
                ForEach(drawerAlbums, id: \.id) { album in
                    drawerRow(icon: album.kind.iconName, title: album.title) {
                        showDrawer = false
                        router.photoLibraryPath.append(.album(album))
                    }
                }

                Divider().padding(.vertical, 8)

                drawerRow(icon: "folder.badge.plus", title: "New Album") {
                    showDrawer = false
                    newAlbumName = ""
                    showCreateAlbum = true
                }
                drawerRow(icon: "gearshape", title: "Settings") {
                    showDrawer = false
                    showSettings = true
                }

                Spacer()
            }
            .frame(width: 280)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Design.bg)
            .transition(.move(edge: .leading))
        }
    }

    /// The system albums the drawer can jump to (the user's own
    /// albums are what the grid itself is for).
    private var drawerAlbums: [PhotoKitAlbum] {
        store.photoKit.albums.filter { $0.kind != .user }
    }

    private func drawerRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 15.5))
            }
            .foregroundStyle(Design.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createAlbum() async {
        let result = await store.photoKit.createAlbum(title: newAlbumName)
        if let message = result.failureMessage {
            operationError = message
        }
    }

    // MARK: - Ready

    @ViewBuilder
    private var readyBody: some View {
        VStack(spacing: 0) {
            if store.photoKit.authorization == .limited {
                limitedBanner
            }

            if store.photoKit.isLoading && store.photoKit.albums.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.photoKit.hasLoaded
                        && store.photoKit.albums.allSatisfy({ $0.count == 0 }) {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.stack",
                    description: Text("There are no photos or videos on this device yet. New photos and screenshots will appear here automatically.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhotoKitAlbumGrid(searchText: searchText)
            }
        }
    }

    /// Limited access is readable, but only for the subset the user
    /// picked. Say so on the gallery itself — otherwise an album that
    /// looks short reads as a bug rather than as the user's own choice —
    /// and give the way back to the system setting.
    private var limitedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(Design.ink2)
            Text("Limited access — showing the photos you selected.")
                .font(.footnote)
                .foregroundStyle(Design.ink2)
            Spacer()
            Button("Manage") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Design.bgGrouped)
    }

    // MARK: - States

    private var notDeterminedState: some View {
        LibraryEmptyState(
            icon: "photo.on.rectangle.angled",
            title: "Access Your Photos",
            message: "Pixel Pic shows the photos already on this device — your Camera, Screenshots and your own albums. Nothing is uploaded.",
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
    /// `total` is the size of the *collection* being browsed — one album
    /// for a drill-in. It is separate from `assets.count` because the
    /// browsed list is usually a page of a much larger collection, and
    /// "12 of 600" when the album holds 12,043 photos would be a lie.
    private func openViewer(at asset: PhotoKitAsset, in assets: [PhotoKitAsset], total: Int?) {
        viewerAssets = assets.isEmpty ? [asset] : assets
        viewerTotalCount = total
        viewerAsset = asset
    }
}

// MARK: - Month grouping

/// One month of a photo list.
///
/// A top-level type rather than a member of a view so a test can pin the
/// grouping without an actor hop — the same reason `PhotoSection` (the
/// folder grid's) is a top-level struct.
struct PhotoKitSection: Identifiable {
    let id: String
    let title: String
    let assets: [PhotoKitAsset]

    /// Group a newest-first asset list by month.
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

/// One album's assets, newest first, in a grid.
struct PhotoKitAlbumDetailView: View {
    let album: PhotoKitAlbum
    /// Called when the user taps an asset to open the viewer. The album's
    /// own asset list is passed along so the viewer pages through *this
    /// album*, not through the whole library, and the album's own count
    /// so the viewer's "N of M" is the album's size rather than the size
    /// of the page that was paged in.
    let onOpen: (PhotoKitAsset, [PhotoKitAsset], Int) -> Void

    @Environment(GalleryStore.self) private var store

    @State private var assets: [PhotoKitAsset] = []
    /// The album's live count. Seeded from the tile's snapshot and
    /// refreshed whenever the library changes, so the paging sentinel
    /// and the viewer's "N of M" follow the library rather than the
    /// moment the tile was tapped.
    @State private var currentCount: Int = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    /// Set when a page came back empty.
    ///
    /// The album's count was read when the albums were enumerated, and
    /// the library can shrink in between (the user deletes a photo from
    /// another app). The count would then stay above the number of
    /// assets actually reachable, and the paging sentinel would keep
    /// asking for a page that no longer exists. An empty page ends the
    /// paging instead.
    @State private var hasReachedTheEnd = false

    // Selection mode (long-press a cell to enter).
    @State private var selection = PhotoSelectionModel()
    @State private var showSelectionDeleteConfirm = false
    @State private var showAlbumPicker = false
    @State private var shareItems: PhotoKitShareItems?
    @State private var isSharingSelection = false
    @State private var operationError: String?
    @State private var editorAsset: PhotoKitAsset?

    /// Grid density tier, shared with the folder grid's convention.
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var grid: GridLayoutConfig {
        GridLayoutConfig(sizeTier: sizeTier, isLandscape: verticalSizeClass == .compact)
    }

    /// Whether the album has more assets than have been fetched.
    ///
    /// The album's count comes from PhotoKit, which is exact without
    /// loading the assets — so the sentinel knows when to disappear
    /// without having the whole album in memory.
    private var hasMore: Bool {
        !hasReachedTheEnd && assets.count < currentCount
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
                            cell(for: asset, size: cell)
                        }
                    }
                    // Paging: the last cell pulls the next page in. An
                    // album can hold most of a 100k-photo library, so
                    // without this the grid would have to hold every
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
            // Warm the thumbnails of the page just loaded, ahead of the
            // scroll. Keyed on the last asset, so it re-runs when a new
            // page lands (or a library change replaces the list) and not
            // on every render.
            .task(id: assets.last?.id) {
                await store.photoKit.preheatThumbnails(
                    for: assets.map(\.id),
                    size: cell
                )
            }
        }
        .background(Design.bg)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selection.isActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { selection.cancel() }
                }
                ToolbarItem(placement: .principal) {
                    Text(selection.count == 1 ? "1 Selected" : "\(selection.count) Selected")
                        .font(.system(size: 15, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select All") {
                        selection.selectAll(assets.map(\.id))
                    }
                    .disabled(assets.isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sizeTier = GridLayoutConfig.nextTier(from: sizeTier)
                    } label: {
                        Image(systemName: grid.nextTierIconName)
                    }
                    .accessibilityLabel(grid.nextTierAccessibilityLabel)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive {
                selectionActionBar
            }
        }
        .sheet(item: $shareItems) { items in
            ShareSheet(items: items.urls)
        }
        .sheet(item: $editorAsset) { asset in
            PhotoKitPhotoEditorView(asset: asset)
        }
        .sheet(isPresented: $showAlbumPicker) {
            albumPicker
        }
        .alert("Delete \(selection.count) item\(selection.count == 1 ? "" : "s")?", isPresented: $showSelectionDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { await deleteSelection() }
            }
        } message: {
            Text("This removes them from your device's photo library. It cannot be undone.")
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .onChange(of: assets.map(\.id)) { _, _ in
            // A reload replaced the list: drop selected ids that are
            // no longer here, keep the rest (ids, not indexes, so a
            // reshuffled grid cannot retarget the selection).
            selection.prune(toPresentIDs: Set(assets.map(\.id)))
        }
        .task {
            currentCount = album.count
            await load()
        }
        // A photo or screenshot taken while this album is open: the
        // service has already refreshed the album list, so re-read the
        // count and reload the visible page — the new item is newest,
        // so it lands at the top of the grid without a manual refresh.
        .onChange(of: store.photoKit.libraryChangeToken) { _, _ in
            Task { await reloadAfterLibraryChange() }
        }
    }

    /// One grid cell, selection-aware: a long-press enters
    /// selection mode; in selection mode a tap toggles instead of
    /// opening; selected cells carry a checkmark badge and a ring.
    private func cell(for asset: PhotoKitAsset, size cell: CGFloat) -> some View {
        let isSelected = selection.contains(asset.id)
        return PhotoKitThumbnailView(
            assetID: asset.id,
            size: cell,
            isVideo: asset.isVideo,
            isLivePhoto: asset.isLivePhoto
        )
        .frame(width: cell, height: cell)
        .overlay(alignment: .topTrailing) {
            if selection.isActive {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? Design.accentColor : .white)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .padding(4)
            }
        }
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Design.accentColor, lineWidth: 2.5)
            }
        }
        .opacity(selection.isActive && !isSelected ? 0.75 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.isActive {
                selection.toggle(asset.id)
            } else {
                onOpen(asset, assets, currentCount)
            }
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            if !selection.isActive {
                selection.begin(with: asset.id)
            }
        }
    }

    /// The selection action bar: Share, Add to Album, Delete, and —
    /// with exactly one photo selected — Edit.
    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            selectionAction(icon: "square.and.arrow.up", label: "Share", disabled: selection.isEmpty || isSharingSelection) {
                Task { await shareSelection() }
            }
            selectionAction(icon: "folder.badge.plus", label: "Add to Album", disabled: selection.isEmpty) {
                showAlbumPicker = true
            }
            if selection.count == 1, let only = selection.orderedSelection(from: assets).first, !only.isVideo {
                selectionAction(icon: "crop", label: "Edit", disabled: false) {
                    editorAsset = only
                }
            }
            selectionAction(icon: "trash", label: "Delete", disabled: selection.isEmpty) {
                showSelectionDeleteConfirm = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func selectionAction(
        icon: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    /// Destination picker for Add / Move.
    ///
    /// The copy is honest about PhotoKit semantics: "Add" references
    /// the same photos in another album (nothing is copied), and
    /// "Move" — add + remove from this album — only exists when this
    /// album is one of the user's own, because Camera, Screenshots
    /// and the other system albums compute their membership from
    /// each photo itself; there is no list to remove from.
    @State private var pickerMove = false

    private var albumPicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.photoKit.albums.filter { $0.kind == .user && $0.id != album.id }) { destination in
                        Button(destination.title) {
                            Task { await applyAlbumOperation(to: destination) }
                        }
                    }
                } header: {
                    Text(pickerMove ? "Move to" : "Add to")
                } footer: {
                    Text("Adding references the same photos in the other album — nothing is copied or duplicated.")
                }

                if album.kind == .user {
                    Section {
                        Toggle("Move (remove from \(album.title))", isOn: $pickerMove)
                    } footer: {
                        Text("Move adds the photos to the destination and removes them from \(album.title). The photos themselves stay in your library.")
                    }
                } else {
                    Section {
                        Text("Move isn't available from \(album.title): its contents are worked out from each photo itself, not stored as a list. Adding to another album is always available.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAlbumPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func applyAlbumOperation(to destination: PhotoKitAlbum) async {
        let ids = Array(selection.selectedIDs)
        let result: PhotoKitOperationResult
        if pickerMove, album.kind == .user {
            result = await store.photoKit.moveAssets(ids, from: album.id, to: destination.id)
        } else {
            result = await store.photoKit.addAssets(ids, toAlbumID: destination.id)
        }
        showAlbumPicker = false
        if let message = result.failureMessage {
            operationError = message
        } else {
            selection.cancel()
            await refreshAfterOperation()
        }
    }

    private func shareSelection() async {
        isSharingSelection = true
        defer { isSharingSelection = false }
        var urls: [URL] = []
        for asset in selection.orderedSelection(from: assets) {
            if let url = await store.photoKit.exportToTemporaryFile(for: asset.id) {
                urls.append(url)
            }
        }
        if urls.isEmpty {
            operationError = "The selected items couldn't be prepared for sharing."
        } else {
            shareItems = PhotoKitShareItems(urls: urls)
        }
    }

    private func deleteSelection() async {
        let ids = Array(selection.selectedIDs)
        let ok = await store.photoKit.delete(assetIDs: ids)
        if ok {
            selection.cancel()
            await refreshAfterOperation()
        } else {
            operationError = "The selected items couldn't be deleted. If you gave Pixel Pic limited access, some of them may be outside the allowed set."
        }
    }

    /// After a mutation, re-read this album's page and count — the
    /// change observer will also fire, but the grid should be right
    /// when the action finishes, not when the callback lands.
    private func refreshAfterOperation() async {
        if let fresh = store.photoKit.albums.first(where: { $0.id == album.id }) {
            currentCount = fresh.count
        }
        await load()
    }

    private func load() async {
        isLoading = true
        hasReachedTheEnd = false
        assets = await store.photoKit.albumPage(
            album,
            offset: 0,
            limit: PhotoKitService.initialAlbumLimit
        )
        if assets.count < currentCount, assets.isEmpty {
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
            limit: PhotoKitService.albumPageSize
        )
        if page.isEmpty {
            // Nothing left to fetch — the count the album tile carries is
            // stale. Stop asking, or the sentinel would spin forever.
            hasReachedTheEnd = true
            return
        }
        assets.append(contentsOf: page)
    }

    /// Reload after a Photos-library change, keeping the depth the user
    /// had already paged to so a new screenshot does not throw them back
    /// to the top of a long album.
    private func reloadAfterLibraryChange() async {
        if let fresh = store.photoKit.albums.first(where: { $0.id == album.id }) {
            currentCount = fresh.count
        }
        let target = max(assets.count, PhotoKitService.initialAlbumLimit)
        let page = await store.photoKit.albumPage(
            album,
            offset: 0,
            limit: target
        )
        assets = page
        hasReachedTheEnd = page.isEmpty && currentCount > 0
    }
}

/// Identifiable wrapper for a multi-item share sheet.
struct PhotoKitShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

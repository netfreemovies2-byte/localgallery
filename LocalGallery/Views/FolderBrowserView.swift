import SwiftUI

struct FolderBrowserView: View {
    @Environment(GalleryStore.self) private var store
    var folder: PhotoFolder? = nil
    /// Only the root tab should show the gear. Child browsers leave it off.
    var isRoot: Bool = true

    @State private var showSettings = false
    @State private var showFolderPicker = false

    private var displayFolder: PhotoFolder? {
        if let folder {
            // Pushed screens hold a snapshot from navigation time; re-resolve
            // against the live tree so a rescan that dropped files updates
            // counts and photos instead of leaving a stale child on screen.
            return store.rootFolder?.folder(withID: folder.id)
        }
        return store.rootFolder
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if folder != nil {
                childBody
            } else {
                rootBody
            }
        }
        // Live name first; the NavigationLink snapshot covers a child whose
        // node was deleted mid-drill-in; "Folders" only at the root before
        // the bookmark resolves, so the large title does not flash "".
        .navigationTitle(displayFolder?.name ?? folder?.name ?? (isRoot ? "Folders" : ""))
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar {
            // Always include the banner — it returns EmptyView when no
            // scan is running. The `if store.scanProgress != nil` used to
            // live here, but reading scanProgress in the parent body made
            // every progress tick re-evaluate FolderBrowserView and the
            // List of folder rows below it. Scoping the read to
            // ScanProgressBanner.body keeps the parent untouched.
            ToolbarItem(placement: .principal) {
                ScanProgressBanner()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if displayFolder?.subfolders.isEmpty == false {
                    Menu {
                        Picker("Sort Folders", selection: $store.folderSortOrder) {
                            ForEach(FolderSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                if isRoot {
                    SettingsToolbarButton(isPresented: $showSettings)
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .libraryFolderPicker(isPresented: $showFolderPicker)
    }

    /// Root tab only. A hidden library takes the whole screen — the cached
    /// tree may still be in memory after an unlistable root, and showing it
    /// would look like the library was still there. The cold-launch spinner
    /// is `isScanning && displayFolder == nil` so a Reload Library pass does
    /// not hide a tree we already have.
    @ViewBuilder
    private var rootBody: some View {
        if store.libraryAvailability == .unavailable {
            unavailableState
        } else if store.libraryAvailability == .permissionDenied {
            permissionDeniedState
        } else if store.isScanning && displayFolder == nil {
            ProgressView("Scanning folder…")
        } else if let folder = displayFolder {
            folderContent(folder)
        } else if store.libraryAvailability == .empty {
            emptyLibraryState
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var childBody: some View {
        // An unlistable root keeps `rootFolder` in memory so lookup would
        // still hit and show a ghost tree. The root tab already hid that; a
        // pushed child has to as well.
        if store.libraryAvailability == .unavailable {
            unavailableState
        } else if store.libraryAvailability == .permissionDenied {
            permissionDeniedState
        } else if let folder = displayFolder {
            folderContent(folder)
        } else {
            ContentUnavailableView(
                "This folder is no longer available",
                systemImage: "folder"
            )
        }
    }

    private var emptyState: some View {
        LibraryEmptyState(icon: "folder", title: "No Folder Selected",
                          message: "Set a folder in Settings to get started.")
    }

    private var emptyLibraryState: some View {
        LibraryEmptyState.selectedFolderEmpty(icon: "folder", title: "No Photos")
    }

    private var unavailableState: some View {
        LibraryEmptyState.unavailable(icon: "folder") {
            Task { await store.rescan(kind: .light, silent: false) }
        }
    }

    /// The folder exists but we may not read it — re-picking it is the only
    /// fix, so the action opens the system picker directly.
    private var permissionDeniedState: some View {
        LibraryEmptyState.permissionDenied(icon: "lock.trianglebadge.exclamationmark") {
            showFolderPicker = true
        }
    }

    @ViewBuilder
    private func folderContent(_ folder: PhotoFolder) -> some View {
        let sortedSubfolders = store.sortFolders(folder.subfolders)
        let isRootFolder = self.folder == nil
        // The derivation is pure and lives with the view that draws it, so
        // it can be pinned in a test without a live Store.
        let album = AlbumGridRules.makePhotosAlbum(
            for: folder,
            isLibraryRoot: isRootFolder,
            libraryPhotoCount: store.allPhotos.count
        )

        if album == nil && sortedSubfolders.isEmpty {
            ContentUnavailableView(
                "No Photos Found",
                systemImage: "photo",
                description: Text("This folder doesn't contain any images.")
            )
        } else {
            AlbumTileGrid(
                folder: folder,
                photosAlbum: album,
                subfolders: sortedSubfolders,
                isLibraryRoot: isRootFolder
            )
            .refreshable {
                await store.rescan(kind: .light)
            }
        }
    }
}

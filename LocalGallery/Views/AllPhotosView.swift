import SwiftUI

struct AllPhotosView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var seedTags: [TagSuggestion] = []
    @State private var showSettings = false
    @State private var showFolderPicker = false

    var body: some View {
        Group {
            // Cold-launch spinner only while there is nothing to show.
            // A hidden library wins even when `allPhotos` still holds a cache:
            // rendering the grid would look like the library was still there.
            if store.isScanning && store.allPhotos.isEmpty && !store.libraryAvailability.hidesLibrary {
                chrome { ProgressView("Scanning…") }
            } else {
                switch store.libraryAvailability {
                case .noneSelected:
                    chrome { emptyState }
                case .unavailable:
                    chrome { unavailableState }
                case .permissionDenied:
                    chrome { permissionDeniedState }
                case .empty:
                    chrome { emptyLibraryState }
                case .ready:
                    readyBody
                }
            }
        }
        .background(Design.bg)
        .libraryFolderPicker(isPresented: $showFolderPicker)
        .onAppear { applyPendingTagFilter() }
        .onChange(of: router.pendingPhotosTagFilter) { _, _ in applyPendingTagFilter() }
    }

    private func applyPendingTagFilter() {
        guard !router.pendingPhotosTagFilter.isEmpty else { return }
        let resolved = router.pendingPhotosTagFilter.compactMap { path in
            store.allTags.first { $0.fullPath == path }
        }
        seedTags = resolved
        router.pendingPhotosTagFilter = []
    }

    @ViewBuilder
    private var readyBody: some View {
        if !store.hasSortedPhotos {
            // The library is loaded but the core has not published its sort
            // yet — a few hundred milliseconds on a cold launch with a warm
            // cache. `PhotoGridScreen` would render `sortedPhotos == []` as
            // "No photos match.", which is a *filter* message and reads as
            // if the user's library had gone missing. A spinner is the
            // honest state; showing the photos unsorted would be worse,
            // because the grid would then visibly reshuffle under the
            // user's thumb the moment the sort lands.
            chrome { ProgressView() }
        } else {
            PhotoGridScreen(
                title: "Photos",
                photos: store.sortedPhotos,
                isRoot: true,
                showSearch: true,
                showVisibleDateRange: true,
                initialTags: seedTags
            )
            // Force fresh PhotoGridScreen state when a deep-link seeds new
            // tags so its internal @State activeTags actually adopts them.
            .id("photogrid-" + seedTags.map(\.id).joined(separator: "|"))
        }
    }

    private var emptyState: some View {
        LibraryEmptyState(icon: "photo.stack", title: "No Photos")
    }

    private var emptyLibraryState: some View {
        LibraryEmptyState.selectedFolderEmpty(icon: "photo.stack", title: "No Photos")
    }

    private var unavailableState: some View {
        LibraryEmptyState.unavailable(icon: "photo.stack") {
            Task { await store.rescan(kind: .light, silent: false) }
        }
    }

    /// The folder exists but we may not read it. Re-picking it is the only
    /// fix — a retry would fail identically — so the action opens the
    /// system picker directly instead of bouncing the user through Settings.
    private var permissionDeniedState: some View {
        LibraryEmptyState.permissionDenied(icon: "lock.trianglebadge.exclamationmark") {
            showFolderPicker = true
        }
    }

    /// Title and gear for the states `PhotoGridScreen` does not render. The
    /// grid carries its own, so this wraps only the placeholders — applying it
    /// to the whole tab would stack a second title and a second gear on top of
    /// the grid's.
    @ViewBuilder
    private func chrome(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Matches Collections and Folders: the banner is always in the
                // principal slot and returns EmptyView when no scan is
                // running, keeping the `store.scanProgress` read scoped to
                // ScanProgressBanner.body.
                ToolbarItem(placement: .principal) {
                    ScanProgressBanner()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsToolbarButton(isPresented: $showSettings)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

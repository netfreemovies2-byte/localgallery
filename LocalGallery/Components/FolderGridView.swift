import SwiftUI

struct FolderGridView: View {
    /// Fallback title when the live node is gone (deleted while this grid
    /// was on the stack). The live folder's name wins when the lookup hits.
    let title: String
    let folderID: UUID

    @Environment(GalleryStore.self) private var store
    @State private var showFolderPicker = false

    private var liveFolder: PhotoFolder? {
        store.rootFolder?.folder(withID: folderID)
    }

    var body: some View {
        Group {
            if store.libraryAvailability == .unavailable {
                LibraryEmptyState.unavailable(icon: "folder") {
                    Task { await store.rescan(kind: .light, silent: false) }
                }
                .navigationTitle(title)
            } else if store.libraryAvailability == .permissionDenied {
                LibraryEmptyState.permissionDenied(icon: "lock.trianglebadge.exclamationmark") {
                    showFolderPicker = true
                }
                .navigationTitle(title)
            } else if let liveFolder {
                let photos = liveFolder.photos
                PhotoGridScreen(
                    title: liveFolder.name,
                    subtitle: "\(photos.count) photos",
                    photos: photos,
                    showSearch: true
                )
            } else {
                ContentUnavailableView(
                    "This folder is no longer available",
                    systemImage: "folder"
                )
                .navigationTitle(title)
            }
        }
        // Attached once, outside the branches: the picker has to be
        // reachable from the permission-denied state, and a modifier that
        // lives inside one `if` disappears the moment the state changes.
        .libraryFolderPicker(isPresented: $showFolderPicker)
    }
}

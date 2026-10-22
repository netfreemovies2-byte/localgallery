import SwiftUI
import UniformTypeIdentifiers

/// Picks the library folder and re-establishes access to it.
///
/// The system picker is the only way to obtain a security-scoped bookmark,
/// so this is the one place that flow lives. It was inline in
/// `SettingsView`; the permission-denied empty state needs the same action
/// ("Choose Folder…" when the scope lapsed), and duplicating the bookmark /
/// scope / rescan dance in two places is how the two drift apart.
struct LibraryFolderPicker: ViewModifier {
    /// True while the picker is presented.
    @Binding var isPresented: Bool
    /// Called after a folder has been chosen, access re-established, and the
    /// first scan has been kicked off. The Store owns the scan; this only
    /// reports that the flow finished.
    var onPicked: (() -> Void)? = nil

    @Environment(GalleryStore.self) private var store

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder]) { result in
                guard case .success(let pickerURL) = result else { return }
                // Bookmark creation needs an active security scope; the
                // long-lived scope is then (re)opened on the *resolved* URL
                // via startAccessingFolder, so this transient one is closed
                // immediately.
                _ = pickerURL.startAccessingSecurityScopedResource()
                store.saveBookmark(for: pickerURL)
                pickerURL.stopAccessingSecurityScopedResource()

                if let resolvedURL = store.resolveBookmark() {
                    Task {
                        store.startAccessingFolder(resolvedURL)
                        await store.scanFolder(at: resolvedURL)
                    }
                }
                onPicked?()
            }
    }
}

extension View {
    /// Attach the library folder picker. See `LibraryFolderPicker`.
    func libraryFolderPicker(
        isPresented: Binding<Bool>,
        onPicked: (() -> Void)? = nil
    ) -> some View {
        modifier(LibraryFolderPicker(isPresented: isPresented, onPicked: onPicked))
    }
}

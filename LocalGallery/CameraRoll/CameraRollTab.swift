import SwiftUI

/// Root of the "Camera Roll" tab: the iPhone Photos library (PhotoKit).
/// This is separate from the Folders tab, which browses files the user
/// granted through the Files app — selecting a Files folder never grants
/// access to Photos, and vice versa.
struct CameraRollTab: View {
    @State private var library = CameraRollLibrary()
    @State private var collections = CameraRollCollectionStore()
    @State private var mode: Mode = .photos
    @State private var showSettings = false

    enum Mode: String, CaseIterable, Identifiable {
        case photos = "Photos"
        case albums = "Albums"
        case collections = "Collections"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch library.access {
                case .notDetermined:
                    CameraRollPermissionView(kind: .request) { Task { await library.requestAccess() } }
                case .denied:
                    CameraRollPermissionView(kind: .denied) { library.openAppSettings() }
                case .restricted:
                    CameraRollPermissionView(kind: .restricted) {}
                case .limited, .authorized:
                    home
                }
            }
            .navigationTitle("Camera Roll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if library.access.canRead {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Camera Roll settings")
                    }
                }
            }
            .navigationDestination(for: CameraRollAlbum.self) { album in
                CameraRollGridView(title: album.title, source: .album(album))
            }
            .navigationDestination(for: CameraRollCollection.self) { collection in
                CameraRollGridView(title: collection.name, source: .collection(collection.id))
            }
        }
        .environment(library)
        .environment(collections)
        .task { library.start() }
        .sheet(isPresented: $showSettings) {
            CameraRollSettingsView()
                .environment(library)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // The user may have changed access in iOS Settings.
            library.refreshAccess()
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)

            if library.access == .limited { limitedBanner }

            switch mode {
            case .photos:
                CameraRollGridView(title: "Photos", source: .library)
                    .id(library.access)   // fresh model after an access change
            case .albums:
                CameraRollAlbumsView()
            case .collections:
                CameraRollCollectionsView()
            }
        }
    }

    private var limitedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
            Text("Limited access: only photos you chose are shown.")
                .font(.footnote)
            Spacer()
            Button("Manage") { library.presentLimitedLibraryPicker() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: - Permission states

struct CameraRollPermissionView: View {
    enum Kind { case request, denied, restricted }
    let kind: Kind
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            switch kind {
            case .request: Button("Allow Photos Access", action: action).buttonStyle(.borderedProminent)
            case .denied: Button("Open Settings", action: action).buttonStyle(.borderedProminent)
            case .restricted: EmptyView()
            }
        }
    }

    private var title: String {
        switch kind {
        case .request: "See your Photos library"
        case .denied: "Photos access is off"
        case .restricted: "Photos access is restricted"
        }
    }

    private var icon: String {
        switch kind {
        case .request: "photo.on.rectangle.angled"
        case .denied: "lock.slash"
        case .restricted: "hand.raised.slash"
        }
    }

    private var message: String {
        switch kind {
        case .request:
            "LocalGallery shows your iPhone's photos and videos here, and everything stays on your device. The Folders tab is separate: it browses files you pick in the Files app."
        case .denied:
            "Turn on Photos access for LocalGallery in Settings to browse your camera roll. Your Files folders keep working without it."
        case .restricted:
            "Photos access is restricted on this device (for example by Screen Time or a device profile), so it can't be turned on from here."
        }
    }
}

// MARK: - Albums

struct CameraRollAlbumsView: View {
    @Environment(CameraRollLibrary.self) private var library
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)]

    var body: some View {
        let albums = library.visibleAlbums
        Group {
            if library.isLoadingAlbums && library.albums.isEmpty {
                ProgressView("Loading albums…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "rectangle.stack",
                                       description: Text("No albums are available, or all of them are hidden."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) { CameraRollAlbumCard(album: album) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    Text("These are albums from the Photos app. Folders from the Files app are in the Folders tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
        }
    }
}

struct CameraRollAlbumCard: View {
    let album: CameraRollAlbum
    @Environment(CameraRollLibrary.self) private var library
    @Environment(\.displayScale) private var displayScale
    @State private var cover: UIImage?
    @State private var coverMissing = false

    var body: some View {
        let hidden = library.settings.isHidden(album.id)
        VStack(alignment: .leading, spacing: 5) {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else if coverMissing || album.assetCount == 0 {
                        Image(systemName: "photo.on.rectangle").font(.title).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(hidden ? 0.45 : 1)
            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 4) {
                Text("\(album.assetCount)").font(.caption).foregroundStyle(.secondary)
                if album.source == .smart {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                }
                if hidden { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .contextMenu {
            Button(hidden ? "Show album" : "Hide album", systemImage: hidden ? "eye" : "eye.slash") {
                library.settings.setHidden(!hidden, albumID: album.id)
            }
        }
        .task(id: "\(album.id)-\(album.assetCount)-\(library.settings.includeVideos)") { await loadCover() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.title), \(album.assetCount) items")
    }

    private func loadCover() async {
        coverMissing = false
        guard album.assetCount > 0,
              let id = await CameraRollImageService.coverAssetID(albumID: album.id, includeVideos: library.settings.includeVideos)
        else { cover = nil; coverMissing = true; return }
        let side = 220 * displayScale
        let image = await CameraRollImageService.shared.thumbnail(id: id, pixelSize: CGSize(width: side, height: side)).value
        guard !Task.isCancelled else { return }
        cover = image
        coverMissing = image == nil
    }
}

// MARK: - Collections

struct CameraRollCollectionsView: View {
    @Environment(CameraRollCollectionStore.self) private var store
    @State private var newName = ""
    @State private var showNew = false
    @State private var renaming: CameraRollCollection?
    @State private var renameText = ""

    var body: some View {
        Group {
            if store.collections.isEmpty {
                ContentUnavailableView {
                    Label("No collections yet", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Collections are your own groupings inside this app. They don't create albums in the Photos app. Select photos and choose Add to Collection.")
                } actions: {
                    Button("New Collection") { showNew = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(store.collections) { c in
                        NavigationLink(value: c) {
                            HStack {
                                Text(c.name)
                                Spacer()
                                Text("\(c.assetIDs.count)").foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.delete(c.id) }
                            Button("Rename") { renaming = c; renameText = c.name }.tint(.blue)
                        }
                    }
                    Section {
                        Button("New Collection", systemImage: "plus") { showNew = true }
                    }
                }
            }
        }
        .alert("New collection", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { store.create(name: newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let r = renaming { store.rename(r.id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: - Settings

struct CameraRollSettingsView: View {
    @Environment(CameraRollLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = library.settings
        NavigationStack {
            Form {
                Section("Show") {
                    Toggle("Include videos", isOn: $settings.includeVideos)
                        .onChange(of: settings.includeVideos) { _, _ in library.reloadAlbums() }
                    Toggle("Show hidden albums", isOn: $settings.showHiddenAlbums)
                }
                Section("Order") {
                    Picker("Sort by date", selection: $settings.newestFirst) {
                        Text("Newest first").tag(true)
                        Text("Oldest first").tag(false)
                    }
                    Picker("Group timeline", selection: $settings.grouping) {
                        ForEach(CameraRollGrouping.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Photos access") {
                    LabeledContent("Status", value: statusText)
                    if library.access == .limited {
                        Button("Choose more photos") { library.presentLimitedLibraryPicker() }
                    }
                    Button("Open iOS Settings") { library.openAppSettings() }
                }
                Section {
                    Text("Hiding an album only hides it in this app; nothing changes in Photos. Press and hold an album to hide or show it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Camera Roll settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var statusText: String {
        switch library.access {
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .limited: "Limited"
        case .authorized: "Full access"
        }
    }
}

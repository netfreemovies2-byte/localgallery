import Photos
import SwiftUI

// MARK: - Thumbnail cache + cell

/// Small in-memory cache of decoded grid thumbnails. Bounded by count and cost.
private enum CameraRollThumbnailCache {
    nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 800
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    static func key(_ id: String, _ pixel: Int) -> NSString { "\(id)@\(pixel)" as NSString }
}

/// One grid cell. The loaded image is stored together with the asset id it
/// belongs to, so a recycled cell can never show the previous asset's image.
struct CameraRollThumbnailView: View {
    let item: CameraRollItem
    let side: CGFloat
    var isSelected: Bool = false
    var selectionMode: Bool = false

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (id: String, image: UIImage)?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let loaded, loaded.id == item.id {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            } else if failed {
                Image(systemName: item.isVideo ? "video.slash" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .bottomLeading) {
            if item.isVideo {
                Label(Self.durationText(item.duration), systemImage: "play.fill")
                    .font(.system(size: max(9, side * 0.085), weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(3)
            } else if item.isAnimated {
                Text("GIF")
                    .font(.system(size: max(9, side * 0.085), weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
                    .shadow(radius: 2)
                    .padding(4)
            } else if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: max(9, side * 0.085)))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(4)
            }
        }
        .overlay {
            if isSelected { Color.accentColor.opacity(0.25) }
        }
        .contentShape(Rectangle())
        .task(id: item.id) { await load() }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func load() async {
        let pixel = Int((side * displayScale).rounded(.up))
        let key = CameraRollThumbnailCache.key(item.id, pixel)
        if let cached = CameraRollThumbnailCache.cache.object(forKey: key) {
            loaded = (item.id, cached)
            return
        }
        failed = false
        let size = CGSize(width: pixel, height: pixel)
        let image = await CameraRollImageService.shared.thumbnail(id: item.id, pixelSize: size).value
        guard !Task.isCancelled else { return }   // scrolled away: the request was cancelled
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            CameraRollThumbnailCache.cache.setObject(image, forKey: key, cost: cost)
            loaded = (item.id, image)
        } else {
            failed = true
        }
    }

    private var accessibilityText: String {
        var parts = [item.isVideo ? "Video" : (item.isAnimated ? "GIF" : "Photo")]
        if let d = item.creationDate { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        if item.isVideo { parts.append(Self.durationText(item.duration)) }
        if item.isFavorite { parts.append("Favorite") }
        return parts.joined(separator: ", ")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Source of a grid

enum CameraRollGridSource: Hashable, Sendable {
    case library
    case album(CameraRollAlbum)
    case collection(UUID)
}

// MARK: - Model

@Observable
@MainActor
final class CameraRollGridModel {
    let source: CameraRollGridSource

    private(set) var allItems: [CameraRollItem] = []
    private(set) var isLoading = true
    private(set) var sections: [CameraRollSection] = []
    private(set) var visibleItems: [CameraRollItem] = []

    var filter: CameraRollMediaFilter = .all
    var searchText = ""
    var selection = CameraRollSelection()
    private(set) var isSelecting = false

    /// Entering/leaving selection mode; leaving clears the selection.
    func setSelecting(_ on: Bool) {
        isSelecting = on
        if !on { selection.clear() }
    }

    @ObservationIgnored private var settings: CameraRollSettings?
    @ObservationIgnored private var collectionIDs: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(source: CameraRollGridSource) { self.source = source }

    func bind(settings: CameraRollSettings) { self.settings = settings }

    /// Reloads from PhotoKit. Off-main; the array swap is on main.
    func reload(collectionAssetIDs: [String] = []) {
        guard let settings else { return }
        collectionIDs = collectionAssetIDs
        loadTask?.cancel()
        let includeVideos = settings.includeVideos
        let newestFirst = settings.newestFirst
        let source = self.source
        let ids = collectionAssetIDs
        if allItems.isEmpty { isLoading = true }
        loadTask = Task { [weak self] in
            let loaded: [CameraRollItem]
            switch source {
            case .library:
                loaded = await CameraRollImageService.loadItems(albumID: nil, includeVideos: includeVideos, newestFirst: newestFirst)
            case .album(let album):
                loaded = await CameraRollImageService.loadItems(albumID: album.id, includeVideos: includeVideos, newestFirst: newestFirst)
            case .collection:
                loaded = await CameraRollImageService.loadItems(ids: ids)
            }
            guard !Task.isCancelled, let self else { return }
            self.allItems = loaded
            self.isLoading = false
            self.selection.prune(keeping: loaded)
            self.recompute()
        }
    }

    /// Re-derive without refetching (filter/search/sort/grouping change).
    func recompute() {
        guard let settings else { return }
        visibleItems = CameraRollQuery.apply(
            to: allItems,
            includeVideos: settings.includeVideos,
            filter: filter,
            searchText: searchText,
            newestFirst: settings.newestFirst
        )
        sections = CameraRollQuery.sections(from: visibleItems, grouping: settings.grouping)
    }

    func removeLocally(ids: Set<String>) {
        allItems.removeAll { ids.contains($0.id) }
        selection.prune(keeping: allItems)
        recompute()
    }

    func updateFavorite(ids: Set<String>, favorite: Bool) {
        for i in allItems.indices where ids.contains(allItems[i].id) { allItems[i].isFavorite = favorite }
        recompute()
    }
}

extension CameraRollImageService {
    /// Items for explicit asset ids (user collections). Missing ids (deleted
    /// from Photos, or outside limited access) are silently skipped.
    static func loadItems(ids: [String]) async -> [CameraRollItem] {
        guard !ids.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var byID: [String: CameraRollItem] = [:]
            result.enumerateObjects { asset, _, _ in
                byID[asset.localIdentifier] = CameraRollItem(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    isVideo: asset.mediaType == .video,
                    isAnimated: asset.playbackStyle == .imageAnimated,
                    isFavorite: asset.isFavorite,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    duration: asset.duration
                )
            }
            return ids.compactMap { byID[$0] }
        }.value
    }
}

// MARK: - Share sheet

struct CameraRollShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CameraRollShareRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Grid screen

struct CameraRollGridView: View {
    let title: String
    let source: CameraRollGridSource

    @Environment(CameraRollLibrary.self) private var library
    @Environment(CameraRollCollectionStore.self) private var collections
    @State private var model: CameraRollGridModel
    @State private var viewerStart: ViewerStart?
    @State private var showDeleteConfirm = false
    @State private var shareRequest: CameraRollShareRequest?
    @State private var errorMessage: String?
    @State private var showAddToCollection = false
    @State private var columnTier = 1

    init(title: String, source: CameraRollGridSource) {
        self.title = title
        self.source = source
        _model = State(initialValue: CameraRollGridModel(source: source))
    }

    struct ViewerStart: Identifiable {
        let id: String
    }

    private var collectionAssetIDs: [String] {
        if case .collection(let id) = source {
            return collections.collections.first { $0.id == id }?.assetIDs ?? []
        }
        return []
    }

    var body: some View {
        content
            .navigationTitle(model.isSelecting ? "\(model.selection.count) selected" : title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchText, prompt: "Search date or type")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if model.isSelecting { selectionBar } }
            .task {
                model.bind(settings: library.settings)
                model.reload(collectionAssetIDs: collectionAssetIDs)
            }
            .onChange(of: library.changeToken) { _, _ in model.reload(collectionAssetIDs: collectionAssetIDs) }
            .onChange(of: library.settings.includeVideos) { _, _ in model.reload(collectionAssetIDs: collectionAssetIDs) }
            .onChange(of: library.settings.newestFirst) { _, _ in model.reload(collectionAssetIDs: collectionAssetIDs) }
            .onChange(of: library.settings.grouping) { _, _ in model.recompute() }
            .onChange(of: model.searchText) { _, _ in model.recompute() }
            .onChange(of: model.filter) { _, _ in model.recompute() }
            .onChange(of: collectionAssetIDs) { _, _ in model.reload(collectionAssetIDs: collectionAssetIDs) }
            .fullScreenCover(item: $viewerStart) { start in
                CameraRollViewer(
                    items: model.visibleItems,
                    startID: start.id,
                    albumTitle: title,
                    onDeleted: { ids in
                        model.removeLocally(ids: ids)
                        collections.forget(assetIDs: Array(ids))
                    },
                    onFavoriteChanged: { ids, fav in model.updateFavorite(ids: ids, favorite: fav) }
                )
            }
            .sheet(item: $shareRequest) { request in CameraRollShareSheet(urls: request.urls) }
            .sheet(isPresented: $showAddToCollection) {
                CameraRollAddToCollectionSheet(assetIDs: Array(model.selection.ids)) {
                    showAddToCollection = false
                    model.setSelecting(false)
                }
            }
            .confirmationDialog(
                "Delete \(model.selection.count) item\(model.selection.count == 1 ? "" : "s")?",
                isPresented: $showDeleteConfirm, titleVisibility: .visible
            ) {
                Button("Delete from Photos", role: .destructive) { Task { await deleteSelected() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Items move to Recently Deleted in Photos. iOS will ask you to confirm.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.allItems.isEmpty {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty || model.filter != .all {
            ContentUnavailableView.search
        } else if case .collection = source {
            ContentUnavailableView(
                "No photos yet", systemImage: "rectangle.stack",
                description: Text("Select photos in the Photos tab and choose Add to Collection.")
            )
        } else {
            ContentUnavailableView(
                "No photos or videos", systemImage: "photo.on.rectangle",
                description: Text(library.access == .limited
                    ? "You've shared a limited selection with this app. Use Manage in the Photos tab to choose more."
                    : "This album is empty.")
            )
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let layout = GridLayoutConfig(sizeTier: columnTier, isLandscape: proxy.size.width > proxy.size.height)
            let side = layout.cellSize(for: proxy.size.width)
            ScrollView {
                LazyVGrid(columns: layout.columns(for: proxy.size.width), spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                CameraRollThumbnailView(
                                    item: item, side: side,
                                    isSelected: model.selection.contains(item.id),
                                    selectionMode: model.isSelecting
                                )
                                .onTapGesture { tapped(item) }
                                .contextMenu { contextActions(for: item) }
                            }
                        } header: {
                            HStack {
                                Text(section.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(section.items.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.bar)
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func tapped(_ item: CameraRollItem) {
        if model.isSelecting {
            model.selection.toggle(item.id)
        } else {
            viewerStart = ViewerStart(id: item.id)
        }
    }

    @ViewBuilder
    private func contextActions(for item: CameraRollItem) -> some View {
        Button("Select", systemImage: "checkmark.circle") {
            model.setSelecting(true)
            model.selection.toggle(item.id)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if model.isSelecting {
                Button("Done") { model.setSelecting(false) }
            } else {
                Menu {
                    Picker("Show", selection: $model.filter) {
                        ForEach(CameraRollMediaFilter.allCases) { f in
                            Label(f.title, systemImage: f.systemImage).tag(f)
                        }
                    }
                    Divider()
                    Picker("Sort", selection: Bindable(library.settings).newestFirst) {
                        Text("Newest first").tag(true)
                        Text("Oldest first").tag(false)
                    }
                    Picker("Group", selection: Bindable(library.settings).grouping) {
                        ForEach(CameraRollGrouping.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Button("Thumbnail size", systemImage: "square.grid.3x3") {
                        columnTier = (columnTier + 1) % GridLayoutConfig.tierCount
                    }
                    Button("Select", systemImage: "checkmark.circle") { model.setSelecting(true) }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Sort and filter")
            }
        }
    }

    private var selectionBar: some View {
        HStack {
            Button(model.selection.count == model.visibleItems.count ? "Select none" : "Select all") {
                if model.selection.count == model.visibleItems.count { model.selection.clear() }
                else { model.selection.selectAll(model.visibleItems) }
            }
            Spacer()
            Button { Task { await shareSelected() } } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
            Button { showAddToCollection = true } label: { Image(systemName: "rectangle.stack.badge.plus") }
                .accessibilityLabel("Add to collection")
            Button { Task { await favoriteSelected() } } label: { Image(systemName: "heart") }
                .accessibilityLabel("Favorite")
            if case .collection(let id) = source {
                Button { collections.remove(assetIDs: Array(model.selection.ids), from: id); model.setSelecting(false) } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel("Remove from collection")
            }
            Button(role: .destructive) { showDeleteConfirm = true } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete")
        }
        .disabled(model.selection.isEmpty)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func shareSelected() async {
        var urls: [URL] = []
        for item in model.selection.resolve(in: model.visibleItems) {
            if let url = try? await CameraRollImageService.shared.exportForSharing(id: item.id) { urls.append(url) }
        }
        if urls.isEmpty { errorMessage = "Those items couldn't be prepared for sharing." }
        else { shareRequest = CameraRollShareRequest(urls: urls) }
    }

    private func favoriteSelected() async {
        let ids = Array(model.selection.ids)
        do {
            try await CameraRollImageService.shared.setFavorite(ids: ids, favorite: true)
            model.updateFavorite(ids: Set(ids), favorite: true)
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteSelected() async {
        let ids = Array(model.selection.ids)
        do {
            if try await CameraRollImageService.shared.delete(ids: ids) {
                model.removeLocally(ids: Set(ids))
                collections.forget(assetIDs: ids)
                model.setSelecting(false)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Add to collection

struct CameraRollAddToCollectionSheet: View {
    let assetIDs: [String]
    let onFinish: () -> Void
    @Environment(CameraRollCollectionStore.self) private var store
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("New collection") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Create") {
                            if let c = store.create(name: newName) {
                                store.add(assetIDs: assetIDs, to: c.id)
                                onFinish()
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !store.collections.isEmpty {
                    Section("Existing") {
                        ForEach(store.collections) { c in
                            Button(c.name) {
                                store.add(assetIDs: assetIDs, to: c.id)
                                onFinish()
                            }
                        }
                    }
                }
                Section {
                    Text("Collections are groupings inside this app. They don't create albums in the Photos app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add to collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) } }
        }
        .presentationDetents([.medium, .large])
    }
}

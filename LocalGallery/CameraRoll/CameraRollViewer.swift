import AVKit
import SwiftUI

// MARK: - Animated image (GIF) host

struct CameraRollAnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = image
        view.startAnimating()
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image {
            view.image = image
            view.startAnimating()
        }
    }
}

// MARK: - Viewer

/// Full-screen viewer. Pages are lazy (`LazyHStack`), so a library of tens of
/// thousands of items does not instantiate tens of thousands of views, and a
/// page that scrolls off-screen cancels its image request.
struct CameraRollViewer: View {
    let items: [CameraRollItem]
    let startID: String
    let albumTitle: String
    var onDeleted: (Set<String>) -> Void = { _ in }
    var onFavoriteChanged: (Set<String>, Bool) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var liveItems: [CameraRollItem]
    @State private var currentID: String?
    @State private var chromeVisible = true
    @State private var isZoomed = false
    @State private var infoItem: CameraRollItem?
    @State private var shareRequest: CameraRollShareRequest?
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    init(
        items: [CameraRollItem],
        startID: String,
        albumTitle: String,
        onDeleted: @escaping (Set<String>) -> Void = { _ in },
        onFavoriteChanged: @escaping (Set<String>, Bool) -> Void = { _, _ in }
    ) {
        self.items = items
        self.startID = startID
        self.albumTitle = albumTitle
        self.onDeleted = onDeleted
        self.onFavoriteChanged = onFavoriteChanged
        _liveItems = State(initialValue: items)
        _currentID = State(initialValue: startID)
    }

    private var current: CameraRollItem? {
        liveItems.first { $0.id == currentID }
    }

    private var currentIndex: Int? {
        liveItems.firstIndex { $0.id == currentID }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
        }
        .overlay(alignment: .top) { if chromeVisible { topBar } }
        .overlay(alignment: .bottom) { if chromeVisible { bottomBar } }
        .statusBarHidden(!chromeVisible)
        .sheet(item: $infoItem) { item in CameraRollInfoSheet(item: item) }
        .sheet(item: $shareRequest) { request in CameraRollShareSheet(urls: request.urls) }
        .confirmationDialog("Delete this item?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete from Photos", role: .destructive) { Task { await deleteCurrent() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to Recently Deleted in Photos. iOS will ask you to confirm.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(liveItems) { item in
                    CameraRollPageView(
                        item: item,
                        isCurrent: item.id == currentID,
                        onTap: { withAnimation(.easeInOut(duration: 0.15)) { chromeVisible.toggle() } },
                        onZoomChange: { zoomed in if item.id == currentID { isZoomed = zoomed } }
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollDisabled(isZoomed)
        .scrollIndicators(.hidden)
        .onChange(of: currentID) { _, _ in isZoomed = false }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold))
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 1) {
                Text(current?.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? albumTitle)
                    .font(.subheadline.weight(.semibold))
                if let i = currentIndex {
                    Text("\(i + 1) of \(liveItems.count) · \(albumTitle)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            Button { if let c = current { infoItem = c } } label: { Image(systemName: "info.circle").font(.title3) }
                .accessibilityLabel("Info")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        HStack {
            Button { Task { await shareCurrent() } } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
            Spacer()
            Button { Task { await toggleFavorite() } } label: {
                Image(systemName: current?.isFavorite == true ? "heart.fill" : "heart")
            }
            .accessibilityLabel(current?.isFavorite == true ? "Remove favorite" : "Favorite")
            Spacer()
            Button(role: .destructive) { showDeleteConfirm = true } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete")
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Actions

    private func shareCurrent() async {
        guard let id = currentID else { return }
        do {
            let url = try await CameraRollImageService.shared.exportForSharing(id: id)
            shareRequest = CameraRollShareRequest(urls: [url])
        } catch {
            errorMessage = "This item couldn't be prepared for sharing. It may be unavailable or still in iCloud."
        }
    }

    private func toggleFavorite() async {
        guard let item = current else { return }
        let newValue = !item.isFavorite
        do {
            try await CameraRollImageService.shared.setFavorite(ids: [item.id], favorite: newValue)
            if let i = liveItems.firstIndex(where: { $0.id == item.id }) { liveItems[i].isFavorite = newValue }
            onFavoriteChanged([item.id], newValue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCurrent() async {
        guard let item = current, let index = currentIndex else { return }
        do {
            guard try await CameraRollImageService.shared.delete(ids: [item.id]) else { return }  // user cancelled
            onDeleted([item.id])
            liveItems.remove(at: index)
            if liveItems.isEmpty {
                dismiss()
            } else {
                currentID = liveItems[min(index, liveItems.count - 1)].id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - One page

struct CameraRollPageView: View {
    let item: CameraRollItem
    let isCurrent: Bool
    let onTap: () -> Void
    let onZoomChange: (Bool) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var animated: UIImage?
    @State private var player: AVPlayer?
    @State private var unavailable = false

    var body: some View {
        ZStack {
            if item.isVideo {
                videoBody
            } else if let animated {
                CameraRollAnimatedImageView(image: animated)
                    .onTapGesture(perform: onTap)
            } else if let image {
                ZoomableImageView(image: image, onSingleTap: onTap, onZoomChange: onZoomChange)
            } else if unavailable {
                ContentUnavailableView(
                    "Unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("This item was deleted, is outside your limited selection, or couldn't be loaded.")
                )
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.id) { await load() }
        .onChange(of: isCurrent) { _, nowCurrent in
            if !nowCurrent { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var videoBody: some View {
        if let player {
            VideoPlayer(player: player)
        } else if unavailable {
            ContentUnavailableView(
                "Video unavailable", systemImage: "video.slash",
                description: Text("It may be deleted or still downloading from iCloud.")
            ).foregroundStyle(.white)
        } else {
            ProgressView().tint(.white)
        }
    }

    private func load() async {
        unavailable = false
        let service = CameraRollImageService.shared
        let screenPixels = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * displayScale

        if item.isVideo {
            if let box = await service.playerItem(id: item.id), !Task.isCancelled {
                player = AVPlayer(playerItem: box.value)
            } else if !Task.isCancelled {
                unavailable = true
            }
            return
        }

        // Quick low-res first so the page is never blank, then the screen-sized image.
        if image == nil {
            image = await service.thumbnail(id: item.id, pixelSize: CGSize(width: 400, height: 400)).value
        }
        if item.isAnimated {
            if let gif = await service.animatedImage(id: item.id, maxPixel: min(screenPixels, 1080)).value, !Task.isCancelled {
                animated = gif
                return
            }
        }
        // Capped at 2x the screen's long edge — never the full original.
        let full = await service.displayImage(id: item.id, maxPixel: min(screenPixels * 1.5, 4096)).value
        guard !Task.isCancelled else { return }
        if let full { image = full } else if image == nil { unavailable = true }
    }
}

// MARK: - Info sheet

struct CameraRollInfoSheet: View {
    let item: CameraRollItem
    @Environment(\.dismiss) private var dismiss
    @State private var info: CameraRollAssetInfo?

    var body: some View {
        NavigationStack {
            List {
                if let info {
                    row("File name", info.filename ?? "Unavailable")
                    row("Type", info.isVideo ? "Video" : (item.isAnimated ? "Animated GIF" : "Photo"))
                    if let d = info.creationDate { row("Date", d.formatted(date: .long, time: .standard)) }
                    row("Dimensions", "\(info.pixelWidth) × \(info.pixelHeight)")
                    if info.isVideo { row("Duration", CameraRollThumbnailView.durationText(info.duration)) }
                    row("Favorite", info.isFavorite ? "Yes" : "No")
                    if let lat = info.latitude, let lon = info.longitude {
                        row("Location", String(format: "%.4f, %.4f", lat, lon))
                    }
                    Section {
                        Text("File size isn't shown: Photos doesn't expose it through a public API.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Unavailable", systemImage: "info.circle")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { info = CameraRollImageService.shared.info(id: item.id) }
        }
        .presentationDetents([.medium])
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing) }
    }
}

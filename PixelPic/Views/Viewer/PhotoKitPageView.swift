import SwiftUI
import UIKit
import AVFoundation
import Photos

/// One page of the photo-library viewer: a still, a zoomable photo, or
/// a video with a transport.
///
/// The counterpart of `PhotoPageView`, and separate for the same
/// reason: a `PHAsset` is fetched through `PHImageManager` and played
/// through `AVPlayerItem(asset:)`, not read from a file URL.
///
/// **Loading discipline** (rewritten after device reports of black
/// screens and video crashes, October 2026):
///
/// * Work is keyed by a *generation*: every load captures the asset
///   id and a nonce, and a completion that arrives after either moved
///   on is dropped instead of written into state. Nothing ever
///   "nils out" an image that is already on screen for the same
///   asset, so a reload can never blank a visible photo.
/// * Neighbour pages load thumbnails only. The 2000px full image is
///   requested when the page becomes the settled, current page —
///   three full-size decodes racing during a swipe was both wasted
///   memory and contention that starved the current page.
/// * A page seeds itself synchronously from the thumbnail cache —
///   whatever size the grid decoded — before its first await, and
///   concurrent full-image triggers coalesce into one request. A
///   cache keyed by exact size plus un-coalesced duplicate loads
///   reproduced the black viewer on device even with the discipline
///   above in place: the tapped photo's decode existed in memory,
///   at the grid's size, and the page could not see it.
/// * Loading is a visible state, not an absence: spinner, iCloud
///   download progress when PhotoKit reports it, the degraded
///   preview the moment it arrives, and — on genuine failure — an
///   error with a Retry, never an indefinite black screen.
/// * Video start is a structured task owned by the page, guarded by
///   the same generation: swipe away mid-load and the orphaned
///   completion is discarded instead of attaching a player to a page
///   the user has left (which played phantom audio and corrupted
///   state). Playback failures surface through
///   `VideoPlaybackState.playbackError` with Retry.
struct PhotoKitPageView: View {
    let asset: PhotoKitAsset

    @Environment(GalleryStore.self) private var store
    @Binding var isChromeVisible: Bool
    @Binding var videoTransportVisible: Bool
    /// The viewer's current asset id, shared with every page. A page
    /// is "current" only when this equals its own asset's id.
    @Binding var currentAssetID: String

    @State private var fullImage: UIImage?
    @State private var thumbnail: UIImage?
    @State private var player: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var isZoomed = false
    @State private var livePlayer: AVPlayer?
    @State private var isPlayingLive = false
    /// The transport's playback state, held here rather than inside
    /// the bar so it survives the bar being hidden and shown again.
    @State private var playbackState = VideoPlaybackState()

    /// The asset the current load state belongs to. When it differs
    /// from `asset.id`, the page has been recycled for a new asset
    /// and state resets; when it matches, a reload keeps what is on
    /// screen.
    @State private var loadedAssetID: String?
    /// Monotonic load nonce: completions from an older load are
    /// stale and dropped.
    @State private var loadNonce = 0
    /// Full-image load state for the current asset.
    @State private var loadPhase: LoadPhase = .loading
    /// iCloud download progress for the full image, when reported.
    @State private var downloadProgress: Double?
    /// Bumped by the Retry button to re-run the full-image load.
    @State private var retryNonce = 0
    /// The nonce of the full-image load currently in flight, if any.
    /// Several triggers can ask for the full image at once (the
    /// thumbnail task's tail, the current-page task, a retry); they
    /// must coalesce into ONE request, not race near-identical
    /// 2000 px decodes that supersede each other and leave the page
    /// waiting on the slowest — a device-reproduced black viewer.
    /// Monotonic nonce for the *thumbnail* load only. It is separate
    /// from `loadNonce` (the full-image load's) on purpose: the two
    /// loads run concurrently by design, and sharing one nonce let
    /// a full-load start invalidate the thumbnail's completion —
    /// discarding the very image the page was waiting to show, and
    /// chaining duplicate full loads behind it (device-reported
    /// intermittent black viewer, October 2026).
    @State private var thumbnailNonce = 0
    @State private var fullLoadNonce: Int?
    /// Why starting the video failed (load-level; playback-level
    /// failures arrive via `playbackState.playbackError`).
    @State private var videoLoadError: String?
    /// The structured task that starts video playback.
    @State private var videoTask: Task<Void, Never>?
    /// Nonce guarding the video task, like `loadNonce` for images.
    @State private var videoNonce = 0

    private enum LoadPhase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// Whether this page is the viewer's settled, current page.
    private var isCurrentPage: Bool { currentAssetID == asset.id }

    @ViewBuilder
    private var videoBody: some View {
        if isPlayingVideo, let player {
            playingVideoBody(player: player)
        } else {
            videoThumbnailBody
        }
    }

    /// The playing-video branch of `videoBody`, split out so each
    /// view builder type-checks a single, small expression.
    /// Compilation of this file stalled in CI when these branches
    /// were one large builder, so the builders here are kept
    /// deliberately small and separate.
    private func playingVideoBody(player: AVPlayer) -> some View {
        // The raw player layer, not AVKit's `VideoPlayer`:
        // `VideoPlayer` brings its own transport controls, which
        // would sit on top of the app's transport bar and give the
        // user two scrubbers fighting over the same gesture.
        AVPlayerLayerView(player: player)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    videoTransportVisible.toggle()
                }
            }
            .overlay(alignment: .bottom) {
                if videoTransportVisible {
                    VideoTransportBar(state: playbackState)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let playbackError = playbackState.playbackError {
                    videoErrorOverlay(message: playbackError)
                }
            }
    }

    /// A playback failure over the (frozen) video: say what happened
    /// and offer the two ways out — try again, or go back to the
    /// thumbnail.
    private func videoErrorOverlay(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Retry") { startVideo() }
                    .buttonStyle(.borderedProminent)
                Button("Back") { stopVideo() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }

    /// The not-yet-playing branch of `videoBody`: thumbnail (or
    /// spinner) with the play button, and — after a failed start —
    /// the reason and a retrying play button.
    private var videoThumbnailBody: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
            VStack(spacing: 10) {
                Button {
                    startVideo()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 8)
                }
                if let videoLoadError {
                    Text(videoLoadError)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    /// The page's media content — video or photo — before geometry
    /// and gestures are applied in `body`.
    @ViewBuilder
    private var mediaBody: some View {
        if asset.isVideo {
            videoBody
        } else {
            photoBody
        }
    }

    /// Live-photo long-press recognised.
    private func handleLivePhotoLongPress() {
        guard asset.isLivePhoto, !isZoomed else { return }
        Task { await startLivePlayback() }
    }

    private func handlePressingChanged(_ pressing: Bool) {
        if !pressing { stopLivePlayback() }
    }

    var body: some View {
        GeometryReader { geo in
            mediaBody
            .frame(width: geo.size.width, height: geo.size.height)
            // Live-photo press-and-hold. The `pressing` callback
            // fires *immediately* on touch start, so anything
            // heavyweight lives in `perform` — see the history on
            // this gesture: pressing(true) used to hide chrome and
            // race the chrome toggle on every quick tap.
            .onLongPressGesture(
                minimumDuration: 0.3,
                maximumDistance: 50,
                perform: handleLivePhotoLongPress,
                onPressingChanged: handlePressingChanged
            )
        }
        // Thumbnail (and video poster) for every page; the expensive
        // full image only for the settled current page.
        .task(id: asset.id) {
            await loadThumbnail()
        }
        .task(id: isCurrentPage) {
            if isCurrentPage {
                await loadFullImageIfNeeded()
            }
        }
        .task(id: retryNonce) {
            if retryNonce > 0 {
                await loadFullImageIfNeeded(force: true)
            }
        }
        // Swiping away from a playing video stops it: the page
        // controller keeps neighbour pages alive, so without this a
        // video the user has left keeps its audio.
        .onChange(of: currentAssetID) { _, newValue in
            if newValue != asset.id {
                stopVideo()
                stopLivePlayback()
            }
        }
        .onDisappear {
            videoTask?.cancel()
            stopVideo()
            stopLivePlayback()
        }
    }

    @ViewBuilder
    private var photoBody: some View {
        if let displayImage = fullImage ?? thumbnail {
            ZoomableImageView(
                image: displayImage,
                isZoomEnabled: true,
                onSingleTap: {
                    withAnimation { isChromeVisible.toggle() }
                },
                onZoomChange: { zoomed in
                    isZoomed = zoomed
                    if zoomed { stopLivePlayback() }
                }
            )
        } else if case .failed(let message) = loadPhase {
            photoErrorBody(message: message)
        } else {
            photoLoadingBody
        }

        // A preview is on screen but the full image is still
        // loading: say so, visibly. Without this the seeded or
        // degraded picture looks final-but-soft with no explanation,
        // and the wait reads as a hang.
        if fullImage == nil, thumbnail != nil, loadPhase == .loading {
            loadingProgressCapsule
        }

        livePhotoOverlay
    }

    /// The in-flight indicator shown over a seeded/degraded preview
    /// while the full image loads: spinner, plus iCloud progress
    /// when PhotoKit reports it.
    private var loadingProgressCapsule: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            if let downloadProgress, downloadProgress < 1 {
                Text("Downloading from iCloud… \(Int(downloadProgress * 100))%")
            } else {
                Text("Loading full photo…")
            }
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 96)
        .allowsHitTesting(false)
    }

    /// The explicit loading state: a spinner, and when PhotoKit is
    /// downloading from iCloud, the progress — a black screen with a
    /// spinner and no explanation is what the bug report described.
    private var photoLoadingBody: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            if let downloadProgress, downloadProgress < 1 {
                Text("Downloading from iCloud… \(Int(downloadProgress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        // Full-frame and centered: a content-sized spinner tucked
        // in a corner of a black page is indistinguishable from the
        // black screen it is supposed to be explaining.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A genuine failure: say so, and let the user retry without
    /// leaving the viewer.
    private func photoErrorBody(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 30))
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Retry") { retryNonce += 1 }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    /// Live photo motion overlay.
    @ViewBuilder
    private var livePhotoOverlay: some View {
        if isPlayingLive, let livePlayer {
            AVPlayerLayerView(player: livePlayer)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Video

    /// Start playback as a structured, page-owned task.
    ///
    /// The previous version fired an unstructured `Task` and
    /// attached whatever came back, whenever it came back: swipe
    /// away during the load and the orphan attached and played
    /// anyway — phantom audio, corrupted state, and a plausible
    /// contributor to the device-reported video crashes. Now the
    /// completion is checked against the page's nonce, its
    /// cancellation, and its current-page status before anything is
    /// attached; a stale completion is dropped whole.
    private func startVideo() {
        guard isCurrentPage else { return }
        videoLoadError = nil
        videoTask?.cancel()
        videoNonce += 1
        let nonce = videoNonce
        let assetID = asset.id
        videoTask = Task {
            let result = await store.photoKit.playerItemResult(for: assetID)
            guard !Task.isCancelled,
                  videoNonce == nonce,
                  currentAssetID == assetID else { return }
            guard let item = result.item else {
                Log.photokit.error("Video: load failed")
                videoLoadError = result.failureMessage
                    ?? "This video could not be loaded."
                return
            }
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            isPlayingVideo = true
            videoTransportVisible = true
            // Attach before playing so the transport's first frame
            // already knows the duration, and so the item's status
            // (including failure) is observed from the start.
            playbackState.attach(to: newPlayer)
            Log.photokit.info("Video: player attached")
            playbackState.play()
            Log.photokit.info("Video: playback started")
            isChromeVisible = false
        }
    }

    /// Stop playback and tear the player down: pause, detach every
    /// observer, drop the layer's player.
    private func stopVideo() {
        videoTask?.cancel()
        videoTask = nil
        player?.pause()
        player = nil
        if isPlayingVideo {
            isPlayingVideo = false
        }
        playbackState.detach()
        videoTransportVisible = false
    }

    // MARK: - Loading

    /// Load the cheap thumbnail for this page's asset.
    ///
    /// Runs for neighbour pages too — a thumbnail is what makes a
    /// swipe land on a picture instead of a spinner. Existing images
    /// for the *same* asset are kept (a reload must never blank the
    /// screen); state resets only when the page's asset changed.
    private func loadThumbnail() async {
        if loadedAssetID != asset.id {
            loadedAssetID = asset.id
            fullImage = nil
            thumbnail = nil
            loadPhase = .loading
            downloadProgress = nil
            videoLoadError = nil
            isZoomed = false
            fullLoadNonce = nil
            stopVideo()
            stopLivePlayback()
        }
        // Seed BEFORE the first await: whatever the grid already
        // decoded for this asset — the very image the user tapped —
        // goes on screen in the same frame. The cache is keyed by
        // size and the grid's cell size is not this page's 600 pt,
        // so an exact-size lookup would miss by construction and
        // the page would sit black through a cold ~1800 px decode;
        // that miss was the device-reported black viewer.
        if thumbnail == nil, let seed = store.photoKit.cachedThumbnail(for: asset.id) {
            thumbnail = seed
        }
        thumbnailNonce += 1
        let nonce = thumbnailNonce
        let assetID = asset.id
        let image = await store.photoKit.thumbnail(
            for: assetID,
            size: 600,
            onDegraded: { degraded in
                // A degraded preview beats an empty page while the
                // full decode is still running.
                guard thumbnailNonce == nonce, loadedAssetID == assetID else { return }
                if thumbnail == nil {
                    thumbnail = degraded
                }
            }
        )
        guard thumbnailNonce == nonce, loadedAssetID == assetID else { return }
        if let image, thumbnail == nil {
            thumbnail = image
        }
        // The current page may already be waiting on its full image;
        // a neighbour's thumbnail task does not own that load.
        if isCurrentPage, !asset.isVideo {
            await loadFullImageIfNeeded()
        }
    }

    /// Load the full-size image — current page only.
    ///
    /// The degraded preview is published into `thumbnail` the moment
    /// it arrives, and progress into `downloadProgress`, so the wait
    /// is visible and explained. A `nil` result is a *failure state*,
    /// not a spinner forever — unless a degraded preview made it to
    /// the screen, in which case the photo is shown and the phase is
    /// ready (a small picture beats an error about a big one).
    private func loadFullImageIfNeeded(force: Bool = false) async {
        guard !asset.isVideo, isCurrentPage else { return }
        if fullImage != nil, !force { return }
        // Coalesce concurrent triggers (thumbnail tail, current-page
        // task, retry task): one in-flight load per page. Without
        // this, two triggers each start a 2000 px decode and the
        // nonce drops the first one's result — the page waits on
        // duplicated work while showing nothing new.
        if fullLoadNonce != nil, !force { return }
        if loadedAssetID != asset.id {
            await loadThumbnail()
        }
        loadNonce += 1
        let nonce = loadNonce
        fullLoadNonce = nonce
        let assetID = asset.id
        loadPhase = .loading
        let image = await store.photoKit.fullImage(
            for: assetID,
            onProgress: { progress in
                guard loadNonce == nonce else { return }
                downloadProgress = progress
            },
            onDegraded: { degraded in
                guard loadNonce == nonce, loadedAssetID == assetID else { return }
                if thumbnail == nil {
                    thumbnail = degraded
                }
            }
        )
        if fullLoadNonce == nonce {
            fullLoadNonce = nil
        }
        guard loadNonce == nonce, loadedAssetID == assetID else { return }
        downloadProgress = nil
        if let image {
            fullImage = image
            loadPhase = .ready
        } else if thumbnail != nil {
            loadPhase = .ready
        } else {
            loadPhase = .failed("This photo couldn't be loaded. It may still be downloading from iCloud — check your connection and try again.")
        }
    }

    // MARK: - Live photo

    private func startLivePlayback() async {
        let assetID = asset.id
        guard let url = await store.photoKit.livePhotoVideoFile(for: assetID) else { return }
        // The press-and-hold may have ended, or the user may have
        // swiped on, while the file was being written out.
        guard currentAssetID == assetID, isCurrentPage else { return }
        let newPlayer = AVPlayer(url: url)
        livePlayer = newPlayer
        newPlayer.play()
        withAnimation(.easeIn(duration: 0.15)) { isPlayingLive = true }
        isChromeVisible = false
    }

    private func stopLivePlayback() {
        guard isPlayingLive || livePlayer != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { isPlayingLive = false }
        livePlayer?.pause()
        livePlayer = nil
    }
}

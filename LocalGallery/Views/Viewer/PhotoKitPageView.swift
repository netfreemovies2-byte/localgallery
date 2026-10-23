import SwiftUI
import UIKit
import AVFoundation
import Photos

/// One page of the photo-library viewer: a still, a zoomable photo, or a
/// video with a transport.
///
/// The counterpart of `PhotoPageView`, and separate for the same reason:
/// a `PHAsset` is fetched through `PHImageManager` and played through
/// `AVPlayerItem(asset:)`, not read from a file URL.
struct PhotoKitPageView: View {
    let asset: PhotoKitAsset

    @Environment(GalleryStore.self) private var store
    @Binding var isChromeVisible: Bool
    @Binding var videoTransportVisible: Bool

    @State private var fullImage: UIImage?
    @State private var thumbnail: UIImage?
    @State private var player: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var isZoomed = false
    @State private var livePlayer: AVPlayer?
    @State private var isPlayingLive = false
    /// The transport's playback state, held here rather than inside the
    /// bar so it survives the bar being hidden and shown again.
    @State private var playbackState = VideoPlaybackState()

    @ViewBuilder
    private var videoBody: some View {
        if isPlayingVideo, let player {
            playingVideoBody(player: player)
        } else {
            videoThumbnailBody
        }
    }

    /// The playing-video branch of `videoBody`, split out so each view
    /// builder type-checks a single, small expression. Compilation of this
    /// file stalled in CI when these branches were one large builder
    /// (runs 39876929274 and 39897984214 both stop at this file), so the
    /// builders here are kept deliberately small and separate.
    private func playingVideoBody(player: AVPlayer) -> some View {
        // The raw player layer, not AVKit's `VideoPlayer`: `VideoPlayer`
        // brings its own transport controls, which would sit on top of
        // the app's transport bar and give the user two scrubbers
        // fighting over the same gesture.
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
    }

    /// The not-yet-playing branch of `videoBody`: thumbnail (or spinner)
    /// with the play button.
    private var videoThumbnailBody: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
            Button {
                startVideo()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 8)
            }
        }
    }

    /// The page's media content — video or photo — before geometry and
    /// gestures are applied in `body`.
    @ViewBuilder
    private var mediaBody: some View {
        if asset.isVideo {
            videoBody
        } else {
            photoBody
        }
    }

    /// Live-photo long-press recognised. See the gesture comment in
    /// `body` for why playback starts here and never in the pressing
    /// callback.
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
            // Live-photo press-and-hold. The `pressing` callback fires
            // *immediately* on touch start (before `minimumDuration`), so
            // anything heavyweight (start playback, hide chrome) MUST live
            // in `perform` — the recognised long-press — or every quick tap
            // on a live photo races the chrome toggle: pressing(true) hides
            // chrome, then ZoomableImageView's delayed singleTap toggles it
            // back. `pressing(false)` only stops playback, never starts it.
            .onLongPressGesture(
                minimumDuration: 0.3,
                maximumDistance: 50,
                perform: handleLivePhotoLongPress,
                onPressingChanged: handlePressingChanged
            )
        }
        .task(id: asset.id) {
            await load()
        }
        .onDisappear {
            // The page controller retains neighbour pages, so without this
            // a playing video keeps its audio going after the user swipes
            // to the next asset.
            player?.pause()
            isPlayingVideo = false
            playbackState.detach()
            videoTransportVisible = false
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
        } else {
            ProgressView().tint(.white)
        }

        livePhotoOverlay
    }

    /// Live photo motion overlay. The still underneath is dimmed while
    /// the motion plays — the system Photos app does the same, and
    /// without it the two images fight for the eye and the motion
    /// looks like a glitch rather than a live photo.
    @ViewBuilder
    private var livePhotoOverlay: some View {
        if isPlayingLive, let livePlayer {
            AVPlayerLayerView(player: livePlayer)
                .allowsHitTesting(false)
        }
    }

    private func startVideo() {
        Task {
            guard let item = await store.photoKit.playerItem(for: asset.id) else { return }
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            isPlayingVideo = true
            videoTransportVisible = true
            // Attach before playing so the transport's first frame already
            // knows the duration.
            playbackState.attach(to: newPlayer)
            playbackState.play()
            isChromeVisible = false
        }
    }

    // MARK: - Loading

    private func load() async {
        fullImage = nil
        thumbnail = nil
        isPlayingVideo = false
        player?.pause()
        player = nil
        isPlayingLive = false
        livePlayer?.pause()
        livePlayer = nil
        isZoomed = false
        playbackState.detach()
        videoTransportVisible = false

        // A cheap thumbnail first, so the page has something to show
        // while the full-resolution request is in flight.
        thumbnail = await store.photoKit.thumbnail(for: asset.id, size: 600)
        if !asset.isVideo {
            fullImage = await store.photoKit.fullImage(for: asset.id)
        }
    }

    // MARK: - Live photo

    private func startLivePlayback() async {
        guard let url = await store.photoKit.livePhotoVideoFile(for: asset.id) else { return }
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
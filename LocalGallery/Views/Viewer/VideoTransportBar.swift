import SwiftUI
import AVFoundation

/// Play / pause + a scrubber for the video playing behind it.
///
/// AVKit's `VideoPlayer` brings its own transport controls, which would sit
/// on top of this bar and give the user two scrubbers fighting over the
/// same gesture — so the page renders a bare `AVPlayerLayer` and the
/// transport is ours. The viewer's own chrome is hidden during playback,
/// so the transport has to be able to bring the user back out of the way
/// (tap the video) and to pause, and it has to survive that toggle.
///
/// The player's state is read through `VideoPlaybackState`, an
/// `@Observable` box: `AVPlayer` posts its change notifications on a
/// private queue, and the view is main-actor bound, so the hop has to
/// happen somewhere. A 0.5s timer would keep the main actor awake for the
/// whole playback of every video; the notifications do not.
@MainActor
@Observable
final class VideoPlaybackState {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    /// Sound on by default: playback only ever starts from an explicit tap
    /// on the play button, so the user has already signalled intent to watch
    /// (and iOS Photos behaves the same). The control is right there to mute.
    var isMuted = false

    /// The player this state observes. Set when the page starts playback; the
    /// periodic time observer is torn down and re-armed whenever the page
    /// loads a different photo, because the gallery swaps the item under the
    /// player.
    ///
    /// `@ObservationIgnored`: nothing in the UI reads it, and observing a
    /// non-`Sendable` AVPlayer would make every mutation a view invalidation
    /// for no reason.
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func attach(to player: AVPlayer) {
        detach()
        self.player = player
        player.isMuted = isMuted

        duration = Self.seconds(of: player.currentItem?.duration)
        isPlaying = player.timeControlStatus == .playing

        // Periodic observation — the only way to drive a scrubber. The
        // interval is coarse enough to be free and fine enough to look
        // like playback. The callback is `@Sendable` and runs on the
        // main queue, so the hop onto the main actor is explicit.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = Self.seconds(of: time)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                let total = Self.seconds(of: self.player?.currentItem?.duration)
                if total > 0 { self.duration = total }
                self.isPlaying = self.player?.timeControlStatus == .playing
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            // Stop on the last frame rather than looping. A gallery video
            // that silently restarts looks like it is stuck — the user
            // asked for a clip, not a screensaver. The scrubber is left at
            // the end, so the play button restarts it from the top.
            Task { @MainActor [weak self] in
                guard let player = self?.player else { return }
                player.pause()
                self?.isPlaying = false
            }
        }
    }

    func detach() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player = nil
        // Reset the readout too. The state outlives the page (it is owned by
        // the page's `@State`, which survives the photo changing), so
        // without this the next video's scrubber opens showing the *previous*
        // clip's position and duration for up to a quarter of a second —
        // until the periodic observer's first tick corrects it.
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            // Restart from the top if the clip already ran to its end —
            // otherwise "play" would resume at the final frame and appear
            // to do nothing.
            let duration = Self.seconds(of: player.currentItem?.duration)
            if duration > 0, currentTime >= duration - 0.25 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    /// Start playback. Separate from `togglePlayback` so the *initial*
    /// play — the one the big play button on the page triggers — goes
    /// through the state and the transport's button is correct on its very
    /// first frame instead of waiting for the periodic observer's first
    /// tick to say "playing".
    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        // The readout is updated here as well as by the periodic observer:
        // on release the slider stops reading `scrubTime` and falls back to
        // `currentTime`, and the observer's next tick is up to a quarter of
        // a second away — long enough for the scrubber to visibly snap
        // back to where it was before the drag.
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    /// `CMTime.seconds` is `NaN` for an indefinite duration (a live
    /// stream, or an item that has not loaded yet) and `infinity` for an
    /// unknown one. Both would poison the scrubber's range.
    ///
    /// `nonisolated` because the periodic time observer's callback is a
    /// `@Sendable` closure that runs off the actor; it needs to read the
    /// duration before hopping onto the main actor.
    nonisolated private static func seconds(of time: CMTime?) -> Double {
        guard let time else { return 0 }
        let value = time.seconds
        guard value.isFinite, value >= 0 else { return 0 }
        return value
    }
}

/// The transport itself.
struct VideoTransportBar: View {
    /// The shared playback state. Owned by the page, not the bar, so it
    /// survives the bar being hidden (the user tapped the video) and shown
    /// again — a transport that reset its scrubber on every toggle would
    /// be unusable.
    ///
    /// The bar holds no `AVPlayer` of its own: the state owns the player
    /// it was attached to, and the bar only reads and commands it through
    /// the state. Two references to one player is one too many — they can
    /// disagree about which item is loaded.
    @Bindable var state: VideoPlaybackState

    /// Whether the user is dragging the scrubber. While scrubbing, the
    /// slider shows the dragged position, not the player's.
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    /// Where the drag started. The first `scrubTime` change after a drag
    /// begins is the seed from the player's own position, not a user
    /// choice — seeking to it would be a no-op seek that can hitch the
    /// player on touch-down.
    @State private var scrubOrigin: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : state.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(state.duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        // Seed the mirror from the *player's* position, not
                        // from the last mirrored value: the slider reads
                        // `scrubTime` while scrubbing, so a stale seed would
                        // yank the scrubber back to wherever the user last
                        // let go (or to zero) the moment they touched it.
                        scrubTime = state.currentTime
                        scrubOrigin = state.currentTime
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        state.seek(to: scrubTime)
                    }
                }
            )
            .tint(Design.accentColor)
            // Scrubbing previews the frame under the thumb while the finger
            // is down. Without it the video keeps playing the old position
            // until the drag ends, so the user is dragging a scrubber that
            // is not connected to what they are looking at — the picture
            // and the thumb disagree for the whole gesture.
            .onChange(of: scrubTime) { _, newValue in
                guard isScrubbing else { return }
                // The first change after touch-down is the seed itself;
                // seeking to where the player already is would be a no-op
                // seek, and on some files that stalls the decoder.
                guard newValue != scrubOrigin else { return }
                state.seek(to: newValue)
            }

            HStack(spacing: 16) {
                Button {
                    state.togglePlayback()
                } label: {
                    Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

                Text(timeLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()

                Spacer()

                // The mute control is always visible, so sound is the
                // user's to turn off rather than a hidden setting.
                Button {
                    state.toggleMute()
                } label: {
                    Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        // The state is attached by the page (before playback starts, so the
        // transport's first frame already knows the duration) and detached
        // by the page on teardown — not here, because hiding this bar must
        // not stop the observer.
    }

    private var timeLabel: String {
        let total = state.duration
        let current = isScrubbing ? scrubTime : state.currentTime
        return "\(VideoTimeFormat.string(current)) / \(VideoTimeFormat.string(total))"
    }
}

/// The transport's time labels.
///
/// A plain type rather than a static on the `View`: the formatting is a
/// pure function, and keeping it out of the view means a test can call it
/// without an actor hop.
enum VideoTimeFormat {
    /// "1:01" for a short clip, "1:01:01" for a long one.
    ///
    /// `CMTime.seconds` is `NaN` for an indefinite duration (a live
    /// stream, or an item that has not loaded yet) and `infinity` for an
    /// unknown one. Neither may reach the label, so both are rejected
    /// here rather than at the call site.
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// Zero-padded to two digits.
    ///
    /// Hand-rolled rather than `String(format: "%02d", …)`: `%d` is a
    /// 32-bit conversion and `Int` is 64-bit, so the varargs width and the
    /// argument width disagree. It happens to read the right bytes for
    /// values below 2^31, but a time format is not the place to rely on
    /// that.
    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

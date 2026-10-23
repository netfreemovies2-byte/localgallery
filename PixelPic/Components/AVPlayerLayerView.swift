import SwiftUI
import AVKit

// MARK: - Lightweight AVPlayerLayer wrapper for live photo overlay

class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    /// Release the player when the view leaves the hierarchy. The
    /// page controller retains pages (and their layers); without
    /// this, a dismantled page's layer keeps its `AVPlayer` — and
    /// its decoder and buffers — alive for as long as the controller
    /// caches the page.
    func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}

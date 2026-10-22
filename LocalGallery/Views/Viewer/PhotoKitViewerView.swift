import SwiftUI
import UIKit
import AVFoundation
import Photos

/// The full-screen viewer for the device's own photo library.
///
/// A sibling of `PhotoViewerView` rather than a variant: the folder
/// viewer works on `PhotoFile`s, which have a file URL on disk that
/// `AVPlayer` and `ImageIO` can open directly. A `PHAsset` has neither —
/// its pixels come from `PHImageManager` and its video from
/// `AVPlayerItem(asset:)` — so the two viewers share a look but not a
/// pipeline.
///
/// What it does carry over: pinch-to-zoom, swipe navigation, swipe-to-
/// dismiss, a video transport with play/pause, scrubbing and mute, and a
/// share action that exports the original bytes.
struct PhotoKitViewerView: View {
    /// The assets being browsed, in timeline order.
    let assets: [PhotoKitAsset]
    /// The asset the viewer opens on.
    let currentAssetID: String
    /// How many assets the *library* holds, for the "N of M" readout.
    ///
    /// The browsed set is often a page of a much larger library — the
    /// timeline pages in 600 at a time — so "N of 600" would be a lie.
    /// The library's own count is exact and is what the system Photos app
    /// shows.
    var totalCount: Int? = nil
    /// Called when the user deletes assets. The service reloads the
    /// library afterwards.
    let onDelete: ([String]) async -> Void

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String = ""
    @State private var isChromeVisible = true
    @State private var videoTransportVisible = true
    @State private var dismissOffset: CGFloat = 0
    @State private var showDeleteConfirm = false
    @State private var shareItem: ShareItem?
    @State private var isExporting = false
    @State private var windowInsets: EdgeInsets = .init()

    private var currentIndex: Int? {
        assets.firstIndex { $0.id == currentID }
    }

    private var currentAsset: PhotoKitAsset? {
        guard let idx = currentIndex else { return nil }
        return assets[idx]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                    .opacity(dismissOffset > 0 ? max(0.3, 1.0 - Double(dismissOffset) / 300.0) : 1.0)
                    .ignoresSafeArea()

                if assets.isEmpty {
                    Color.clear
                } else {
                    PhotoKitPagingView(
                        assets: assets,
                        store: store,
                        currentAssetID: $currentID,
                        isChromeVisible: $isChromeVisible,
                        videoTransportVisible: $videoTransportVisible
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                if isChromeVisible {
                    VStack {
                        topBar
                        Spacer()
                    }
                    .padding(.top, windowInsets.top)
                    .transition(.opacity)
                    .offset(y: dismissOffset)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
            .statusBarHidden(!isChromeVisible)
            // The chrome is layered above a full-bleed canvas, and the
            // GeometryReader reports zero insets inside a `fullScreenCover`
            // on iOS 18 — so the real insets come from the window. A
            // rotation changes them, and `onAppear` alone would leave the
            // buttons under the status bar until the viewer was reopened.
            .onChange(of: geo.size) { _, _ in
                windowInsets = Self.currentWindowInsets()
            }
            .background(
                SwipeToDismissGestureInstaller(
                    offset: $dismissOffset,
                    isInfoOpen: .constant(false),
                    // The whole canvas is the photo area — there is no info
                    // drawer here — so the dismiss gesture may begin
                    // anywhere on it except the transport's strip.
                    photoHeight: geo.size.height,
                    bottomExclusionHeight: videoTransportExclusionHeight,
                    onDismiss: { dismiss() },
                    onOpenInfo: {},
                    onCloseInfo: {}
                )
                .frame(width: 0, height: 0)
            )
        }
        .ignoresSafeArea()
        .onAppear {
            windowInsets = Self.currentWindowInsets()
            currentID = assets.contains { $0.id == currentAssetID } ? currentAssetID : (assets.first?.id ?? "")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(deletePromptTitle, isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await onDelete([currentID])
                    dismiss()
                }
            }
        } message: {
            Text("This removes it from your device’s photo library. It cannot be undone.")
        }
    }

    /// "Delete this video?" for a video, "Delete this photo?" for a still.
    private var deletePromptTitle: String {
        currentAsset?.isVideo == true ? "Delete this video?" : "Delete this photo?"
    }

    private var videoTransportExclusionHeight: CGFloat? {
        guard currentAsset?.isVideo == true, videoTransportVisible else { return nil }
        return 120
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel("Close")

            Spacer()

            if let idx = currentIndex, !assets.isEmpty {
                Text(PhotoKitLibraryRules.positionLabel(
                    index: idx,
                    total: totalCount,
                    browsed: assets.count
                ))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.35), in: Capsule())
            }

            Spacer()

            Button {
                Task { await exportCurrent() }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .disabled(isExporting)
            .accessibilityLabel("Share")

            if currentAsset != nil {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .accessibilityLabel("Delete")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Export

    private func exportCurrent() async {
        guard let asset = currentAsset else { return }
        isExporting = true
        defer { isExporting = false }
        guard let url = await store.photoKit.exportToTemporaryFile(for: asset.id) else { return }
        shareItem = ShareItem(url: url)
    }

    /// Identifiable wrapper for `.sheet(item:)`.
    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private static func currentWindowInsets() -> EdgeInsets {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.keyWindow else { return .init() }
        let i = window.safeAreaInsets
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }
}

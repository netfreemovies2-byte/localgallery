import SwiftUI
import UIKit
import AVFoundation
import Photos

/// The swipeable page container for the photo-library viewer.
///
/// A `UIPageViewController` for the same reason the folder viewer uses
/// one: it gives the platform's own paging physics (rubber-banding,
/// interactive transitions) for free, and it keeps the *neighbouring*
/// pages alive so a swipe does not decode from scratch.
///
/// The paging identity is the asset's `localIdentifier`, not an index:
/// a library reload can insert or remove assets between the viewer being
/// built and the user swiping.
struct PhotoKitPagingView: UIViewControllerRepresentable {
    let assets: [PhotoKitAsset]
    /// The Store, passed in rather than read from the environment: a
    /// `UIViewControllerRepresentable` cannot use `@Environment`, and the
    /// page views need it for the photo-library service.
    let store: GalleryStore
    @Binding var currentAssetID: String
    @Binding var isChromeVisible: Bool
    @Binding var videoTransportVisible: Bool

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        // Open on the asset the user tapped, not on the first one. The
        // folder pager has the same rule — the id is the source of truth
        // and the index is re-resolved against the current array.
        let initialID: String? = assets.contains(where: { $0.id == currentAssetID })
            ? currentAssetID
            : assets.first?.id
        if let initialID {
            let initial = context.coordinator.makeHostingController(for: initialID)
            pvc.setViewControllers([initial], direction: .forward, animated: false)
            context.coordinator.parent.currentAssetID = initialID
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard let current = pvc.viewControllers?.first as? IndexedHostingController,
              current.assetID != currentAssetID,
              assets.contains(where: { $0.id == currentAssetID }) else { return }
        // Programmatic `setViewControllers` mid-swipe trips
        // UIPageViewController's assertion, so the request is stashed and
        // applied from `didFinishAnimating` instead.
        if context.coordinator.isTransitioning {
            context.coordinator.pendingAssetID = currentAssetID
            return
        }
        context.coordinator.applyAssetID(currentAssetID, to: pvc)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A hosting controller that remembers which asset it is showing.
    class IndexedHostingController: UIHostingController<AnyView> {
        let assetID: String
        init(assetID: String, rootView: AnyView) {
            self.assetID = assetID
            super.init(rootView: rootView)
            view.backgroundColor = .clear
        }
        @MainActor required init?(coder: NSCoder) { fatalError() }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoKitPagingView
        var isTransitioning = false
        var pendingAssetID: String?
        /// Assets frozen for the duration of a manual swipe, so an
        /// enrichment tick that rebuilds `parent.assets` cannot shift the
        /// answers UIKit gets mid-transition.
        private var assetsSnapshot: [PhotoKitAsset]?
        /// Weak cache so a given asset always resolves to the same hosting
        /// controller while UIPageViewController still holds it.
        private final class WeakVC { weak var vc: IndexedHostingController? }
        private var vcCache: [String: WeakVC] = [:]

        init(_ parent: PhotoKitPagingView) { self.parent = parent }

        private var activeAssets: [PhotoKitAsset] {
            assetsSnapshot ?? parent.assets
        }

        func makeHostingController(for assetID: String) -> IndexedHostingController {
            if let cached = vcCache[assetID]?.vc { return cached }
            let assets = activeAssets
            let idx = assets.firstIndex(where: { $0.id == assetID }) ?? 0
            let asset = assets[idx]
            let view = PhotoKitPageView(
                asset: asset,
                isChromeVisible: parent.$isChromeVisible,
                videoTransportVisible: parent.$videoTransportVisible
            )
            .environment(parent.store)
            let controller = IndexedHostingController(assetID: assetID, rootView: AnyView(view))
            let box = WeakVC()
            box.vc = controller
            vcCache[assetID] = box
            return controller
        }

        func applyAssetID(_ assetID: String, to pvc: UIPageViewController) {
            guard let current = pvc.viewControllers?.first as? IndexedHostingController,
                  current.assetID != assetID,
                  parent.assets.contains(where: { $0.id == assetID }) else { return }
            let curIdx = parent.assets.firstIndex(where: { $0.id == current.assetID }) ?? 0
            let tarIdx = parent.assets.firstIndex(where: { $0.id == assetID }) ?? 0
            let direction: UIPageViewController.NavigationDirection = tarIdx > curIdx ? .forward : .reverse
            let vc = makeHostingController(for: assetID)
            pvc.setViewControllers([vc], direction: direction, animated: false)
            vcCache = vcCache.filter { $0.value.vc != nil }
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerBefore vc: UIViewController
        ) -> UIViewController? {
            let assets = activeAssets
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = assets.firstIndex(where: { $0.id == indexed.assetID }),
                  curIdx > 0 else { return nil }
            return makeHostingController(for: assets[curIdx - 1].id)
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            viewControllerAfter vc: UIViewController
        ) -> UIViewController? {
            let assets = activeAssets
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = assets.firstIndex(where: { $0.id == indexed.assetID }),
                  curIdx < assets.count - 1 else { return nil }
            return makeHostingController(for: assets[curIdx + 1].id)
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
            assetsSnapshot = parent.assets
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            assetsSnapshot = nil
            if completed, let indexed = pvc.viewControllers?.first as? IndexedHostingController {
                parent.currentAssetID = indexed.assetID
            }
            vcCache = vcCache.filter { $0.value.vc != nil }
            if let pending = pendingAssetID {
                pendingAssetID = nil
                applyAssetID(pending, to: pvc)
            }
        }
    }
}

import SwiftUI
import AVFoundation
import UIKit
import BackgroundTasks

/// AppDelegate handles two things: per-screen orientation locking (used by
/// `OrientationLock`) and registration of the once-a-day background refresh
/// task that re-runs memory generation when the app isn't open. Registration
/// must happen synchronously in `didFinishLaunchingWithOptions`, before the
/// scene is connected — that's why this lives here and not on `GalleryStore`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// `BGTaskSchedulerPermittedIdentifiers` whitelists these exact strings
    /// in the Info.plist; they must stay in sync (the video-export identifier
    /// lives on `VideoExportShield`). `nonisolated` so the scheduling helpers
    /// can read it.
    nonisolated static let backgroundRefreshIdentifier = "com.j23n.pixelpic.app.dailyMemories"
    nonisolated static let sidecarRefreshIdentifier = "com.j23n.pixelpic.app.sidecarRefresh"

    /// Owns the BG-task → store indirection. The `WindowGroup` attaches the
    /// `GalleryStore` once SwiftUI builds the scene. We hold the service
    /// here (rather than reaching for a `GalleryStore.shared` global) so the
    /// BG handler has a stable, isolation-correct API to call.
    let memoryRefresh = MemoryRefreshService()
    let sidecarRefresh = SidecarRefreshService()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Capture the service value (Sendable because MemoryRefreshService is
        // `@MainActor`) rather than `self` (AppDelegate isn't auto-Sendable
        // under Swift 6 strict concurrency).
        let service = memoryRefresh
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: nil
        ) { task in
            Self.handleBackgroundRefresh(task: task as! BGAppRefreshTask, service: service)
        }

        let sidecarService = sidecarRefresh
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.sidecarRefreshIdentifier,
            using: nil
        ) { task in
            Self.handleSidecarRefresh(task: task as! BGAppRefreshTask, service: sidecarService)
        }

        // Continued-processing shield for the slideshow video export — keeps
        // the encode running (with system progress UI) when the user
        // backgrounds the app mid-render. The identifier lives on the shield;
        // it must also stay listed in BGTaskSchedulerPermittedIdentifiers.
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: VideoExportShield.taskIdentifier,
                using: nil
            ) { task in
                VideoExportShield.shared.adopt(task as! BGContinuedProcessingTask)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.scheduleBackgroundRefresh()
            Self.scheduleSidecarRefresh()
        }

        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.current
    }

    /// Schedule the next background refresh ~24h out. iOS treats this as an
    /// earliest-bound — the actual run is opportunistic and may be skipped.
    /// The foreground catch-up in `GalleryStore.generateMemoriesIfNeeded` is
    /// the safety net for days iOS skips.
    ///
    /// `nonisolated` so the `didEnterBackgroundNotification` observer (a
    /// `@Sendable` closure) and the `BGAppRefreshTask` handler can call it
    /// without hopping back to MainActor — neither needs MainActor state.
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.bg.info("Scheduled background refresh for ~24h from now")
        } catch {
            // Common reasons: simulator (where BG tasks aren't supported) or
            // user disabled "Background App Refresh". Not actionable from code.
            Log.bg.warning("Failed to schedule background refresh: \(Log.r.error(error))")
        }
    }

    /// Schedule the next sidecar refresh ~12h out — twice the cadence of the
    /// daily memories task. Best-effort, same as memories.
    nonisolated static func scheduleSidecarRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: sidecarRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.bg.info("Scheduled sidecar refresh for ~12h from now")
        } catch {
            Log.bg.warning("Failed to schedule sidecar refresh: \(Log.r.error(error))")
        }
    }

    /// Handler for the background refresh. Forwards to `MemoryRefreshService`
    /// which runs the once-a-day memory regeneration on the attached store
    /// (or no-ops on a background-only launch where the WindowGroup never
    /// built). Always re-schedules the next run so a single skipped day
    /// doesn't kill the recurring schedule.
    private static func handleBackgroundRefresh(task: BGAppRefreshTask, service: MemoryRefreshService) {
        Log.bg.info("Background refresh started")
        scheduleBackgroundRefresh()

        let work = Task { @MainActor in
            await service.runDailyRefresh()
        }

        // Expiration just cancels — completion is reported once below after
        // `work` finishes (or finishes-via-cancellation), so we never call
        // `setTaskCompleted` twice.
        task.expirationHandler = {
            Log.bg.warning("Background refresh expired before completion")
            work.cancel()
        }

        Task {
            await work.value
            let success = !work.isCancelled
            task.setTaskCompleted(success: success)
            Log.bg.info("Background refresh finished (success: \(success))")
        }
    }

    /// Handler for the sidecar refresh. Mirrors `handleBackgroundRefresh`
    /// but routes to `SidecarRefreshService`.
    private static func handleSidecarRefresh(task: BGAppRefreshTask, service: SidecarRefreshService) {
        Log.bg.info("Sidecar refresh started")
        scheduleSidecarRefresh()

        let work = Task { @MainActor in
            await service.runRefresh()
        }

        task.expirationHandler = {
            Log.bg.warning("Sidecar refresh expired before completion")
            work.cancel()
        }

        Task {
            await work.value
            let success = !work.isCancelled
            task.setTaskCompleted(success: success)
            Log.bg.info("Sidecar refresh finished (success: \(success))")
        }
    }
}

@MainActor
enum OrientationLock {
    static var current: UIInterfaceOrientationMask = .all

    static func lock(_ mask: UIInterfaceOrientationMask, rotateTo orientation: UIInterfaceOrientation? = nil) {
        current = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if let orientation, mask.contains(orientationMask(for: orientation)) {
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientationMask(for: orientation))
            scene.requestGeometryUpdate(prefs) { _ in }
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func orientationMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .all
        }
    }
}

@main
struct PixelPicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = GalleryStore()
    @State private var router = AppRouter()
    @AppStorage("crashReportingEnabled") private var crashReportingEnabled = false
    /// The appearance the user picked in Settings.
    ///
    /// `@AppStorage` rather than a `GalleryStore` property: the setting is
    /// about the *window*, not about the library, and it has to be applied
    /// at the scene root — a value the app root reads on every appearance
    /// change. The stored raw value is read through `AppAppearance` so an
    /// unknown one degrades to "System" rather than leaving the app with
    /// no scheme at all.
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRaw = AppAppearance.system.rawValue

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureAppearance()
        CrashDiagnosticsService.shared.setEnabled(crashReportingEnabled)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(router)
                .tint(Design.accentColor)
                // The user's appearance choice. `nil` follows the system,
                // which is the default; a forced scheme overrides it.
                //
                // Applied at the scene root so it reaches every window and
                // every sheet — a scheme set on a single tab would leave the
                // Settings sheet (a separate presentation) in the old one.
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme)
                // Hand the store to the BG-task service. Runs once per
                // scene build; on a true background-only launch the
                // WindowGroup doesn't build and the service stays detached
                // (BG handler no-ops, foreground catch-up takes over on
                // next entry).
                //
                // Trade-off vs the previous synchronous `Self.shared = self`
                // in `GalleryStore.init()`: there is now a small additional
                // window between `@State` materialisation and `.task` firing
                // where a BG handler could see a store-less service and
                // no-op. In practice BG tasks are gated to ≥24h after
                // submission and the foreground catch-up covers any miss, so
                // the window is benign.
                .task {
                    appDelegate.memoryRefresh.attach(store)
                    appDelegate.sidecarRefresh.attach(store)
                    // Pre-render the six slideshow music themes so the first
                    // memory open doesn't pay the synth cost on the main
                    // actor. Idempotent — already-cached themes are skipped.
                    Task.detached(priority: .background) {
                        await SlideshowMusicCache.prewarmAll()
                    }
                }
                .onOpenURL { url in
                    router.handle(url)
                }
        }
    }

    private func configureAppearance() {
        // The dynamic variants, not `UIColor(Design.bg)`. `UIColor(Color)`
        // snapshots the colour at the *current* trait collection, so it
        // would bake today's appearance into the proxy and never follow a
        // system appearance change. The `Scheme` exposes the provider
        // itself, so the nav bar resolves light or dark per trait
        // collection — the same source the SwiftUI tokens use.
        let accent = Design.accentUIColor

        // The WindowGroup-level `.tint()` is the SwiftUI authority, but there
        // are gaps where it can't reach a control: sheet presentations cross
        // a `UIPresentationController` boundary (and nested sheets compound
        // it — Settings → Linked Contacts → Contact picker), and during
        // bursts of observed-state updates descendant Lists can rebuild before
        // the new tint context resolves. In any of those gaps the underlying
        // UIView falls through to `tintColor`, which inherits up to the window
        // — and the iOS default window tint is system blue.
        //
        // The `@Observable` migration (#21) eliminated most rebuild-burst
        // triggers (field-level granularity vs `@Published`'s whole-object
        // invalidation), but the sheet-boundary tint gap is an iOS layout
        // constraint independent of the observation framework. Verified still
        // needed under iOS 18 + `@Observable`: Settings → Linked Contacts →
        // Contact picker continues to resolve to system blue without this.
        //
        // SwiftUI `.tint()` modifiers continue to override where intentional
        // (e.g. `.tint(.primary)` on the Folder row in Settings).
        UIView.appearance().tintColor = accent
        UIWindow.appearance().tintColor = accent

        // Nav bar: transparent at scroll edge, translucent blur when content
        // scrolls under. Matches stock apps (Photos, Messages) — no opaque band.
        // Unrelated to @Observable; still required for the warm design treatment.
        //
        // The alpha is applied *inside* the colour provider
        // (`dynamic(alpha:)`), not with `withAlphaComponent` on a resolved
        // colour: that call snapshots the current appearance, which is
        // exactly the bug this whole pass is fixing.
        let navStandard = UINavigationBarAppearance()
        navStandard.configureWithOpaqueBackground()
        navStandard.backgroundColor = Design.bgScheme.dynamic(alpha: 0.90)
        navStandard.shadowColor = .clear
        navStandard.titleTextAttributes = [.foregroundColor: Design.inkScheme.dynamic]

        let navEdge = UINavigationBarAppearance()
        navEdge.configureWithTransparentBackground()
        navEdge.shadowColor = .clear
        navEdge.titleTextAttributes = [.foregroundColor: Design.inkScheme.dynamic]

        UINavigationBar.appearance().standardAppearance = navStandard
        UINavigationBar.appearance().scrollEdgeAppearance = navEdge
        UINavigationBar.appearance().compactAppearance = navStandard
        UINavigationBar.appearance().compactScrollEdgeAppearance = navEdge

        // No tab bar appearance: the app has no tabs. It is a single
        // gallery — one navigation stack rooted at the Albums screen.
    }
}

struct ContentView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        // The one main screen: the Albums gallery over the device's
        // Photos library. The path is bound so the album grid's drill-in
        // pushes onto this stack; `PhotoKitLibraryView` registers the
        // `PhotoLibraryRoute` destination on it.
        //
        // There is deliberately nothing else here — no TabView, no
        // folder restore, no "choose a folder" gate. The app opens
        // straight into the gallery, and the gallery's own view owns
        // the Photos-permission states.
        NavigationStack(path: $router.photoLibraryPath) {
            PhotoKitLibraryView()
        }
    }
}

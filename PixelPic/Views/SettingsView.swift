import SwiftUI
import UIKit

/// Settings for a simple gallery — and nothing else.
///
/// What is here is what a person using a photo gallery actually needs:
/// the Photos access state (and the way to fix it), the appearance, the
/// album grid size, the photo order, and the app version.
///
/// What is deliberately *not* here any more: the folder-library picker
/// and rescan controls, on-device tagging and its model pack, people /
/// birthday / contacts features, library stats, crash reporting and log
/// screens, and the repository link. Those belonged to the app Pixel
/// Pic used to be — a settings-heavy folder browser with AI features —
/// not to the QuickPic-style gallery it is now. Their screens are gone
/// from the settings UI entirely: no empty sections, no dead rows.
struct SettingsView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// The appearance the user picked.
    ///
    /// A stored property rather than a local `@AppStorage` inside
    /// `appearanceSection`: a local property wrapper is re-created on
    /// every evaluation of the computed property, which would tear the
    /// binding down and rebuild it on each render.
    ///
    /// The app root reads the same key, so writing it here updates the
    /// window's colour scheme immediately.
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRaw = AppAppearance.system.rawValue
    /// Album grid density tier — the same `gridSizeTier` the album
    /// screens' own grid button cycles.
    @AppStorage("gridSizeTier") private var gridSizeTier = 0
    /// Photo order inside an album. `false` (the default) is
    /// newest-first; `PhotoKitService` reads the same key when it
    /// builds its fetches.
    @AppStorage("albumSortOldestFirst") private var sortOldestFirst = false
    /// Whether empty user albums show on the home grid. Off by
    /// default: an album with nothing in it is noise on the home
    /// screen. The home grid's filter menu writes the same key.
    @AppStorage("showEmptyAlbums") private var showEmptyAlbums = false

    var body: some View {
        NavigationStack {
            List {
                photosAccessSection
                appearanceSection
                gallerySection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            // The user can change Photos access in the system Settings
            // while this sheet is up behind it; re-read the state when
            // the app comes back to the front so the row is never stale.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    let before = store.photoKit.authorization
                    store.photoKit.refreshAuthorization()
                    if before != store.photoKit.authorization,
                       store.photoKit.authorization.isReadable {
                        await store.photoKit.loadLibrary()
                    }
                }
            }
        }
    }

    // MARK: - Photos access

    /// The device Photos library's access state, and the one action that
    /// can change it from here.
    ///
    /// The gallery itself offers the same recovery, but a user who said
    /// no once and forgot should be able to see the state — and fix it —
    /// from Settings, without the app re-asking for permission on every
    /// appearance.
    @ViewBuilder
    private var photosAccessSection: some View {
        Section {
            LabeledContent {
                Text(photosAccessSummary)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Photos Library", systemImage: "photo.on.rectangle.angled")
            }

            switch store.photoKit.authorization {
            case .notDetermined:
                Button {
                    Task {
                        let result = await store.photoKit.requestAccess()
                        if result.isReadable {
                            await store.photoKit.loadLibrary()
                        }
                    }
                } label: {
                    Label("Allow Access to Photos", systemImage: "hand.raised")
                }
            case .denied, .limited:
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
            case .restricted, .authorized:
                // Nothing to offer: a policy is the device
                // administrator's to change, and full access needs no
                // action at all.
                EmptyView()
            }
        } header: {
            Text("Device Photos")
        } footer: {
            Text("Pixel Pic shows the photos already on this device — your Camera, Screenshots and your own albums. Nothing is uploaded and nothing leaves the device.")
        }
    }

    private var photosAccessSummary: String {
        switch store.photoKit.authorization {
        case .notDetermined: return "Not requested"
        case .restricted: return "Blocked by policy"
        case .denied: return "Not allowed"
        case .limited: return "Limited access"
        case .authorized: return "Full access"
        }
    }

    // MARK: - Appearance

    /// The light/dark control.
    ///
    /// The app's palette is a warm light/dark *pair* (`Design.Scheme`),
    /// so both appearances are designed rather than one being the system
    /// grey. "System" is the default and follows the device.
    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker(selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("“System” follows your device’s setting.")
        }
    }

    // MARK: - Gallery

    /// The two controls that shape the gallery itself: how dense the
    /// album grids are, and which end of an album they start from.
    ///
    /// Both write the same preference keys the gallery reads, so a
    /// change here and the album screen's own grid-size button can
    /// never disagree.
    @ViewBuilder
    private var gallerySection: some View {
        Section {
            Picker(selection: $gridSizeTier) {
                Text("2 columns").tag(0)
                Text("3 columns").tag(1)
                Text("4 columns").tag(2)
                Text("5 columns").tag(3)
            } label: {
                Label("Grid Size", systemImage: "square.grid.3x3")
            }

            Picker(selection: $sortOldestFirst) {
                Text("Newest first").tag(false)
                Text("Oldest first").tag(true)
            } label: {
                Label("Photo Order", systemImage: "arrow.up.arrow.down")
            }

            Toggle(isOn: $showEmptyAlbums) {
                Label("Show Empty Albums", systemImage: "photo.stack")
            }
        } header: {
            Text("Gallery")
        } footer: {
            Text("Photo Order applies the next time you open an album.")
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
        } header: {
            Text("About")
        } footer: {
            Text("Pixel Pic — a simple gallery for the photos on this device.")
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if build.isEmpty || build == short { return short }
        return "\(short) (\(build))"
    }
}

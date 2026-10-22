import SwiftUI

/// The app's appearance preference.
///
/// A top-level type rather than a nested enum so a test can pin the
/// mapping without a view — and so the value can be read from
/// `UserDefaults` in two places (the Settings picker and the app root's
/// `preferredColorScheme`) without either owning it.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system. The default, and what most people leave it on.
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The `UserDefaults` key.
    static let defaultsKey = "appAppearance"

    /// The title shown in the picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The SwiftUI colour scheme to force, or `nil` to follow the system.
    ///
    /// `nil` rather than `.light`/`.dark` for the "system" case is what
    /// makes "System" mean *follow* rather than *be light* — a forced
    /// scheme would ignore the device's own setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Read the stored preference, falling back to `.system` when the key
    /// is absent or holds something this version does not know.
    ///
    /// The fallback matters: a value written by a newer build (or
    /// corrupted by hand) must not leave the app with no appearance at
    /// all, and must not trap on an unknown raw value.
    static func stored(in defaults: UserDefaults) -> AppAppearance {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = AppAppearance(rawValue: raw) else {
            return .system
        }
        return value
    }
}

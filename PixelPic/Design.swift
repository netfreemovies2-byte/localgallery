import SwiftUI
import UIKit

// MARK: - Design Tokens (Quiet direction)

enum Design {
    // MARK: Colour model

    /// sRGB components of one colour in one appearance. `Sendable`, so a
    /// palette can be shared between the SwiftUI tokens and the UIKit
    /// appearance proxies without a data race.
    struct Components: Sendable {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat

        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        func uiColor() -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: a)
        }
    }

    /// A light/dark pair — the single source of truth for one token.
    ///
    /// Both the SwiftUI `Color` and the `UIColor` the UIKit appearance
    /// proxies use (nav bar, tab bar) resolve from the same pair, so the
    /// chrome and the content can never drift apart in dark mode. That is
    /// the reason this is a pair and not two independent colours: a token
    /// that is written twice is a token that eventually disagrees with
    /// itself.
    struct Scheme: Sendable {
        let light: Components
        let dark: Components

        func components(for traits: UITraitCollection) -> Components {
            traits.userInterfaceStyle == .dark ? dark : light
        }

        /// The dynamic colour: one provider, resolved per trait collection.
        var dynamic: UIColor {
            UIColor { traits in components(for: traits).uiColor() }
        }

        /// The same colour with a fixed alpha folded in *inside* the
        /// provider, so the translucency follows the appearance too.
        /// `UIColor.withAlphaComponent` on a dynamic colour is avoided on
        /// purpose — the alpha has to be applied where the components are
        /// chosen, not where the resolved colour happens to be.
        func dynamic(alpha multiplier: CGFloat) -> UIColor {
            UIColor { traits in
                let c = components(for: traits)
                return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * multiplier)
            }
        }

        var color: Color { Color(uiColor: dynamic) }
    }

    // MARK: Palette

    /// Warm, stock-adjacent palette (#FAF7F2 canvas, muted amber accent)
    /// with a matching dark scheme. The dark scheme is the same warm
    /// family at low luminance rather than a neutral grey, so a photo
    /// grid in dark mode still sits on a warm canvas instead of a cold
    /// one.
    static let bgScheme = Scheme(
        light: Components(0.980, 0.969, 0.949),   // #FAF7F2
        dark:  Components(0.071, 0.067, 0.063)     // #121110
    )
    static let bgCardScheme = Scheme(
        light: Components(1.000, 1.000, 1.000),   // #FFFFFF
        dark:  Components(0.114, 0.106, 0.098)     // #1D1B19
    )
    static let bgGroupedScheme = Scheme(
        light: Components(0.949, 0.929, 0.898),   // #F2EDE5
        dark:  Components(0.149, 0.137, 0.125)     // #262320
    )
    static let inkScheme = Scheme(
        light: Components(0.110, 0.102, 0.086),   // #1C1A16
        dark:  Components(0.949, 0.937, 0.914)     // #F2EFE9
    )
    static let ink2Scheme = Scheme(
        light: Components(0.369, 0.341, 0.302),   // #5E574D
        dark:  Components(0.710, 0.678, 0.631)     // #B5ADA1
    )
    static let ink3Scheme = Scheme(
        light: Components(0.584, 0.553, 0.510),   // #958D82
        dark:  Components(0.541, 0.510, 0.471)     // #8A8278
    )
    static let separatorScheme = Scheme(
        light: Components(0.235, 0.216, 0.176, 0.10),
        dark:  Components(1.000, 1.000, 1.000, 0.14)
    )
    /// The fill behind the search field — a faint wash of the ink colour
    /// rather than a system grey, so it matches the canvas in both
    /// appearances.
    static let fieldFillScheme = Scheme(
        light: Components(0.110, 0.102, 0.086, 0.06),
        dark:  Components(1.000, 1.000, 1.000, 0.10)
    )
    static let destructiveScheme = Scheme(
        light: Components(0.698, 0.290, 0.227),   // #B24A3A
        dark:  Components(0.878, 0.439, 0.361)     // #E0705C
    )
    /// The pulse drawn over a loading thumbnail. It has to *lighten* the
    /// placeholder, so it is a white wash rather than another ink tint —
    /// an ink wash would darken the tile and read as a pressed state
    /// instead of a load in progress.
    static let shimmerScheme = Scheme(
        light: Components(1.000, 1.000, 1.000, 0.55),
        dark:  Components(1.000, 1.000, 1.000, 0.10)
    )

    // MARK: Tokens

    static let accentColor  = Color("AccentColor")

    /// The Albums home toolbar blue, from the QuickPic reference the
    /// redesign is modelled on (Material Blue 600, #1E88E5). Used for
    /// the home navigation bar in both appearances — the reference's
    /// toolbar does not change with the theme; the content below it
    /// still follows the Appearance setting.
    static let toolbarBlue  = Color(red: 0.118, green: 0.533, blue: 0.898)
    static let accentSoft   = Color("AccentColor").opacity(0.13)

    /// The accent as a *dynamic* `UIColor`, for the UIKit appearance
    /// proxies. `UIColor(Design.accentColor)` would snapshot the accent at
    /// the current trait collection — the same bug the `Scheme` type
    /// exists to fix — and the asset catalogue's own dark variant would
    /// never be reached after a system appearance change.
    ///
    /// `UIColor(named:)` resolves the catalogue's per-appearance variants
    /// per trait collection, so this one stays in step with the SwiftUI
    /// token above.
    ///
    /// A computed `static var` rather than a `static let`: `UIColor` is not
    /// `Sendable`, and a stored static of a non-`Sendable` type is a
    /// Swift 6 concurrency error. The lookup is cheap and cached by UIKit.
    static var accentUIColor: UIColor {
        UIColor(named: "AccentColor")
            ?? UIColor(red: 0.769, green: 0.541, blue: 0.243, alpha: 1)
    }

    static let bg           = bgScheme.color
    static let bgCard       = bgCardScheme.color
    static let bgGrouped    = bgGroupedScheme.color

    static let ink          = inkScheme.color
    static let ink2         = ink2Scheme.color
    static let ink3         = ink3Scheme.color
    static let separator    = separatorScheme.color
    static let fieldFill    = fieldFillScheme.color
    static let shimmer      = shimmerScheme.color

    static let destructive  = destructiveScheme.color

    static let cardRadius: CGFloat = 14
    static let memoryRadius: CGFloat = 20

    /// Newsreader italic stand-in (system serif italic) — used for memory titles.
    static func serifItalic(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif).italic()
    }
}

extension View {
    /// Soft gradient fade at the top edge of the enclosing scroll view so
    /// content dissolves into the nav bar (iOS 26+ — no-op on older OSes).
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Tab bar shrinks to a floating accessory while the user scrolls down
    /// and re-expands on scroll-up (iOS 26+ — no-op on older OSes). More
    /// photo per screen on the three grid tabs.
    @ViewBuilder
    func minimizableTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

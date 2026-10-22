import Foundation
import os

/// Owns the security-scoped bookmark for the user-picked photo folder and the
/// matching balanced `startAccessingSecurityScopedResource` / `stop…` calls.
///
/// Single source of truth for "which URL are we currently scoped into?" — every
/// scan, foreground refresh, and rescan reads it from here. The Store retains
/// this service and forwards picker / settings calls into it.
@MainActor
final class BookmarkManager {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    /// `nonisolated(unsafe)` so the implicit-nonisolated deinit can read it
    /// to balance the final `stopAccessingSecurityScopedResource`. Mutations
    /// happen only from `@MainActor` methods on this instance, so reads from
    /// deinit observe a stable last-written value.
    private(set) nonisolated(unsafe) var activeURL: URL?

    /// True when the last `startAccessing(_:)` was **refused** by the OS.
    ///
    /// The distinction this carries is the difference between two failure
    /// modes that look identical from the scanner's side: a folder that is
    /// gone (or a provider that is offline) and a folder we are simply not
    /// allowed to read any more. The scanner reports both the same way — the
    /// root's listing failed — so the only place that knows the difference is
    /// here, where the security scope was refused.
    ///
    /// `nil` means "not known": no scope has been attempted since launch.
    private(set) var lastStartDenied: Bool? = nil

    /// No default for `bookmarkKey` — it comes from `GalleryPaths` (via the
    /// Store) so the key string lives in exactly one place.
    init(defaults: UserDefaults = .standard, bookmarkKey: String) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

    deinit {
        // Under Swift 6, deinit on a `@MainActor` type is implicitly
        // nonisolated — it runs on whichever thread releases the last
        // reference. That's why `activeURL` above is `nonisolated(unsafe)`.
        // `stopAccessingSecurityScopedResource()` is documented thread-safe
        // (it's reference-counted), so calling it from any thread is fine.
        activeURL?.stopAccessingSecurityScopedResource()
    }

    func save(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmarkData, forKey: bookmarkKey)
            // A new bookmark supersedes the old one, so the previous
            // refusal no longer describes anything. Clearing it here means
            // the next scan cannot report "access denied" on the strength of
            // a refusal that belonged to a *different* folder.
            lastStartDenied = nil
        } catch {
            Log.cache.error("Failed to save bookmark: \(Log.r.error(error))")
        }
    }

    func resolve() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                save(for: url)
            }
            return url
        } catch {
            Log.cache.error("Failed to resolve bookmark: \(Log.r.error(error))")
            return nil
        }
    }

    /// Balanced start: stops any currently-active scope before starting the new
    /// one, so a single instance never holds two scopes at once. `activeURL` is
    /// only recorded when the start call succeeds — recording it on failure
    /// would make the next `stopAccessing()` unbalanced (a documented kernel
    /// resource leak) and hide the access failure from diagnostics.
    ///
    /// A refusal is recorded in `lastStartDenied` rather than being thrown
    /// away: it is the one signal that separates "we may not read this
    /// folder" from "this folder is gone", and the scan pipeline needs it to
    /// pick the right empty state.
    func startAccessing(_ url: URL) {
        stopAccessing()
        guard url.startAccessingSecurityScopedResource() else {
            Log.cache.error("Security-scoped access denied for \(Log.r.path(url))")
            lastStartDenied = true
            return
        }
        lastStartDenied = false
        activeURL = url
    }

    func stopAccessing() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
    }
}

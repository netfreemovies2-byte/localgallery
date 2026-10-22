import SwiftUI

/// Shared empty / unavailable state for the three library tabs. The default
/// copy is the "pick a folder" path; callers override `message` when a
/// folder is already selected, and pass both `retryTitle` and `onRetry` when
/// the recovery action is a rescan rather than a trip to Settings.
struct LibraryEmptyState: View {
    let icon: String
    let title: String
    var message: String = "Choose a folder in Settings to get started."
    var retryTitle: String? = nil
    var onRetry: (() -> Void)? = nil
    /// A second, secondary action — used by the permission-denied state,
    /// where "Retry" is useless on its own and the real fix is to pick the
    /// folder again.
    var secondaryTitle: String? = nil
    var onSecondary: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(Design.accentColor.opacity(0.7))
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Design.ink2)
                    .multilineTextAlignment(.center)
            }
            if let retryTitle, let onRetry {
                Button(retryTitle, action: onRetry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.accentColor)
            }
            if let secondaryTitle, let onSecondary {
                Button(secondaryTitle, action: onSecondary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.ink2)
            }
        }
        .padding(32)
    }

    /// Bookmark exists but the root is gone or the provider is offline.
    /// Retry is a non-silent light scan so progress UI is visible — a silent
    /// pass would look like the button did nothing.
    static func unavailable(icon: String, onRetry: @escaping () -> Void) -> LibraryEmptyState {
        LibraryEmptyState(
            icon: icon,
            title: "Library Unavailable",
            message: "The selected folder can’t be found. It may have been moved or is temporarily offline.",
            retryTitle: "Retry",
            onRetry: onRetry
        )
    }

    /// The folder is there but the app is not allowed to read it — the
    /// security scope lapsed, or the folder was never granted. A retry
    /// cannot fix that (the scope has to be re-established first), so the
    /// copy points at the one action that can: choosing the folder again.
    static func permissionDenied(icon: String, onReopen: @escaping () -> Void) -> LibraryEmptyState {
        LibraryEmptyState(
            icon: icon,
            title: "Access Denied",
            message: "Pixel Pic doesn’t have permission to read the selected folder. Choose it again to grant access.",
            secondaryTitle: "Choose Folder…",
            onSecondary: onReopen
        )
    }

    /// Folder is selected and listable, but the walk found no images.
    /// Distinct from the default copy so we don't send the user to Settings
    /// to "choose a folder" they already chose.
    static func selectedFolderEmpty(icon: String, title: String) -> LibraryEmptyState {
        LibraryEmptyState(
            icon: icon,
            title: title,
            message: "The selected folder doesn’t contain any images."
        )
    }
}

import Foundation
import Photos

/// The outcome of a library-mutating operation (create album, add,
/// move, delete), as the UI needs it: success, or a message worth
/// showing.
///
/// PhotoKit reports these failures as `PHPhotosError` values (or,
/// for change requests, as a bare `Bool` + `Error`). Mapping them in
/// one pure place keeps every screen honest in the same words — and
/// keeps the mapping unit-testable without a photo library.
enum PhotoKitOperationResult: Equatable {
    case success
    case failure(message: String)

    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failure(let message) = self { return message }
        return nil
    }

    /// Map a PhotoKit error to a user-facing result.
    ///
    /// `nil` error + unsuccessful flag happens when a change is
    /// rejected without a reason (limited access can do this); the
    /// message still has to say something true.
    static func from(error: Error?, succeeded: Bool) -> PhotoKitOperationResult {
        if succeeded { return .success }
        guard let error else {
            return .failure(message: "The change was not allowed. If you gave Pixel Pic limited access, the selected photos or the album may be outside the allowed set.")
        }
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain else {
            return .failure(message: error.localizedDescription)
        }
        return .failure(message: message(forPhotosErrorCode: nsError.code))
    }

    /// The message for one `PHPhotosError` code (the raw `NSError`
    /// code in `PHPhotosErrorDomain`). Only the codes with a
    /// genuinely different recovery get their own words; everything
    /// else falls through to one honest generic message.
    ///
    /// Codes: 3311 access user denied, 3312 access restricted,
    /// 3301 user cancelled, 3302 network access required.
    static func message(forPhotosErrorCode code: Int) -> String {
        switch code {
        case 3311, 3312:
            return "Pixel Pic doesn't have permission to change your photo library. You can allow it in Settings."
        case 3301:
            return "Cancelled."
        case 3302:
            return "This needs a network connection to finish (the item is in iCloud). Connect and try again."
        default:
            return "Something went wrong in the photo library. Try again."
        }
    }
}

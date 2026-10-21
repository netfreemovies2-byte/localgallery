# Camera Roll (iPhone Photos library)

The **Camera Roll** tab reads the iPhone Photos library through PhotoKit. It is
separate from the Folders / Collections / Photos tabs, which work on files the
user granted through the Files app (security-scoped bookmarks). Choosing a Files
folder never grants Photos access, and Photos access never exposes Files folders.
`PhotoFile` (URL-based) is untouched; Photos assets use their own small model
(`CameraRollItem`, keyed by `PHAsset.localIdentifier`).

## Source layout (`LocalGallery/CameraRoll/`)

| File | Role |
|---|---|
| `CameraRollModels.swift` | Pure value types + filter/sort/search/date grouping/selection logic (no Photos import) |
| `CameraRollImageService.swift` | PhotoKit: listing, albums, thumbnails (`PHCachingImageManager`, cancellable), GIF decode, video, info, favorite, delete, share export |
| `CameraRollLibrary.swift` | Authorization state, change observer, albums, settings (UserDefaults), user collections (JSON in Application Support) |
| `CameraRollTab.swift` | Tab root, permission states, albums grid, collections list, settings sheet |
| `CameraRollGridView.swift` | Timeline/grid with sections, multi-select, batch actions |
| `CameraRollViewer.swift` | Lazy-paging full-screen viewer: zoom, GIF, video, info, share, favorite, delete |

Tests: `LocalGalleryTests/Unit/CameraRollTests.swift`.

## Behaviour notes / limits

- Authorization is requested with `.readWrite` (needed for favorite/delete) only when the user taps **Allow Photos Access**. Limited access shows a banner with **Manage**; denied shows **Open Settings**; restricted explains why it can't be changed.
- iOS shows its own confirmation when deleting; the app asks first as well. Deleted items go to Recently Deleted.
- Hide/show albums and include/exclude videos are app preferences; nothing changes in Photos.
- User collections are app-defined (not Photos albums) and say so in the UI.
- Sorting is by creation date. File name and file size are not available for a whole library through public PhotoKit API, so there is no name/size sort, and search matches date and media type, not file name. File name appears in the Info sheet.
- Thumbnails come from `PHCachingImageManager` at cell pixel size; the viewer requests a screen-sized image (capped at 4096 px), never the full original. GIFs are decoded with ImageIO (frames sampled above 120).
- Moving assets between filesystem folders is not possible through PhotoKit.

## Manual verification on a device (not run in the authoring environment)

1. Fresh install -> Camera Roll tab shows the explanation + **Allow Photos Access**; no prompt appears before tapping.
2. Allow Full Access -> Photos grid fills with real items, month headers, video durations, GIF badge.
3. Delete + reinstall, choose **Select Photos** -> limited banner; **Manage** opens the picker; grid updates after choosing.
4. iOS Settings -> deny -> return -> denied screen; **Open Settings** works.
5. Albums: covers and counts match the Photos app; long-press an album -> Hide; Settings -> Show hidden albums reveals it.
6. Settings -> Include videos off -> grids, album counts and covers drop videos.
7. Viewer: swipe, pinch, double-tap, pan while zoomed (pager must not scroll), play a video, open a GIF (animates), Info sheet.
8. Favorite in viewer -> appears in Photos app Favorites; Share sheet opens a real file; Delete -> app confirm -> iOS confirm -> item gone, viewer advances.
9. Add/delete a photo in the Photos app while the grid is open -> grid refreshes.
10. Select multiple -> Add to Collection -> relaunch app -> collection and membership persist.

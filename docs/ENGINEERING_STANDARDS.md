# Pixel Pic — Engineering Standards

The standing rules for this project. They exist so that stability,
privacy and release quality do not depend on who happens to be
editing the code that day.

## Scope

- **Local-first.** The app works on the device's own Photos library.
  No accounts, no sign-in, no backend, no analytics, no cloud
  upload, no new network dependencies. A feature that needs a server
  is out of scope until that changes deliberately, in writing, here.
- PhotoKit access is least-privilege: read/write through
  `PHPhotoLibrary` only, with limited-access handled as a first-class
  state, and every mutation's failure surfaced to the user.

## Privacy

- **Logs never carry user data.** No photo metadata, filenames,
  private paths, asset identifiers, coordinates or names in log
  lines. The codebase's `Log.r.*` redactor (tokenized stand-ins) is
  the only way an identifying value may appear; counts, statuses and
  error domains/codes are fine.
- **Temporary files** (Live Photo paired videos, share/export
  copies) live under `temporaryDirectory` with opaque names and are
  purged at the next launch. They are never a storage location.
- **Deep links** validate scheme and host against a whitelist and
  treat every identifier as untrusted input that the app re-resolves
  itself; a link can never name a file path to open.
- **Entitlements stay minimal** (the shared app group, nothing
  else). No secrets, API keys or credentials in the repo or the
  shipped bundle. ATS exceptions require a written justification in
  this file.
- Face ID / app lock is a separate, later assessment — it is not
  part of any release until it is scoped on its own.

## Stability

- Every asynchronous request has a terminal path: cancellation,
  failure and empty results all resolve the waiter. A request that
  can wait forever is a bug, treated as release-blocking.
- Completions are generation-checked; stale results are dropped,
  never written into current state. Starting playback or loads is
  structured work owned by the screen that asked for it — no orphan
  tasks attaching players or images to pages the user has left.
- Full-resolution work happens only for the settled, on-screen item.
  Neighbours get thumbnails. Repeated open/close cycles and memory
  pressure must not crash or leak players, observers or layers.
- Loading, empty and error states are explicit everywhere, with
  progress for long fetches and a retry for failures. A silent
  spinner is not a state.

## Testing

- Every confirmed bug gets a regression test named for it, in the
  unit-test target, and the CI test job runs them on every release
  build. A test that would hang against the old code is an
  acceptable regression test for a hang — the job timeout is the
  failure signal.
- Reports state test results as passed / failed / not run, with the
  reason for anything not run. Untested is said plainly, never
  implied away.

## Release evidence

- Releases are optimized Release builds from project defaults. If an
  optimized build fails, fix forward from its log; falling back to
  an unoptimized build needs the user's explicit approval and is
  reported as a blocker, never done silently.
- Every delivery is reported in four separate parts, never merged:
  **source review** / **automated tests actually run** / **artifact
  verification** (bundle IDs, build flags from the log, IPA hash,
  no debug dylib) / **real-device testing**. A green build is
  evidence about compilation, never presented as proof a feature
  works on a phone.
- The user's own device test of the new build is the acceptance
  step for runtime behaviour, and the report says exactly what to
  tap.

## Project protection

- Preserve the license and all third-party license notices.
- Old code is removed only when it is verified unreachable *and*
  unused by shared services; retained-but-unreachable code is
  documented as such, not silently deleted and not silently shipped
  as a feature.

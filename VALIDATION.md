# Fork validation

## Build 136: boundary saves, file moves, multi-window quit, app-level speed (2026-10-19)

- Root cause found with heap snapshots of the app-level cycle benchmark: every
  open/close added one document-sized `NSData` (24 extra after 8 rounds of 3
  drawings, +20 MB). Each boundary save rewrote the file and added a new
  checkpoint even when nothing changed. `BoundarySaveTests` failed on build 135
  (modified date changed; checkpoints 2 vs 1) and passes now. The same test
  covers an unsignalled edit before close and a pending edit across an in-app move.
- Real-drawing cycle benchmark (open/close × 8, release, same harness):
  close 991 KB 142–149 → 116–121 ms, 840 KB 105–119 → 85–91 ms, 292 KB
  35–40 → 30–39 ms; open unchanged (about 50–85 ms). The pinned editor re-indexes
  every element of these drawings at load (`index`/`version` change on 1,333 of
  1,333 elements), so their boundary save still writes. The gain comes from
  skipping element decoding and reusing parses, not from the skip itself.
- A first attempt to skip writes when the destination was missing broke an
  existing guarantee (`testForcedSaveBeforeDirtyMetadataAndRetry`: first saves
  must create the file). It was replaced by following recorded in-app moves.
- Full `script/test_local.sh` (run under `caffeinate -du`; the high-refresh
  fixture needs an awake display): 42 plugin, 62 editor, TypeScript, patch
  checks, **82 XCTest** and **26 Swift Testing** cases passed.

## Build 135: linked-file ID race, review coverage (2026-10-19)

- The linked-file ID table is now lock-protected. A 2,000-way concurrent
  lookup test agrees on one ID, and moves keep it.
- Review coverage. Every one of the 722 Swift files was swept for: forced
  casts and `try!`; force indexing and unwrapping; unique-key dictionaries;
  observers and repeating timers; main-thread `sync`; static caches; file reads
  in main-actor files; locks held across early returns; `@Published` writes from
  background work. Read file by file: autosave, recovery, scheduler, snapshot and
  appState savers; the web message bridge and save stream; FileState's save and
  switch boundary; FileCoordinator, FileSyncCoordinator, FolderMonitor and the
  folder monitor modifier; linked-folder persistence, loader and providers;
  checkpoint repositories; preview and library caches; the Quick Look extension;
  both loopback servers; the MCP server and bridge validation paths.
- Measured and rejected: caching security-scoped bookmark resolution
  (0.27 ms median per call) is not worth the scoping risk.
- Full `script/test_local.sh`: 42 plugin, 62 editor, TypeScript, patch checks,
  **79 XCTest** and **26 Swift Testing** cases passed.

## Build 134: multi-window file events, file I/O, app-level measurements (2026-10-19)

- App-level benchmark: the real bundled editor and the app's own open, MCP-edit,
  autosave and close paths, with 3 real repository drawings (991, 840 and
  292 KB, given the standard envelope they lack), in the in-memory test
  database. 3 runs each of build 131 code (2abc3294) and build 133: open, MCP
  edit+save, autosave write and close medians matched within about 10%
  (e.g. 991 KB drawing: autosave 23/23/23 ms both; MCP edit+save 316–323 vs
  324–327 ms). Peak native footprint 103.6–130.3 MB vs 102.3–133.5 MB: run-to-run
  variation (about ±30 MB) exceeds any difference. The editor's separate WebKit
  process is not included. The earlier path-specific gains do not show up at
  app level for these image-free drawings.
- Multi-window file events: the new subscriber test failed on build 131 code
  ("first window sees the change" unfulfilled, then hung) and passes now.
- AppState change check on a 6.6 MB scene: 33.3 → 19.5 ms median (15 runs).
- Full `script/test_local.sh`: 42 plugin, 62 editor, TypeScript, patch checks,
  **78 XCTest** and **26 Swift Testing** cases passed.

## Build 133: security, storage-growth fixes and measured gains (2026-10-19)

- Whole-codebase pattern sweep over all 722 Swift files (force casts and
  `try!`, force indexing, unique-key dictionaries, observers and timers,
  main-thread sync, static caches, file reads on the main actor), plus a review
  of the Quick Look extension and both loopback servers.
- Security: before the fix, `GET /%2e%2e/%2e%2e/Info.plist` and
  `/../../../../../../../../../etc/hosts` on 127.0.0.1:8497 returned 200 from the
  installed build 132. `ContainedDirectoryHTTPHandler` now rejects dot segments,
  NUL bytes and symlink escapes before the library handler runs.
- Checkpoint retention now deletes rows beyond 50 with their stored content;
  the earlier code only unlinked them, and the orphan cleaner treated unlinked
  rows as valid. Existing orphaned rows from earlier builds are not removed.
- Measurements on aMac, Release, identical benchmark source on both trees:
  unchanged recovery autosave of a 6.6 MB scene, 15 runs: build 131 median
  24.25 ms, build 132+ median 2.14 ms. Web-message sanitizer (standalone `-O`
  benchmark with the old and new code copied verbatim, Foundation payloads like
  WebKit's): sanitize plus serialize 2,000 elements 44.6 → 30.7 ms; sanitize
  alone 33.8 → 24.4 ms, retained extra heap 4.40 → 0 MB. Walking Foundation
  containers directly was tried and measured slower (31.2 ms), so it was not
  adopted. Preview cache fixture: 120 previews / 180 MB retained; after a
  pressure warning 32 / 48 MB; after critical 0.
- Full `script/test_local.sh`: 42 plugin tests, 62 editor tests, TypeScript,
  patch verification, **74 XCTest** (new: containment, checkpoint retention,
  preview pressure) and **26 Swift Testing** cases passed.
- Not measured: whole-app resident memory or frame time on real drawings.

## Build 132: crash hardening and bridge/memory optimizations (2026-10-19)

- Duplicate element, frame, slide and library-item IDs no longer trap in the
  presentation model, MCP presentation/library commands, local folder listing
  or Dropbox deltas. A stored document that is not a JSON object no longer
  crashes canvas persistence; the save writes a valid envelope instead.
- The web-to-native message sanitizer now copies only when it finds a
  non-finite number, instead of rebuilding every message node and formatting
  a path string per node. Unchanged recovery autosaves skip JSON validation and
  the old-copy re-read. Retained cover previews are released on memory-pressure
  warnings (all but 32) and critical events (all).
- A tried change that restored canvas keyboard focus after in-place saves was
  reverted: it changed the editor revision after MCP saves, which failed the
  native MCP acceptance check 4/4 times (baseline 4/4 pass). After reverting,
  the check passed 4/4.
- Full `script/test_local.sh` on aMac (macOS 27.0.1, Xcode 27.0): 42
  diagram-plugin tests, 62 editor tests in 11 files, TypeScript checking, patch
  verification, **69 XCTest cases** (including two new regressions for damaged
  stored content and recovery fingerprint caching) and **26 Swift Testing
  cases** passed. `script/test_stage_native_snapshot.sh` passed.
- Not measured: frame time or resident memory of large real-world drawings.
  The optimizations reduce work per message and per autosave; no benchmark
  figure is claimed.

## Build 131: Dock name and What's New branding

- The local fork's Debug and Release product name is now `ExcalidrawDesktop`.
  Xcode 27 ignored both a source-plist `CFBundleName` and an
  `INFOPLIST_KEY_CFBundleName` override while the product name remained
  `ExcalidrawZ`; the final change fixes the product name instead. The internal
  Swift module, executable, and build-output paths stay compatible with the
  existing installer and test host.
- A Release build on aLaptop (macOS 27.0.1, Xcode 27.0) passed **7 focused XCTest
  cases**. The built bundle reports `ExcalidrawDesktop` for both `CFBundleName`
  and `CFBundleDisplayName`; `NSRunningApplication.current.localizedName` also
  reports `ExcalidrawDesktop`.
- All 18 bundled languages pass the What's New title checks. A source comparison
  verifies that the localization edit changes only branding in 15 What's New
  keys (270 translated values).
- The actual SwiftUI What's New view rendered successfully in a disposable window
  behind the foreground app. Its captured preview was visually checked: the
  heading, logo and cover name show ExcalidrawDesktop. Automatic presentation,
  dismissal tracking and the Help notification handler are unchanged.
- The previously built editor's 469 asset hashes, editor patch and Swift lockfile
  matched this checkout before reusing those unchanged assets. No dependencies
  or embedded-editor code were upgraded.
- The two cable-schedule CSV changes preserve CRLF bytes; normalized CSV contents
  match their prior committed contents. Whitespace checks pass.
- Evidence on aLaptop: `/private/tmp/excalidraw-branding-131-tests-verified.log`
  and `/private/tmp/excalidraw-branding-131-whatsnew.png`. This is build and runtime
  validation in temporary output; installed Applications copies, other Macs and
  downloadable binaries were not updated during this change.

The supported validation target is an Apple Silicon Mac running macOS 27 with Xcode
27, using the local Release configuration. This record separates automated checks
from installed-app observations. It is not a notarization, App Store, or all-platform
release certification.

## Build 130: repository and local release readiness (2026-10-10)

Verified on the local Apple Silicon Mac with macOS 27.0.1, Xcode 27.0, and
Node.js 24.19.0. The embedded editor and Swift packages remain pinned.

- Restored the 16 missing Dropbox/OneDrive source files from the existing commit
  with the user's approval. Their bootstrap references remain intact; no cloud
  account was connected or configured.
- All 42 diagram-plugin tests, 62 editor tests in 11 files, and TypeScript checking
  passed. Exact editor/dependency patch verification and native source staging
  fixtures passed.
- The full native run passed 63 XCTest cases and 26 Swift Testing cases. Its one
  failed acceptance regression attempted to remove a nonexistent coordination
  file. Coordination-file cleanup now applies only to the opt-in client harness;
  the native regression owns a fresh UUID directory. The focused rerun passed
  the remaining XCTest case, covering native mutation, all four export formats,
  persistence, and undo. Total: 90 native checks passed across these runs.
- Rendered test fixtures stay behind the user's foreground app. They use in-memory
  stores and disposable scenes rather than opening user drawings.
- The installer passed a disposable-fixture check for the new release-cache
  location and refusal to replace an unrelated application.
- Release products and manifests now default to
  `~/Library/Caches/ExcalidrawDesktop/release`; generated builds are not copied
  into the iCloud source checkout. The existing ignored build cache was preserved.
- Source/documentation whitespace and relative Markdown link checks passed.
  Patch context whitespace is retained for exact reconstruction. PDF and Word
  artifacts are explicitly binary in Git. A credential-pattern scan of changed
  and new text files found no matches; this is not an exhaustive security audit.
- Release installation and runtime checks are recorded separately in the local
  release cache after committing these sources. The installed build manifest
  identifies the committed source and checksums used for that build.
- Independent Codex/Claude CLI acceptance was not rerun. The earlier pending
  Claude workflow recorded in `docs/MCP-acceptance.md` remains a separate gate.

## Build 129: icon and fork documentation

- The original Excalidraw vector mark is used for the new flat purple/charcoal icon.
  Icon Composer, legacy icon sizes, and the in-app branding image share that source.
- The README was rewritten from scratch for this fork; the upstream changelog was
  replaced with a fork changelog. Attribution and license notices remain.
- TypeScript checking and all **36 embedded-editor JavaScript tests** passed.
- Patch reconstruction and native snapshot staging fixtures passed. The editor and
  dependency checkouts match their recorded patches exactly.
- Relative documentation links resolve. No long verbatim lines from the original
  README remain. A credential-pattern check found no matches in changed text files.
- Release build succeeded. The first native run passed 40 of 41 checks but exposed a
  fixture startup race in image loading: the test used the JS API before the media
  store was ready. The fixture now waits through the same native readiness gate as
  the app; it no longer treats helper existence alone as readiness.
- The corrected rerun passed all **41 native checks** (38 XCTest and 3 Swift Testing).
  Build 129 was installed in Applications and relaunched. macOS NSWorkspace resolves
  the new purple Excalidraw mark on its charcoal icon background; Home loaded normally.
  No user drawing contents were edited during this validation.
- Local evidence: `excalidraw129-validation.log` retains the initial failure;
  `excalidraw129-final-validation.log` records the passing rerun and installation;
  `excalidraw129-editor-tests.log` records the JavaScript/type checks. These logs live
  under `/private/tmp` on the validation Mac and are not repository dependencies.
- Whitespace checks pass for source and documentation. Patch files retain their
  original context whitespace to preserve exact reconstruction; both patches passed
  the exact-source verification instead.

## Existing automated coverage

The build 130 focused native suite contains **64 XCTest cases and 26 Swift Testing cases**.
It covers autosave scheduling, persistence acknowledgement and retry, recovery-copy
replacement and retention, concurrent save boundaries, window binding/reparenting,
local feature policy, file opening, preview preparation, and embedded-editor behavior.

The real bundled editor is exercised for unsignalled edits at forced-save boundaries,
immediate scene changes, large argument transport, embedded images, standard
`.excalidraw` reopening, PNG/SVG export, and native PDF generation. Tests use disposable
scenes and temporary files rather than editing user documents.

Build 128 passed the complete native suite. Its high-refresh test used 1,000 rectangles
with off/on/off phases, recording median frame intervals of 17/8/17 ms. These are
animation callback intervals under synthetic camera motion, not display scanout or
end-to-end pointer latency. See [experimental high refresh](docs/EXPERIMENTAL-HIGH-REFRESH.md).

## Installed-app observations from the preceding builds

- Native import opened a standard drawing with its frame and web toolbar after the
  hosting-window observer and modal routing fixes.
- Rapid navigation, Home/Back, search, and sidebar transitions were exercised after
  replacing the affected split-view/toolbar composition.
- Image-bearing drawings reopened, export previews rendered, and document switching
  succeeded in the installed Applications copy.
- App-owned flat surfaces were checked in light and dark appearance. System file
  panels and alerts retain system styling.
- The experimental refresh switch was checked off → on → off through normal app
  restarts; persistence and restart reminders behaved as intended. The user reported
  a substantial smoothness improvement with the option enabled.

Detailed bounded observations and earlier measurements are recorded in
[AUTOSAVE.md](AUTOSAVE.md), [responsiveness](docs/EDITOR-RESPONSIVENESS.md), and
[preview/surface validation](docs/FLAT-SURFACES-VALIDATION.md).

## Remaining release limits

Developer ID signing, notarization, a full App Store archive, Intel and iOS builds,
sustained thermal/power testing, long-running crash soak, and every external storage
provider are outside this validation. Unsupported WebKit high-refresh behavior can
change with macOS updates and is compiled out of App Store builds. Autosave and
recovery do not guarantee preservation of edits made after the last completed save.

## Repeat the checks

Quit the installed app normally, then run:

```sh
./script/test_local.sh
./script/test_stage_native_snapshot.sh
```

`test_local.sh` rebuilds the pinned editor and stages the native test sources outside
the working tree. Keep the Mac unlocked so visible WebKit fixtures can render frames.

Fresh read-only review of the build-129 commit scope returned **ship**, with no
blocking findings. The review covered icon generation, fork documentation, license
retention, the readiness-fixture correction, and staged-file hygiene. This acceptance
does not expand the distribution or runtime coverage limits above.

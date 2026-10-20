# Changelog

This changelog covers the ExcalidrawDesktop fork. Historical ExcalidrawZ releases are documented in the [upstream repository](https://github.com/chocoford/ExcalidrawZ/releases).

## Unreleased

### Local build 142

- Drawing previews in the backup browser and History no longer keep the previous drawing's framing when another drawing is selected; rotated rectangles in these previews turn around their centre.
- A screen annotation that fails to save now shows an error instead of failing silently after the annotation window closed.

### Local build 141

- Fixed data loss when dragging a library drawing or group onto a linked folder with "also delete the original" checked. The original was permanently deleted even when the copy failed, and a drawing named with "/" or ":" was never written at all. The original is now deleted only after the copy is written.
- "Archive all files" no longer silently leaves out drawings whose names contain "/" or ":"; a file that cannot be written is reported.
- Fixed a crash on truncated or malformed `.excalidraw.png` files (linked folders, opening, Quick Look). Large `.excalidraw.svg` scenes decode much faster (300 KB payload: 0.73 → 0.05 s).
- Image export works for drawing names containing "/" or ":".
- Lighter Home and MCP listings: recent drawings scan each linked folder once instead of once per subfolder level, on every app activation. The PDF insert sheet no longer redraws every page thumbnail when an option changes.

### Local build 140

- Fixed crashes:
  - importing several files when no group is selected;
  - MCP tool calls with very large numbers (list_local_files `limit`, delete ids, camera sizes, adjust_elements `fontFamily`, canvas image sizes);
  - importing a library whose version number is out of range.
- Imported drawings no longer store embedded images twice. Importing several files now handles `.excalidraw.png`/`.excalidraw.svg` instead of storing image bytes as a broken drawing.
- MCP no longer accumulates memory or disk without limit: diagram checkpoints keep the newest 64 and request receipts the newest 256. Tool results attach only files the tools wrote to the temporary folder.
- Keyboard: Backspace anywhere in the app no longer removes the fonts selected in Fonts settings. Opening search no longer leaves a key monitor behind each time. Search ignores case and accents and no longer drops the last text typed during a search.
- PNG exports and shared/dragged drawings whose names contain "/" or ":" now produce a file.
- Faster panels: File History rows no longer decode every checkpoint on the main thread (840 KB drawing: 32 → 3.8 ms per row, in the background). The backup browser and checkpoint preview decode their file once instead of on every view update. The library panel no longer re-encodes every library on each view update.

### Local build 139

- Quitting no longer hangs on a Keychain prompt. After a rebuild, macOS asks before the app can read its backup key, and the quit-time backup waited for that answer indefinitely (seen as a quit that never finishes). Drawings and app data are saved first; the backup now gets at most 20 seconds, and the key is read once per launch instead of once per backed-up file.

### Local build 138

- Inserting a screen annotation into the drawing open in the editor no longer gets erased: the editor kept the old scene and wrote it back when you left the drawing. The open editor now reloads the saved document.
- Renaming, moving or trashing the open drawing in Finder no longer recreates it at the old path; the editor session closes as it does for a deletion.
- History saved by MCP, AI edits, restores and cloud providers for linked-folder and provider drawings is now capped at 50 per drawing. Before, every MCP edit stored two full copies of the drawing in the app database and nothing was ever removed.
- A drawing snapshot that arrives with a missing piece now fails instead of saving a truncated document; snapshot pieces are applied strictly in the order the editor sends them.
- Faster saves for large library and cloud drawings: each autosave no longer parses and re-encodes the whole document to move the view position aside and set the file name (5.8 MB drawing: 114 + 78 ms → 5.6 + 5.6 ms); opening restores the view position in 5.5 ms instead of 77 ms; style changes are checked in 5 ms instead of 36 ms; the view-position file is rewritten only when it changes.
- Cover previews for linked PNG and SVG drawings are decoded off the main thread; background sync checks no longer start duplicate probes.

### Local build 137

- Fixed a launch hang: at startup the app listed MCP clients by decrypting each stored client secret from the Keychain on the main thread. After a rebuild macOS asks for Keychain access, and the app froze before showing a window. Clients are now listed in the background from non-secret Keychain attributes; secrets are read only when a client authenticates.

### Local build 136

- Viewing a drawing no longer rewrites it: closing or switching away used to always rewrite the file, bump its modified date (reordering an "updated" sort) and add a duplicate File History checkpoint that pushed real history out. Unchanged drawings are now left alone; edits, including ones not yet signalled, are still saved.
- Moving or renaming the open drawing inside the app no longer recreates it at the old path; pending edits follow the move to the new file.
- Duplicating a drawing in a sub-folder could overwrite an existing "Name-1" there; trashing an open drawing or a folder containing it could write the drawing back. Both fixed.
- Quitting with several windows open now saves every window's drawing, not only the most recent window's.
- Restoring a file from Recently Deleted returns it to its original group instead of always the default group.
- Fixed a data race in the editor's update-gate timer (it ran on a background queue but read main-thread state).
- Opening a PNG or SVG image file no longer inserts the image twice.
- Exporting a drawing whose name contains "/" or ":" no longer produces a missing file; replacing a backup export or today's automatic backup is now atomic, so a failed replacement keeps the previous copy.
- Faster and lighter: closing a large drawing is about 20% faster (991 KB: 145 → 119 ms); the document is no longer parsed on the main thread at every open; library saves no longer load every image in the library or JSON-decode documents just to detect encryption; local autosaves no longer load every History checkpoint; iCloud linked folders re-check only changed files; sync status lists publish only on change; a closed file's state is released.

### Local build 135

- Fixed a data race on the linked-file ID table: it was changed from background folder refresh, cover rendering and imports while the main thread used it. A linked-folder rename during a refresh could corrupt it and crash. Access is now lock-protected, with atomic lookups and moves.

### Local build 134

- Fixed linked-folder change events with more than one window: a second window replaced the first window's subscription, and closing any subscriber silenced every window, so the sidebar stopped reflecting external file changes. A second window also showed an "already monitoring" error, and closing one window stopped monitoring for the other.
- File writes, deletes, moves and trashing no longer block the shared file actor and a Swift concurrency thread while macOS coordinates access; they run on one ordered queue.
- Style and preference changes no longer rebuild and re-serialize the whole document just to detect a change (6.6 MB scene: 33.3 → 19.5 ms per check).

### Local build 133

- Security: the embedded editor's loopback server (port 8497) served any file the user could read through `%2e%2e` path segments. Requests are now confined to the bundled editor folder, including symlinks.
- Fixed unbounded File History storage growth: checkpoints beyond the newest 50 were only unlinked, never deleted, so their rows and stored content accumulated. They are now deleted with their stored content.
- Quick Look previews of unreadable files now show the error instead of spinning forever.
- Fixed another crash on damaged stored document content in the library save path.
- Measured gains: unchanged recovery autosave of a 6.6 MB drawing 24.3 ms → 2.1 ms; web-message sanitizing about 31% faster with no duplicate copy (4.4 MB less transient heap for a 2,000-element message); memory pressure releases up to 180 MB of pinned previews in the test fixture.

### Local build 132

- Fixed crashes when a drawing, presentation configuration, or library repeats an element, frame, or item ID; the first entry is used.
- Fixed a crash when a stored document is damaged or not a JSON object; the next canvas save writes a valid document instead of failing every save.
- Reduced per-message work in the web-to-native bridge: messages are no longer copied node by node to check for non-finite numbers.
- Unchanged autosaves now skip JSON validation and re-reading the previous recovery copy.
- Retained cover previews are released under system memory pressure instead of staying pinned at up to 192 MB.
- Keeps the editor open on drawings renamed inside a linked folder.

### Local build 131

- Fixed the macOS bundle name so the running app identifies as ExcalidrawDesktop in the Dock.
- Rebranded What's New titles and feature text in all 18 languages, and replaced the macOS cover screenshot that contained the old name with the fork's logo and name.
- Kept the automatic What's New pop-up and its Help menu entry.
- Preserved CRLF line endings in the two cable-schedule CSV exports.

### Local build 130

- Added authenticated, loopback-only MCP transport, complete diagram and document commands, durable mutation receipts, and visible MCP activity.
- Added packaged design, network, and electrical diagram plugins, editable examples, and UI style guidance.
- Preserved asset extension metadata during document hydration and covered persistence and editor regressions.
- Moved completed release products and their manifests to a machine-local cache outside the iCloud source checkout.

### Fork identity and distribution

- Renamed the installed app and local data identity to ExcalidrawDesktop without replacing an installed upstream ExcalidrawZ app.
- Disabled iCloud database sync, upstream automatic updates, cloud AI, subscription prompts, and online collaboration for the local macOS build.
- Added reproducible native/editor source staging, pinned dependency reconstruction, patch verification, and build manifests describing the exact staged sources and bundled editor assets.
- Added an Applications install flow that refuses to replace a running copy so pending saves can finish normally.

### Editor and macOS interface

- Restored the embedded Excalidraw desktop toolbar, property controls, menus, library, help, and keyboard behavior at desktop sizes.
- Reworked the macOS navigation shell to avoid the split-view toolbar constraint loop seen during rapid document, Back, and Search transitions.
- Added a native app menu and drawing menu while preserving the editor's own canvas controls.
- Replaced translucent app-owned surfaces with an opaque Excalidraw-inspired palette and consistent purple hover, focus, and action treatments.
- Added fork-specific Excalidraw branding assets and app icon treatment while preserving required license notices.

### Local features

- Separated local feature eligibility from cloud AI and subscription state.
- Kept presentation available in the local fork.
- Kept MCP opt-in and local, with file/edit-lock checks and built-in tool descriptions and schemas when upstream resources are unavailable.
- Removed cloud-AI controls and home-page promotion from the local workflow.

### Autosave, switching, and recovery

- Added coalesced autosave with bounded scheduling, serialized content saves, retained dirty state after failures, and visible save status.
- Made document switching and normal termination wait for a full snapshot persisted to the captured current target.
- Added a shared flush gate so concurrent switch/quit boundaries cannot acknowledge or overwrite one another out of order.
- Added current and previous complete recovery copies for ordinary local and temporary documents, including embedded image data, with bounded retention and atomic replacement.
- Kept managed library documents, including locked encrypted documents, on their existing repository, history, and encryption path rather than writing extra plaintext recovery copies.
- Kept the editor renderable under its loading cover so frame-dependent loading can complete reliably.

### Import, previews, and performance

- Fixed macOS window binding and import routing across modal teardown and view reparenting, including readable local file URLs.
- Prevented dropped library content from navigating the embedded WebView away from the editor.
- Moved ordinary document parsing and preview preparation off the main actor, reused unchanged scene bytes, and preserved serialized rendering and cancellation guards.
- Replaced very large decimal JavaScript byte literals with argument-based JSON/base64 transport for document loading.
- Removed automatic camera notifications; camera reads remain exact on demand and the compatibility tracking API remains available.
- Reduced bridge payload work for viewport-only changes and kept full snapshots at file-switch and close boundaries.
- Moved folder enumeration and metadata sorting to a private Core Data queue with debounced refresh and stale-result rejection.

### Experimental high refresh rate

- Added a default-off direct-distribution macOS setting that can relax WebKit's near-60-FPS preference for interactive editors.
- Applied the selection only at process startup; changing it shows a restart reminder and does not interrupt the current editor or save flow.
- Excluded the setting and private WebKit selector from `APP_STORE` builds. The option is unsupported, may stop working after an OS update, and does not guarantee 120 FPS.

### Validation and documentation

- Added focused native and embedded-editor coverage for persistence, recovery, save boundaries, document opening, window binding, feature policy, preview preparation, image export, and standard-file reopening.
- Added bounded performance fixtures and documented their limits.
- Added fork-specific build, validation, autosave, responsiveness, surface, and high-refresh documentation.

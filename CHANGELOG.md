# Changelog

This changelog covers the ExcalidrawDesktop fork. Historical ExcalidrawZ releases are documented in the [upstream repository](https://github.com/chocoford/ExcalidrawZ/releases).

## Unreleased

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

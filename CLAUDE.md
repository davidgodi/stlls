# STLLS — working rules

STLLS is an iOS app: a single-file vanilla-JS web app (`story-layout/index.html`, ~15k lines) running in a WKWebView with a Swift shell (`Stlls/Stlls/ContentView.swift`). No frameworks, no build step for the web layer.

## The sync workflow (every web change)
`story-layout/index.html` (in the parent folder, `Desktop/Coding/story-layout/`) is canonical. After editing it:
```bash
cp ../story-layout/index.html Stlls/web/index.html && cp ../story-layout/index.html index.html
```
Both copies must be committed together — `Stlls/web/index.html` is what ships in the app.

## Git
- The remote is named **`STLLS`**, not `origin`: `git push STLLS main`.
- End commit messages with the co-author trailer for the current Claude model.
- **V1.4 App Store release archives from tag `v1.4-cut`, never from main** (carousel-only release; main has unreleased subscription + grid work).
- Never commit API keys/secrets into `index.html` — the repo is public and the file ships inside the .ipa. Newsletter/API integrations go through a serverless proxy.

## Building & verifying Swift
```bash
xcrun -sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios16.0-simulator Stlls/Subscription.swift Stlls/StllsApp.swift Stlls/ContentView.swift
xcodebuild build -scheme Stlls -destination 'generic/platform=iOS Simulator' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```
Deployment target is iOS 16.0 — check API availability (e.g. `transaction.offerType`, not `.offer` which is 17.2+). Use the SDK typecheck, not `-parse`; plain parsing misses availability errors.

### Hand-editing project.pbxproj
Collision-check every new 24-hex object ID with grep before inserting (a reused ID once corrupted the project). Validate with `xcodebuild -list` + a full build — `plutil -lint` passes on semantically broken files. Scheme `BuildableReference` needs `BuildableIdentifier = "primary"`.

## Testing the web layer in the browser pane
- Load `story-layout/index.html` as file:// and **force-navigate after every edit** (hard caching).
- The pane suspends CSS animations and rAF while backgrounded: flows gated on `animationend` (screen transitions, e.g. opening a project) hang — dispatch `new AnimationEvent('animationend')` on the element to force them. Verify animation end-states, not playback.
- Synthetic `PointerEvent`s work, but `setPointerCapture` throws on fake pointerIds — wrap it in try/catch in gesture code (also protects real edge cases).
- Synthetic `.click()` lacks `pointerdown` — coaches dismiss on pointerdown, so drive those with PointerEvents.
- Stub the native bridge as needed: `window.webkit = { messageHandlers: { name: { postMessage } } }`.

## Recurring web-layer traps
- `[hidden]` loses to any `display:flex/block` rule — every overlay needs a `#id[hidden] { display:none !important }` companion.
- Shared CSS classes are global (`.car-chip`, `.car-tool`, `.car-addphoto`…). `.car-addphoto` in particular carries carousel-specific absolute positioning — override per screen when reusing.
- Fullscreen editors add a body class (`car-open`, `grid-open`) that hides the board editor's chrome (`header`, `.workspace`, `#timelineBar`, `#psExport`) — a new fullscreen screen must do the same or the board's fixed export bar bleeds through.
- Reset gesture state at every overlay boundary and on `visibilitychange` — stale pointers break scrolling/dragging after backgrounding.
- Canvas-drawn UI: percentage-positioned absolute children measure against the padded box; account for reserved bands (see `#gridStage` padding vs `#gridEmptyBtn` centering).

## Pro gating (freemium)
- Native pushes `window.STLLS_PRO` into the web layer; **undefined means unlocked** (browser dev / Pro disabled), only explicit `false` locks.
- Gate exports with `if (!stllsIsPro()) { stllsAskPro(); return; }` at the top of the handler. `stllsAskPro()` → upsell card; `stllsOpenOffer()` → paywall directly.
- Free tier: photo-board exports free; carousel/grid/video exports are Pro. Editors and previews are never gated — the preview is the funnel.
- `StllsPro.debugForcePro` (Subscription.swift) force-unlocks everything for dev. It must be `false` for paywall testing and **must never be archived true**.

## Editor conventions (when adding a new tool)
Mirror the carousel/grid pattern: `#xScreen` fixed z-150 with `car-top` header (STLLS brand, home button, undo chip, gear) + `car-sub` label; project `kind` in the shared IDB `projects` list + `openProject()` routing; 30-step snapshot undo with the board-style dropdown; divider-as-progress export line (`carExportProgReset` is reusable); export to Photos via sequential `exportImage` messages with ~350ms gaps; first-time coach chain via `setupCoach`/`showCoach` with guides + scrim inside the screen's stacking context (targets lifted to z-211 via per-step body classes; arrows are auto-aimed by `positionCoach`).

## Product rules
- Push notifications: never between 22:00–08:00 local (quiet hours).
- Home-screen animations must be pure CSS keyframes on the `.nt-*` buttons, scaled as a unit via a parent transform when resized.

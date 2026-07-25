# Handoff — STLLS Pro freemium, onboarding redesign, Social Media Grid tool

**Session span:** July 19–20 2026 · **Last commit:** `bf97cc8` · **Branch:** `main` (remote is named `STLLS`, not `origin`)

## Where things stand

Three major arcs landed this session, all pushed and building green:

### 1. STLLS Pro subscription → freemium model
- All subscription logic lives in `Stlls/Stlls/Subscription.swift` (StoreKit 2, no server): entitlement engine (grandfathered / entitled / locked + Keychain cache), 4-step onboarding, paywall, trial reminder.
- **Model is freemium** (supersedes the spec's hard paywall §3.4): the paywall X drops the user into a free tier. Free = everything usable except **exports** of carousels, grids, and video-clip boards (photo-board exports stay free).
- Launch order: **onboarding first** — the shell injects `STLLS_HOLD_SPLASH` (WKUserScript, documentStart) so the web opening animation pauses on frame one; `stllsReleaseSplash()` fires when the offer resolves (X / purchase / already entitled).
- Web↔native bridge: shell pushes `window.STLLS_PRO` (didFinish + CombineLatest on state/paywallDismissed); web gates call `stllsAskPro()` → `showPaywall` message → native upsell card ("That's a Pro feature!" over blurred scrim, CTA → offer). Home PRO capsule posts `showOffer` → straight to the paywall.
- Onboarding design: STLLS identity — story-style step bar, left-aligned editorial slides, orange→yellow title gradients, blue capsule CTAs (label left / arrow right), dark backdrop with drifting white frames (masked to ~28% behind the text band), trial timeline on slide 3, App Store screenshots fanned in phone frames on the offer.
- ⚠️ **`StllsPro.debugForcePro = true` right now** (David wanted the app fully Pro during dev). Set `false` before any paywall testing and NEVER archive with it true. Same for archiving while `StllsPro.enabled = true` before ASC products exist (archives ignore the scheme's `.storekit` config).
- Pending: David creates the ASC subscription group "STLLS Pro" + monthly/yearly products with 7-day intro offers; then Stage 1 (.storekit) → Stage 2 (sandbox) → Stage 3 (TestFlight) per the spec in `Subscription integration/`. `freemiumCutoffBuild` is still the 999999 placeholder — must be set to the freemium release's build number before that archive.

### 2. Social Media Grid tool (spec: `~/Downloads/social-media-grid-spec.md`)
Built entirely in the web layer (`story-layout/index.html`), not the spec's SwiftUI sketch — zero Swift changes needed. Third project type on the home screen (animated 3×3 button, tiles pop in posting order).
- **Math (source of truth):** IG uploads 4:5 (1080×1350), grid thumbs crop to 3:4 → visible cell 1012.5×1350, bleed 33.75/side. Tiles cut from VISIBLE geometry + bleed → one tile's bleed is its neighbour's visible artwork → seamless. Native 3:4 mode (1080×1440, no bleed) behind the 4:5/3:4 chip. Floats everywhere; edges snap at raster only. Posting order: bottom-right = post_1 … top-left = post_N.
- **Reels:** per-tile marking (Reels chip → tap tiles). Reel tiles export as 9:16 covers (1080×1920): visible cell maps to the centre 3:4 window at `1080/cellW` (16/15 in 4:5 mode), ~240px hidden top/bottom. Seam pixel-verified against post neighbours.
- Editor: single image, drag/pinch/wheel (cover-clamped), 1×3/2×3/3×3 with JS-driven uniform morphs (image lerps between cover-fit placements — never squeezed; guides redraw crisp per frame), Guides overlay, undo/redo (30 steps + Cmd-Z), tap-to-select → accent frame + Delete, empty-state accent + circle, upload-guide modal after export, 4-step coach tour, IDB persistence (kind `'grid'`).
- Removed by David: profile-preview modal; gap slider (geometry still supports `grid.gap` — it compensated IG's rendered gutter spacing; reintroduce if seams kink on a live profile).
- Pending: on-device pass (gestures, 9-tile sequential Photos saves), "STLLS Grid" named Photos album (needs small Swift addition), v1.1 = STLLS layouts as grid source.

### 3. Home screen
Three project types (Board / Carousel / Grid) as smaller buttons, content-flow layout (no more centered-overflow collisions), free-tier note + PRO capsule (free tier only), `:has()`-conditional spacing for Pro users.

## V1.4 App Store release — IMPORTANT
V1.4 ships **carousel only**. Archive from tag **`v1.4-cut`** (`9003865`), NOT main — main has subscription + grid. Bump version/build on a branch from the tag. See memory `project_stlls_v14_release`.

## Verification status
- Web: everything verified in the browser pane (spec constants, seam pixel-identity, posting order, gating, persistence round-trips, coach arrow aim).
- Swift: typecheck + full simulator builds green throughout.
- NOT yet verified on device: grid gestures/exports, onboarding animation feel, upsell card spring.

## Gotchas discovered this session
- Browser pane suspends CSS animations AND requestAnimationFrame when backgrounded: `animationend`-gated flows never fire (dispatch `AnimationEvent` manually) and rAF loops don't run — verify end-states, not animation playback.
- `setPointerCapture` throws on unknown pointerIds (synthetic events) — it's wrapped in try/catch in the grid editor; do the same for new gesture code.
- Shared `.car-*` CSS classes are global: `.car-addphoto` carries `position:absolute` tuned for the carousel stage — override per-screen when reusing.
- The pane's file:// page caches hard — always force-navigate after edits.
- `sips` + a threshold floor (maxChannel ≤ ~40 → alpha 0, ramp above) is the pattern for keying near-black logo backgrounds to transparent.

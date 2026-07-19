# STLLS × Instagram — direct publishing (SCRL-style)

Status: **scaffold** — nothing here ships in the app yet. The app today has the
zero-requirement shortcut (post-export "Open Instagram ↗" button). This folder
holds everything needed to build the full "Connect to Instagram" feature:
account connection + publishing photos/carousels/stories straight from STLLS.

## How SCRL-style publishing actually works

Meta's **Instagram API with Instagram Login** allows apps to publish on behalf
of **Professional accounts only** (Business or Creator — that's why SCRL shows
"I don't have a Creator or Business account"). Personal accounts cannot be
posted to via API, period. Key constraints:

- Media must be fetched by Meta from a **public HTTPS URL** — you cannot push
  bytes directly. So STLLS needs temporary public hosting for exports
  (the worker below uses Cloudflare R2 with short-lived keys).
- Images must be **JPEG** (the publish endpoint rejects PNG). The publish flow
  should always export JPG regardless of the user's Format setting.
- Feed aspect ratios 4:5 … 1.91:1 (STLLS's 4:5 and 1:1 are both fine).
- Carousels: up to 10 children; Stories are supported (`media_type=STORIES`).
- API publishing is rate-limited per account per 24 h (historically 25 posts —
  verify the current number in Meta's Content Publishing docs).
- Tokens: short-lived → exchange for long-lived (~60 days) → refresh before
  expiry. Store only in Keychain on device; the exchange/refresh must happen
  server-side because they require the **app secret**.

## One-time setup (David)

1. **Meta developer app** — developers.facebook.com → Create App → add the
   "Instagram" product → *API setup with Instagram login* (business login).
   Note the Instagram App ID + App Secret.
2. **Redirect URI** — add the worker's `/callback` URL (below) to the app's
   OAuth redirect URIs.
3. **App Review (Meta)** — request `instagram_business_basic` and
   `instagram_business_content_publish`. Requires: privacy policy URL
   (see PRIVACY-ADDITION.md — publish it first), a screencast demoing the
   flow, and a test business account. Until approved, only accounts added as
   testers on the Meta app can connect.
4. **Cloudflare Worker + R2** — `wrangler deploy` `worker.js` with:
   - vars: `IG_APP_ID`, `APP_REDIRECT` (e.g. `stlls://ig-connected`)
   - secrets: `IG_APP_SECRET` (`wrangler secret put IG_APP_SECRET`)
   - R2 binding: `MEDIA` (bucket with a lifecycle rule deleting objects after 1 day)
   NEVER put the secret in index.html — it ships inside the .ipa.

## App-side work (when the above exists)

- Settings → "Instagram" section: Connect button → open
  `https://<worker>/auth` in `ASWebAuthenticationSession`; the callback
  deep-links `stlls://ig-connected#token=…&user_id=…&expires=…` back into the
  app (add the `stlls` URL scheme to Info.plist). Store token in Keychain,
  mirror connection status to the web layer.
- Export flow: when connected, "Share to Instagram" next to Export →
  re-render frames as JPG → POST to worker `/media` → worker `/publish`
  (feed single / carousel / story) → success toast with a link to the post.
- Token refresh on app launch when < 10 days remain.

## App Store Connect checklist (next release with this feature)

- **Privacy labels**: add *Photos or Videos* (user content, uploaded for
  publishing) and *User ID* (Instagram account id/username) — both
  "Linked to you", shared with Meta. Auth tokens count under identifiers.
- **Privacy policy** at davidgodi.github.io/stlls-privacy must include the
  Instagram section (PRIVACY-ADDITION.md) BEFORE submission — Meta review and
  Apple review both check it.
- **Sign in with Apple is NOT required**: guideline 4.8 applies to third-party
  *login for using the app*; connecting a social account purely for publishing
  is exempt. Keep the connection optional and the app fully usable without it.
- **App Review notes**: provide a demo Instagram Business account + steps, or
  reviewers can't exercise the feature.
- **No ATT prompt needed** — no cross-app tracking is involved.
- Info.plist: the `stlls` custom URL scheme addition rides along
  (`LSApplicationQueriesSchemes` already contains `instagram` for the shortcut).

## Already shipped (no requirements, no policy impact)

The post-export "Open Instagram ↗" button (carousel editor) deep-links into
the Instagram app with the fresh export already in the camera roll — no
account connection, no data leaves the device, so the current privacy policy
and labels stay valid for that.

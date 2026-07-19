# STLLS — Subscription Onboarding & Trial Spec (v2)

**Supersedes:** `STLLS_Trial_Paywall_Migration.md` (app-level 14-day trial model is dropped)
**Model:** Free download → onboarding paywall → 7-day free trial that **starts the subscription** (Apple introductory offer, auto-renews unless cancelled) → $4.99/month or $29.99/year
**Reference flow:** SCRL's onboarding (screenshots in project folder). Copy the structure, not the visuals — STLLS keeps its own dark UI language.
**Stack:** SwiftUI, StoreKit 2, on-device only. No server, no RevenueCat.

---

## 1. Why this model (context for future reference)

- Download button stays **"Get"** → app remains in the **free** charts. Subscriptions/trials do not affect chart placement.
- Trial starts the subscription itself (Apple intro offer) → opt-out economics, the highest-converting trial type (~48–60% trial-to-paid benchmarks).
- Apple enforces **one intro offer per Apple ID per subscription group** → trial-reset abuse (delete/reinstall) is impossible by design. No custom tracking.
- Trial-reminder notification (SCRL-style) builds trust, increases trial starts, reduces refunds/chargebacks. Apple also sends its own renewal emails; ours arrives earlier and in-app.

## 2. Products & App Store Connect

Subscription group: **STLLS Pro**
- `is.skjaskot.stlls.pro.monthly` — $4.99/month, intro offer: **7 days free**
- `is.skjaskot.stlls.pro.yearly` — $29.99/year, intro offer: **7 days free**

Configure the introductory offer on **both** products (type: Free, duration: 1 week). Eligibility is automatic via StoreKit (`product.subscription?.introductoryOffer` + `isEligibleForIntroOffer`).

Family Sharing: enable. Localized names/descriptions. **App price unchanged until release day** (see §7).

## 3. Onboarding flow (screen by screen, mirrors SCRL)

New users only (entitlement != grandfathered/subscribed). Full-screen sequence on first launch:

**Screen 1 — Trial intro**
- STLLS wordmark top center. Centered headline: "We want you to discover **STLLS Pro**, so here's a **7-day free trial** on us." (trial phrase in accent color)
- Single CTA: **Continue**. No skip.

**Screen 2 — Notification permission (pre-prompt)**
- Headline: "Allow notifications to get your reminder"
- Mock system-dialog illustration with arrow pointing at "Allow" (SCRL pattern), footer "Turn off notifications at any time", CTA **Continue** → triggers real `UNUserNotificationCenter` authorization request.
- If denied: continue flow normally; skip §5 scheduling.

**Screen 3 — Reminder promise**
- Illustration: iPhone mock showing a notification: "**STLLS Pro** — Your free trial will renew in 2 days unless cancelled before."
- Headline: "We'll remind you 2 days before your trial ends." CTA **Continue**.

**Screen 4 — Paywall (the offer screen)**
- Background: full-bleed brand imagery (photographer/work imagery, dark gradient overlay).
- Title: "Welcome Offer" + subtitle "Enjoy full access with STLLS Pro"
- Checklist: ✓ 7-day free trial ✓ All features and layouts ✓ Cancel anytime from the app
- Plan cards:
  - Monthly — `displayPrice` per month (unselected default)
  - **Yearly — preselected**, badge "SAVE 50%", shown as per-month equivalent + yearly price in parentheses: "$2.50 per month ($29.99 per year)". Compute the per-month equivalent from `Product.price / 12`, formatted with the product's `priceFormatStyle` — never hardcoded.
- CTA: **Try For Free** → `product.purchase()` → Apple's native sheet shows "1-week free trial, starting today / $X per year starting <date>".
- Footer: "Renews automatically. Cancel any time." + Restore Purchases + Terms + Privacy links (App Review requirements).
- **Close (X) button**: required consideration. Decision: X is visible after a 1–2s delay (review-safe, standard practice). Tapping X exits onboarding into **locked state** (§4). Reopening the app returns to the paywall. No feature access without an active trial/subscription — this is still a hard paywall; the X just avoids trapping the user in a purchase sheet loop.

**Post-purchase:** flow dismisses, app opens normally. Schedule reminder (§5).

## 4. Entitlement engine (simplified from v1)

Resolution order:
1. **Grandfathered** — `AppTransaction.shared.originalAppVersion` < `FREEMIUM_CUTOFF_VERSION` → full access forever, zero subscription UI. (Fallback consistency check: `originalPurchaseDate`.)
2. **Subscribed / in trial** — any verified transaction in `Transaction.currentEntitlements` for the group (a free-trial period IS a normal transaction — no separate trial logic needed).
3. **Locked** — everyone else → onboarding/paywall.

Listen to `Transaction.updates` for the app's lifetime. Cache last entitlement in Keychain for offline launches. Handle refunds/revocation (drop to locked). No trial-date math anywhere — Apple owns the trial.

## 5. Trial reminder notification

- On successful purchase where the transaction's offer type == introductory: schedule a **local notification** at `purchaseDate + 5 days`:
  - Title: "STLLS Pro" — Body: "Your free trial will renew in 2 days unless cancelled before."
- On `Transaction.updates`: if `RenewalInfo.willAutoRenew == false` (user cancelled during trial), remove the pending notification.
- If notification permission was denied, skip silently.

## 6. UI/UX requirements

- All prices from StoreKit `displayPrice` / `priceFormatStyle` (ISK, EUR, etc. must localize).
- Paywall must render correctly in en + is; snapshot-test both.
- Purchase states: loading, success, `userCancelled` (stay on paywall, no error), pending (Ask to Buy), failure (toast).
- Restore Purchases on paywall (mandatory).
- Grandfathered users: never see any of this. Optional one-time thank-you row in Settings.

## 7. Rollout sequencing (unchanged from v1 — order still critical)

1. Submit this version **while the app is still paid**; review notes explain paid→subscription migration + grandfathering via `originalAppVersion`.
2. Manual release, phased release OFF.
3. Release day: publish + set price to **Free** in the same sitting.
4. `FREEMIUM_CUTOFF_VERSION` must equal this release's version string. Verify before archiving.

## 8. Testing — three stages, in order

### Stage 1 — Xcode StoreKit Configuration file (local, simulator, day-to-day dev)
- `.storekit` config file with both products **and their 7-day intro offers**. No network, no accounts, full control.
- Use Xcode's Transaction Manager to: purchase with trial, cancel mid-trial (`willAutoRenew` flips → reminder notification must cancel), force trial→paid renewal, refund/revoke (entitlement must drop to locked), Ask to Buy (pending state), interrupted purchases.
- Time control: set subscription renewal rate to accelerated so a full trial→renewal→renewal cycle runs in minutes.
- Intro-offer ineligibility: simulate a previously-used offer → paywall must degrade "Try For Free" → "Subscribe" when `isEligibleForIntroOffer == false`, and the Apple sheet must not promise a trial.
- Grandfathering: mock old `originalAppVersion` → full access, no onboarding ever shown.

### Stage 2 — Sandbox on a real device (App Store sandbox environment)
- Create 2–3 **Sandbox Apple IDs** in App Store Connect (Users and Access → Sandbox Testers). Sign in on device under Settings → App Store → Sandbox Account. Real products from App Store Connect are used — this validates the ASC configuration itself, which Stage 1 cannot.
- Sandbox compresses time automatically: the 7-day free trial ≈ 3 minutes, monthly ≈ 5 minutes, yearly ≈ 1 hour; subscriptions auto-renew up to 6 times then expire. A complete trial→convert→renew→expire lifecycle takes under an hour.
- Use ASC sandbox tester controls between runs: **clear purchase history** (resets intro-offer eligibility so the same tester can re-test the trial path), change renewal rate, test billing retry/grace period toggles.
- Verify on-device: real Apple purchase sheet shows "1-week free trial / then price", cancel flow via Settings → Subscriptions (sandbox), Restore Purchases with a second sandbox account, notification actually fires (temporarily schedule at +60s instead of +5 days via a debug flag).

### Stage 3 — TestFlight round (production-like, 1–2 weeks before submission)
- Internal testers first (you + 2–3 trusted people), then a small external group if desired.
- TestFlight purchases are free and don't charge testers' real Apple IDs; intro offers and renewals run in a compressed sandbox-like environment, renewing up to 6 times.
- This stage validates what the earlier stages can't: the **real onboarding funnel on fresh installs** — notification permission prompt, paywall rendering across device sizes and locales (en + is), the full SCRL-style flow ordering, and the grandfathering check against a testers' device that had the old paid build installed (install old build from TestFlight history → update → must be grandfathered).
- Exit criteria before submission: zero paywall dead-ends, trial reminder verified, restore works, no way into the app without trial/subscription/grandfathering, analytics events all firing.

**Timeline guidance:** Stage 1 continuous during development; Stage 2 ~2–3 days; Stage 3 ~1 week minimum. Budget ~2 weeks of testing after code-complete before submitting.

## 9. Analytics (minimum)

`onboarding_started`, `notification_permission` (granted/denied), `paywall_shown`, `trial_started` (plan), `trial_cancelled`, `trial_converted`, `purchase_failed`, `restore_completed`. Core metric: trial start rate (installs→trials) × trial-to-paid rate. Benchmarks to beat: 40%+ trial-to-paid for opt-out trials.

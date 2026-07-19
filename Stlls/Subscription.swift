import SwiftUI
import StoreKit
import UserNotifications
import Security

// ═══════════════════════════════════════════════════════════════════════════
// STLLS Pro — subscription onboarding, paywall & entitlements
// Implements Subscription integration/STLLS_Subscription_Onboarding_Spec.md:
// free download → onboarding → 7-day free trial (Apple intro offer) →
// $4.99/mo or $29.99/yr. StoreKit 2, on-device only.
// ═══════════════════════════════════════════════════════════════════════════

enum StllsPro {
    /// MASTER SWITCH — Stage 1 testing is ON: the shared scheme selects
    /// StllsPro.storekit, so every Xcode run (simulator or device) uses local
    /// fake products. ⚠️ Do NOT archive for TestFlight/App Store while this is
    /// true until the App Store Connect products exist — archive builds ignore
    /// the scheme's StoreKit configuration and would show a dead paywall.
    static let enabled = true

    static let monthlyID = "is.skjaskot.stlls.pro.monthly"
    static let yearlyID  = "is.skjaskot.stlls.pro.yearly"
    static let productIDs: Set<String> = [monthlyID, yearlyID]

    /// §7.4 — grandfathering cutoff. CRITICAL: on iOS,
    /// `AppTransaction.originalAppVersion` is the original BUILD number
    /// (CFBundleVersion, an integer in this project — currently 4), NOT the
    /// marketing version. Set this to the first freemium release's build
    /// number and verify before archiving that release.
    static let freemiumCutoffBuild = 999_999   // TODO: set to the freemium release build

    /// Debug: fire the trial reminder 60 s after purchase instead of +5 days
    /// (Stage 2 sandbox verification, spec §8).
    static let debugFastReminder = false

    static let privacyURL = URL(string: "https://davidgodi.github.io/stlls-privacy/")!
    static let termsURL   = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static let accent = Color(red: 0.30, green: 0.62, blue: 1.0)   // #4d9fff
    static let bg     = Color(red: 0.04, green: 0.04, blue: 0.04)
}

// Console-only analytics per spec §9 (on-device, no server).
enum SubAnalytics {
    static func log(_ event: String, _ props: [String: String] = [:]) {
        print("📊 \(event)\(props.isEmpty ? "" : " \(props)")")
    }
}

// MARK: - Entitlement engine (spec §4)

enum EntitlementState: String {
    case unknown, grandfathered, entitled, locked
}

@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore()

    @Published private(set) var state: EntitlementState = .unknown
    private var updatesTask: Task<Void, Never>?

    func start() {
        guard StllsPro.enabled else { state = .entitled; return }
        state = KeychainCache.readState() ?? .unknown   // offline-friendly boot
        Task { await resolve() }
        // Listen for the app's lifetime: renewals, cancellations, refunds,
        // Ask to Buy completions.
        updatesTask = updatesTask ?? Task {
            for await update in Transaction.updates {
                if case .verified(let t) = update { await t.finish() }
                await resolve()
                await TrialReminder.sync()
            }
        }
    }

    func resolve() async {
        // 1. Grandfathered — bought while STLLS was a paid app.
        if let result = try? await AppTransaction.shared, case .verified(let appTx) = result {
            let originalBuild = Int(appTx.originalAppVersion.split(separator: ".").first.map(String.init) ?? "") ?? .max
            if originalBuild < StllsPro.freemiumCutoffBuild {
                set(.grandfathered)
                return
            }
        } else if KeychainCache.readState() == .grandfathered {
            // AppTransaction unavailable (offline first check) — trust the cache.
            set(.grandfathered)
            return
        }

        // 2. Subscribed / in trial — a free-trial period IS a normal transaction.
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let t) = entitlement,
               StllsPro.productIDs.contains(t.productID),
               t.revocationDate == nil {
                set(.entitled)
                return
            }
        }

        // 3. Everyone else.
        set(.locked)
    }

    private func set(_ s: EntitlementState) {
        state = s
        KeychainCache.write(state: s)
    }
}

// Minimal Keychain cache so offline launches keep their last entitlement.
private enum KeychainCache {
    private static let account = "is.skjaskot.stlls.entitlement"

    static func write(state: EntitlementState) {
        let data = Data(state.rawValue.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func readState() -> EntitlementState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return EntitlementState(rawValue: raw)
    }
}

// MARK: - Trial reminder (spec §5)

enum TrialReminder {
    static let requestID = "stlls-pro-trial-reminder"

    static func schedule(from purchaseDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = "STLLS Pro"
        content.body  = "Your free trial will renew in 2 days unless cancelled before."
        content.sound = .default

        let interval: TimeInterval = StllsPro.debugFastReminder ? 60 : 5 * 24 * 60 * 60
        let fireDate = purchaseDate.addingTimeInterval(interval)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(60, fireDate.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)   // silently no-ops if permission denied
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    /// If the user turned off auto-renew mid-trial, the reminder must go too.
    static func sync() async {
        guard let products = try? await Product.products(for: StllsPro.productIDs),
              let subscription = products.first?.subscription,
              let statuses = try? await subscription.status else { return }
        for status in statuses {
            if case .verified(let renewal) = status.renewalInfo, renewal.willAutoRenew == false {
                SubAnalytics.log("trial_cancelled")
                cancel()
                return
            }
        }
    }
}

// MARK: - Gate (mounted over the whole app in StllsApp)

struct SubscriptionGate: View {
    @ObservedObject private var store = EntitlementStore.shared

    var body: some View {
        Group {
            if StllsPro.enabled {
                switch store.state {
                case .grandfathered, .entitled:
                    EmptyView()
                case .unknown:
                    StllsPro.bg.ignoresSafeArea()   // brief boot splash while resolving
                case .locked:
                    SubscriptionOnboarding()
                }
            }
        }
        .onAppear { store.start() }
    }
}

// MARK: - Onboarding flow (spec §3)

struct SubscriptionOnboarding: View {
    @AppStorage("stlls-onboarding-seen") private var seenIntro = false
    @State private var step: Int = 0

    var body: some View {
        ZStack {
            if step < 3 { OnboardBackdrop() }
            VStack(spacing: 0) {
                if step < 3 { StepBar(step: step).padding(.top, 12) }
                Group {
                    switch step {
                    case 0: TrialIntroScreen { advance() }
                    case 1: NotificationPrePrompt { advance() }
                    case 2: ReminderPromiseScreen { advance() }
                    default: PaywallScreen()
                    }
                }
            }
        }
        .onAppear {
            if seenIntro { step = 3 }   // returning locked users go straight to the offer
            else { SubAnalytics.log("onboarding_started") }
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.3)) {
            step += 1
            if step >= 3 { seenIntro = true }
        }
    }
}

private struct Wordmark: View {
    var body: some View {
        Image("StllsProLogo")   // STLLS PRO logo, black keyed to transparent
            .resizable()
            .scaledToFit()
            .frame(height: 44)
            .accessibilityLabel("STLLS Pro")
    }
}

// Story-style progress: three thin segments, filled up to the current step.
private struct StepBar: View {
    let step: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? StllsPro.accent : Color.white.opacity(0.15))
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 28)
        .animation(.easeInOut(duration: 0.3), value: step)
    }
}

// Uppercase tracked micro-label above each headline.
private struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(2.4)
            .foregroundColor(StllsPro.accent)
    }
}

private extension LinearGradient {
    static var stllsCTA: LinearGradient {
        LinearGradient(colors: [StllsPro.accent, Color(red: 0.45, green: 0.78, blue: 1.0)],
                       startPoint: .leading, endPoint: .trailing)
    }
    // warm display gradient for the big headlines — orange into yellow
    static var stllsTitle: LinearGradient {
        LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.15),
                                Color(red: 1.0, green: 0.84, blue: 0.30)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// Full-width capsule, label left / arrow right. Screens supply the horizontal
// padding so the capsule lines up with their left-aligned text column.
private struct OnboardCTA: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(0.2)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 17)
            .background(Capsule().fill(LinearGradient.stllsCTA))
            .foregroundColor(.black)
        }
    }
}

// Dark, on-brand backdrop: near-black ground with the STLLS layout frames
// drifting and pulsing over it. Static (and quieter) under Reduce Motion.
private struct OnboardBackdrop: View {
    var intensity: Double = 1.0
    var body: some View {
        ZStack {
            Color.black
            StllsPro.bg.opacity(0.6)
            FloatingFramesBackground().opacity(intensity)
        }
        .ignoresSafeArea()
    }
}

// Empty layout frames — the STLLS motif — drifting and pulsing all over the
// screen. Kept straight (no tilt) and monochrome, on brand.
private struct FloatingFramesBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    // deterministic per-frame layout (fractions of the screen)
    private struct Spec { let x: CGFloat; let y: CGFloat; let w: CGFloat; let h: CGFloat
                          let dy: CGFloat; let dur: Double; let delay: Double }
    private let specs: [Spec] = [
        .init(x: 0.14, y: 0.16, w: 64,  h: 92,  dy: 16, dur: 7.0, delay: 0.0),
        .init(x: 0.82, y: 0.12, w: 48,  h: 48,  dy: 12, dur: 6.2, delay: 1.1),
        .init(x: 0.88, y: 0.44, w: 70,  h: 96,  dy: 20, dur: 8.4, delay: 2.3),
        .init(x: 0.10, y: 0.52, w: 44,  h: 62,  dy: 14, dur: 6.8, delay: 3.0),
        .init(x: 0.24, y: 0.84, w: 78,  h: 56,  dy: 18, dur: 7.6, delay: 0.7),
        .init(x: 0.78, y: 0.80, w: 52,  h: 74,  dy: 15, dur: 6.4, delay: 1.9),
        .init(x: 0.50, y: 0.07, w: 56,  h: 40,  dy: 10, dur: 8.0, delay: 2.7),
        .init(x: 0.56, y: 0.93, w: 40,  h: 40,  dy: 12, dur: 7.2, delay: 3.6),
        .init(x: 0.05, y: 0.33, w: 34,  h: 48,  dy: 16, dur: 6.0, delay: 4.2),
        .init(x: 0.33, y: 0.28, w: 88,  h: 120, dy: 22, dur: 9.2, delay: 1.5),
        .init(x: 0.68, y: 0.30, w: 40,  h: 56,  dy: 13, dur: 6.6, delay: 4.8),
        .init(x: 0.42, y: 0.60, w: 52,  h: 38,  dy: 17, dur: 7.8, delay: 2.0),
        .init(x: 0.93, y: 0.66, w: 36,  h: 52,  dy: 11, dur: 6.1, delay: 3.3),
        .init(x: 0.04, y: 0.74, w: 58,  h: 42,  dy: 19, dur: 8.6, delay: 5.1),
        .init(x: 0.64, y: 0.55, w: 100, h: 72,  dy: 24, dur: 9.8, delay: 0.4),
        .init(x: 0.38, y: 0.97, w: 64,  h: 46,  dy: 14, dur: 7.4, delay: 4.5),
        .init(x: 0.20, y: 0.02, w: 44,  h: 60,  dy: 12, dur: 6.9, delay: 5.6),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(specs.indices, id: \.self) { i in
                    let s = specs[i]
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1.2)
                        .frame(width: s.w, height: s.h)
                        .scaleEffect(reduceMotion ? 1 : (on ? 1.08 : 0.90))
                        .position(x: geo.size.width * s.x, y: geo.size.height * s.y)
                        .offset(y: reduceMotion ? 0 : (on ? -s.dy : s.dy))
                        .opacity(reduceMotion ? 0.05 : (on ? 0.20 : 0.02))
                        .animation(
                            reduceMotion ? nil :
                                .easeInOut(duration: s.dur)
                                .repeatForever(autoreverses: true)
                                .delay(s.delay),
                            value: on
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { on = true }
    }
}

// Screen 1 — trial intro: editorial left-aligned layout, display-size numeral
private struct TrialIntroScreen: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark().padding(.top, 18)
            Spacer()
            Eyebrow("FREE TRIAL")
            Text("7 days\non us.")
                .font(.system(size: 64, weight: .heavy))
                .foregroundStyle(LinearGradient.stllsTitle)
                .padding(.top, 10)
            Text("We want you to try everything STLLS can do, with all the power it has.")
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .padding(.trailing, 24)
            Spacer()
            OnboardCTA(title: "Continue", action: onContinue)
                .padding(.bottom, 34)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Screen 2 — notification permission pre-prompt
private struct NotificationPrePrompt: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark().padding(.top, 18)
            Spacer()
            Eyebrow("STAY IN CONTROL")
            Text("Allow notifications to get your reminder")
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.trailing, 24)
            MockPermissionDialog()
                .rotationEffect(.degrees(-2.5))
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            Spacer()
            Text("Turn off notifications at any time")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            OnboardCTA(title: "Continue") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    SubAnalytics.log("notification_permission", ["granted": String(granted)])
                    DispatchQueue.main.async { onContinue() }
                }
            }
            .padding(.bottom, 34)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Illustration of the modern iOS permission card — dark sheet, left-aligned
// text, capsule buttons. Slightly hazy and desaturated so it reads as a
// preview, not a real prompt; only the accent arrow at "Allow" stays crisp.
private struct MockPermissionDialog: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\u{201C}STLLS\u{201D} Would Like to Send You Notifications")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Notifications may include alerts, sounds and icon badges. These can be configured in Settings.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text("Don't Allow")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    Text("Allow")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(width: 310)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
            .cornerRadius(26)
            .saturation(0.35)
            .opacity(0.85)
            .blur(radius: 1.1)

            // crisp accent arrow aimed at the "Allow" capsule
            Image(systemName: "arrow.up")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(StllsPro.accent)
                .offset(x: -78, y: 44)
        }
        .padding(.bottom, 44)
    }
}

// Screen 3 — reminder promise: trial timeline + the reminder card
private struct ReminderPromiseScreen: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark().padding(.top, 18)
            Spacer()
            Eyebrow("NO SURPRISES")
            Text("We'll remind you 2 days before your trial ends.")
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.trailing, 24)
            TrialTimeline()
                .padding(.top, 26)
            MockReminderNotification()
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            Spacer()
            OnboardCTA(title: "Continue", action: onContinue)
                .padding(.bottom, 34)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The 7-day trial as a vertical timeline: today → reminder → decision day.
private struct TrialTimeline: View {
    private let steps: [(day: String, label: String, filled: Bool)] = [
        ("Today", "Full access to everything in STLLS", true),
        ("Day 5", "We send your reminder", false),
        ("Day 7", "Trial ends — cancel any time before", false),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps.indices, id: \.self) { i in
                let s = steps[i]
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(s.filled ? StllsPro.accent : Color.clear)
                            .overlay(Circle().stroke(StllsPro.accent, lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                            .padding(.top, 3)
                        if i < steps.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 1.5)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.day)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(StllsPro.accent)
                        Text(s.label)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, i < steps.count - 1 ? 18 : 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// STLLS-styled notification card (own dark language, accent ring — not the
// stock iOS banner look).
private struct MockReminderNotification: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("stlls logo1")
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("STLLS Pro")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Your free trial will renew in 2 days unless cancelled before.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: 340)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StllsPro.accent.opacity(0.45), lineWidth: 1))
        .cornerRadius(16)
        .shadow(color: StllsPro.accent.opacity(0.12), radius: 18)
    }
}

// MARK: - Screen 4: the paywall (spec §3.4, §6)

struct PaywallScreen: View {
    @ObservedObject private var store = EntitlementStore.shared

    @State private var products: [Product] = []
    @State private var selected: Product?
    @State private var trialEligible = true
    @State private var purchasing = false
    @State private var showClose = false
    @State private var dismissedToLocked = false
    @State private var toast: String?

    private var monthly: Product? { products.first { $0.id == StllsPro.monthlyID } }
    private var yearly:  Product? { products.first { $0.id == StllsPro.yearlyID } }

    var body: some View {
        if dismissedToLocked {
            LockedScreen { dismissedToLocked = false }
        } else {
            paywall
        }
    }

    private var paywall: some View {
        ZStack(alignment: .topTrailing) {
            OnboardBackdrop(intensity: 0.7)   // quieter behind the offer content

            VStack(spacing: 0) {
                Wordmark()
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                Spacer(minLength: 12)

                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow("WELCOME OFFER")
                    Text("Everything STLLS, unlocked.")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(LinearGradient.stllsTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 10) {
                    checkRow(trialEligible ? "7-day free trial" : "Full access from day one")
                    checkRow("All features and layouts")
                    checkRow("Cancel anytime from the app")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)

                VStack(spacing: 10) {
                    if let m = monthly { planCard(m, badge: nil, subtitle: "\(m.displayPrice) per month") }
                    if let y = yearly {
                        planCard(y, badge: "SAVE 50%", subtitle: yearlySubtitle(y))
                    }
                    if products.isEmpty {
                        ProgressView().tint(.white).padding(.vertical, 30)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                Spacer(minLength: 12)

                Button(action: buy) {
                    HStack {
                        if purchasing {
                            ProgressView().tint(.black).frame(maxWidth: .infinity)
                        } else {
                            Text(trialEligible ? "Try For Free" : "Subscribe")
                                .font(.system(size: 17, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 17)
                    .background(Capsule().fill(LinearGradient.stllsCTA))
                    .foregroundColor(.black)
                }
                .disabled(purchasing || selected == nil)
                .padding(.horizontal, 24)

                Text("Renews automatically. Cancel any time.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 10)

                HStack(spacing: 18) {
                    Button("Restore Purchases", action: restore)
                    Link("Terms", destination: StllsPro.termsURL)
                    Link("Privacy", destination: StllsPro.privacyURL)
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 8)
                .padding(.bottom, 26)
            }

            // Review-safe close: appears after a short delay, exits to locked.
            if showClose {
                Button {
                    dismissedToLocked = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .padding(.top, 18)
                .padding(.trailing, 18)
                .transition(.opacity)
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 13))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial)
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 120)
            }
        }
        .task { await load() }
        .onAppear {
            SubAnalytics.log("paywall_shown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showClose = true }
            }
        }
    }

    private func checkRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(StllsPro.accent.opacity(0.18))
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(StllsPro.accent))
            Text(text).font(.system(size: 15)).foregroundColor(.white.opacity(0.9))
        }
    }

    private func planCard(_ product: Product, badge: String?, subtitle: String) -> some View {
        Button { selected = product } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(product.id == StllsPro.yearlyID ? "Yearly" : "Monthly")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(StllsPro.accent)
                                .foregroundColor(.black)
                                .cornerRadius(6)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(selected?.id == product.id ? StllsPro.accent : Color.clear)
                        .frame(width: 22, height: 22)
                    if selected?.id == product.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                    }
                }
            }
            .padding(14)
            .background(selected?.id == product.id ? StllsPro.accent.opacity(0.08) : Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 15)
                .stroke(selected?.id == product.id ? StllsPro.accent : Color.white.opacity(0.12),
                        lineWidth: 1.5))
            .cornerRadius(15)
        }
    }

    /// "$2.50 per month ($29.99 per year)" — always computed from the product,
    /// never hardcoded (spec §3.4/§6).
    private func yearlySubtitle(_ y: Product) -> String {
        let perMonth = (y.price / 12).formatted(y.priceFormatStyle)
        return "\(perMonth) per month (\(y.displayPrice) per year)"
    }

    private func load() async {
        do {
            let loaded = try await Product.products(for: StllsPro.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            selected = yearly ?? products.last            // yearly preselected
            if let sub = products.first?.subscription {
                trialEligible = await sub.isEligibleForIntroOffer
            }
        } catch {
            toastFlash("Couldn't load plans — check your connection")
        }
    }

    private func buy() {
        guard let product = selected, !purchasing else { return }
        purchasing = true
        Task {
            defer { purchasing = false }
            do {
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    guard case .verified(let transaction) = verification else {
                        toastFlash("Purchase could not be verified")
                        return
                    }
                    await transaction.finish()
                    if transaction.offerType == .introductory {
                        SubAnalytics.log("trial_started", ["plan": product.id])
                        TrialReminder.schedule(from: transaction.purchaseDate)
                    } else {
                        SubAnalytics.log("trial_converted", ["plan": product.id])
                    }
                    await store.resolve()
                case .userCancelled:
                    break                                  // stay on the paywall, no error
                case .pending:
                    toastFlash("Waiting for approval…")     // Ask to Buy
                @unknown default:
                    break
                }
            } catch {
                SubAnalytics.log("purchase_failed", ["error": String(describing: error)])
                toastFlash("Purchase failed — please try again")
            }
        }
    }

    private func restore() {
        Task {
            do {
                try await AppStore.sync()
                await store.resolve()
                SubAnalytics.log("restore_completed")
                if store.state == .locked { toastFlash("No purchases to restore") }
            } catch {
                toastFlash("Restore failed — please try again")
            }
        }
    }

    private func toastFlash(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation { toast = nil }
        }
    }
}

// After X: still a hard paywall — just not a trap (spec §3.4).
private struct LockedScreen: View {
    let onUnlock: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Wordmark()
            Text("STLLS Pro unlocks the full app.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
            Button(action: onUnlock) {
                HStack(spacing: 10) {
                    Text("Unlock STLLS Pro")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .padding(.horizontal, 30).padding(.vertical, 15)
                .background(Capsule().fill(LinearGradient.stllsCTA))
                .foregroundColor(.black)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnboardBackdrop(intensity: 0.5))
    }
}

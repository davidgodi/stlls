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
    /// MASTER SWITCH — keep false until the App Store Connect products exist
    /// and the .storekit file is selected in the scheme; flipping this on with
    /// no products reachable would lock the whole app behind a dead paywall.
    static let enabled = false

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
            StllsPro.bg.ignoresSafeArea()
            switch step {
            case 0: TrialIntroScreen { advance() }
            case 1: NotificationPrePrompt { advance() }
            case 2: ReminderPromiseScreen { advance() }
            default: PaywallScreen()
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
        Text("STLLS")
            .font(.system(size: 15, weight: .semibold))
            .kerning(4)
            .foregroundColor(.white)
    }
}

private struct OnboardCTA: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(StllsPro.accent)
                .foregroundColor(.black)
                .cornerRadius(14)
        }
        .padding(.horizontal, 28)
    }
}

// Screen 1 — trial intro
private struct TrialIntroScreen: View {
    let onContinue: () -> Void
    var body: some View {
        VStack {
            Wordmark().padding(.top, 24)
            Spacer()
            (Text("We want you to discover ")
                + Text("STLLS Pro").bold()
                + Text(", so here's a ")
                + Text("7-day free trial").bold().foregroundColor(StllsPro.accent)
                + Text(" on us."))
                .font(.system(size: 26, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(.horizontal, 32)
            Spacer()
            OnboardCTA(title: "Continue", action: onContinue)
                .padding(.bottom, 34)
        }
    }
}

// Screen 2 — notification permission pre-prompt
private struct NotificationPrePrompt: View {
    let onContinue: () -> Void
    var body: some View {
        VStack {
            Wordmark().padding(.top, 24)
            Spacer()
            Text("Allow notifications to get your reminder")
                .font(.system(size: 26, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(.horizontal, 32)
            MockPermissionDialog()
                .padding(.top, 36)
            Spacer()
            Text("Turn off notifications at any time")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
                .padding(.bottom, 12)
            OnboardCTA(title: "Continue") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    SubAnalytics.log("notification_permission", ["granted": String(granted)])
                    DispatchQueue.main.async { onContinue() }
                }
            }
            .padding(.bottom, 34)
        }
    }
}

// The SCRL-style illustration: a mock system dialog with an arrow at "Allow".
private struct MockPermissionDialog: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("\u{201C}STLLS\u{201D} Would Like to\nSend You Notifications")
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Notifications may include alerts,\nsounds and icon badges.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            Divider()
            HStack(spacing: 0) {
                Text("Don't Allow")
                    .font(.system(size: 15))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                Divider()
                Text("Allow")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(StllsPro.accent)
                            .offset(y: 44)
                    }
            }
            .frame(height: 44)
        }
        .frame(width: 270)
        .background(.regularMaterial)
        .cornerRadius(14)
        .padding(.bottom, 44)
    }
}

// Screen 3 — reminder promise
private struct ReminderPromiseScreen: View {
    let onContinue: () -> Void
    var body: some View {
        VStack {
            Wordmark().padding(.top, 24)
            Spacer()
            MockReminderNotification()
            Text("We'll remind you 2 days before your trial ends.")
                .font(.system(size: 26, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.top, 36)
            Spacer()
            OnboardCTA(title: "Continue", action: onContinue)
                .padding(.bottom, 34)
        }
    }
}

private struct MockReminderNotification: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black)
                .frame(width: 38, height: 38)
                .overlay(Text("S").font(.system(size: 16, weight: .bold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text("STLLS Pro").font(.system(size: 13, weight: .semibold))
                Text("Your free trial will renew in 2 days unless cancelled before.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial)
        .cornerRadius(16)
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
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.17), StllsPro.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Wordmark().padding(.top, 24)
                Spacer(minLength: 12)

                Text("Welcome Offer")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                Text("Enjoy full access with STLLS Pro")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    checkRow(trialEligible ? "7-day free trial" : "Full access from day one")
                    checkRow("All features and layouts")
                    checkRow("Cancel anytime from the app")
                }
                .padding(.top, 22)

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
                    Group {
                        if purchasing { ProgressView().tint(.black) }
                        else { Text(trialEligible ? "Try For Free" : "Subscribe").bold() }
                    }
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(StllsPro.accent)
                    .foregroundColor(.black)
                    .cornerRadius(14)
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
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(StllsPro.accent)
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
                Image(systemName: selected?.id == product.id ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected?.id == product.id ? StllsPro.accent : .white.opacity(0.3))
            }
            .padding(14)
            .background(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .stroke(selected?.id == product.id ? StllsPro.accent : Color.white.opacity(0.12),
                        lineWidth: 1.5))
            .cornerRadius(13)
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
                Text("Unlock STLLS Pro")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 30).padding(.vertical, 14)
                    .background(StllsPro.accent)
                    .foregroundColor(.black)
                    .cornerRadius(13)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StllsPro.bg.ignoresSafeArea())
    }
}

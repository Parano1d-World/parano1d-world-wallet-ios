import Foundation
import UserNotifications
#if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

/// Local alerts about the person's own paired mining computers: offline, a safety stop (cooldown),
/// a GPU running hot, mining stopping by itself, and high rejected shares. Every alert is off until
/// the person turns it on. They come only from the signed status the rig sends this phone; nothing
/// is sent to a notification server, and alerts never show an address or amounts.
/// While the app is closed, iOS decides when the background check runs (often every 15–60 minutes,
/// only while the phone is unlocked), so these are not instant.
@MainActor enum MiningAlerts {
    static let offlineKey = "notifyMiningOffline"
    static let safetyKey = "notifyMiningSafetyStop"
    static let hotKey = "notifyMiningHot"
    static let stoppedKey = "notifyMiningStopped"
    static let rejectsKey = "notifyMiningRejects"
    static let marginKey = "miningHotMarginC"
    /// Posted when the person taps a mining alert.
    static let opened = Notification.Name("parano1d.miningAlertOpened")
    static var pendingOpen = false
    private static let stateKey = "miningAlertState.v1"

    static var anyOn: Bool {
        [offlineKey, safetyKey, hotKey, stoppedKey, rejectsKey].contains { UserDefaults.standard.bool(forKey: $0) }
    }
    static var margin: Int {
        let value = UserDefaults.standard.integer(forKey: marginKey)
        return (1...20).contains(value) ? value : 5
    }

    /// What this phone last saw for one computer, so each alert fires once per event.
    private struct State: Codable {
        var failures = 0
        var offlineNotified = false
        var safetyAt: String?
        var hot: Set<Int> = []
        var running: Bool?
        var stopRequestedAt: Date?
        var rejectsNotified = false
    }
    private static func load(_ id: UUID) -> State {
        guard let data = UserDefaults.standard.data(forKey: stateKey + "." + id.uuidString),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }
    private static func save(_ state: State, _ id: UUID) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey + "." + id.uuidString) }
    }
    private static var lastForegroundCheck: Date?
    /// While the app is open, check every paired computer about once a minute when any alert is on,
    /// even if the Mining tab isn't showing (it refreshes itself while it is).
    static func foregroundTick(offline: Bool) {
        guard anyOn, !offline, !RigStore.shared.rigs.isEmpty else { return }
        if let last = lastForegroundCheck, Date().timeIntervalSince(last) < 60 { return }
        lastForegroundCheck = Date()
        Task { await RigStore.shared.refreshAll(automatic: true) }
    }
    static func forget(_ id: UUID) { UserDefaults.standard.removeObject(forKey: stateKey + "." + id.uuidString) }

    /// The phone itself asked this computer to stop, so the next "stopped" is expected.
    static func noteStopRequested(_ id: UUID) {
        var state = load(id); state.stopRequestedAt = Date(); save(state, id)
    }

    private static func post(_ id: String, _ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["route": "mining"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// A status answer arrived from this computer.
    static func observe(_ rig: RigPairing, status: RigStatus) {
        var state = load(rig.id)
        let name = String(rig.label.prefix(40))
        let defaults = UserDefaults.standard
        if state.offlineNotified, defaults.bool(forKey: offlineKey) {
            post("mining-online-\(rig.id)-\(Int(Date().timeIntervalSince1970))", "\(name) is back online", "The computer is answering again.")
        }
        state.failures = 0; state.offlineNotified = false

        if let event = status.safetyEvent, let at = status.safetyEventAt, at != state.safetyAt {
            if state.safetyAt != nil || state.running == true, defaults.bool(forKey: safetyKey) {
                post("mining-safety-\(rig.id)-\(at)", "Safety stop on \(name)", event)
            }
            state.safetyAt = at
        }

        let limit = status.gpuMaxC ?? 85
        let threshold = Double(limit - margin)
        var nowHot = Set<Int>()
        for gpu in status.gpus {
            guard let temp = gpu.tempC else { continue }
            if temp >= threshold { nowHot.insert(gpu.id) }
            else if state.hot.contains(gpu.id), temp >= threshold - 3 { nowHot.insert(gpu.id) } // keep until it cools 3 °C below
        }
        if status.running, defaults.bool(forKey: hotKey) {
            for index in nowHot.subtracting(state.hot) {
                let temp = status.gpus.first { $0.id == index }?.tempC.map { Int($0.rounded()) } ?? limit
                post("mining-hot-\(rig.id)-\(index)-\(Int(Date().timeIntervalSince1970))", "GPU running hot on \(name)",
                     "GPU \(index) is at \(temp) °C. The safety stop is set to \(limit) °C.")
            }
        }
        state.hot = nowHot

        if state.running == true, !status.running {
            let expected = state.stopRequestedAt.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
            let safety = status.safetyEvent != nil && status.safetyEventAt == state.safetyAt
            if !expected, !safety, defaults.bool(forKey: stoppedKey) {
                post("mining-stopped-\(rig.id)-\(Int(Date().timeIntervalSince1970))", "Mining stopped on \(name)",
                     "The computer reports it's no longer mining. Open Mining to check it.")
            }
            state.stopRequestedAt = nil
        }
        state.running = status.running

        let shares = (status.accepted ?? 0) + (status.rejected ?? 0)
        if let pct = status.rejectPct, status.running, shares >= 20 {
            if pct >= 5, !state.rejectsNotified {
                if defaults.bool(forKey: rejectsKey) {
                    post("mining-rejects-\(rig.id)-\(Int(Date().timeIntervalSince1970))", "High rejected shares on \(name)",
                         "\(pct.formatted(.number.precision(.fractionLength(1))))% of shares were rejected. Open Mining for common causes.")
                }
                state.rejectsNotified = true
            } else if pct < 3 { state.rejectsNotified = false }
        }
        save(state, rig.id)
    }

    /// This computer didn't answer (rig, companion or tunnel offline). Two misses in a row count as offline,
    /// so one dropped request doesn't alert.
    static func observeOffline(_ rig: RigPairing) {
        var state = load(rig.id)
        state.failures += 1
        if state.failures >= 2, !state.offlineNotified {
            if UserDefaults.standard.bool(forKey: offlineKey) {
                post("mining-offline-\(rig.id)-\(Int(Date().timeIntervalSince1970))", "\(String(rig.label.prefix(40))) is offline",
                     "The computer, its mining app or its connection isn't answering. Mining, if running, carries on by itself.")
            }
            state.offlineNotified = true
        }
        save(state, rig.id)
    }

    // MARK: Background checks while the app is closed

    #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.koajent.parano1d.wallet") + ".mining-check"
    private static var registered = false
    /// Must run before the app finishes launching.
    static func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { run(task) }
        }
    }
    /// Called when the app goes to the background.
    static func schedule() {
        guard registered, anyOn, !RigStore.shared.rigs.isEmpty, !UserDefaults.standard.bool(forKey: "offlineMode") else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    /// Completes the system task exactly once, whichever of finishing or expiry happens first.
    private final class Completion {
        let task: BGAppRefreshTask
        private var done = false
        init(_ task: BGAppRefreshTask) { self.task = task }
        @MainActor func finish(_ success: Bool) { guard !done else { return }; done = true; task.setTaskCompleted(success: success) }
    }
    private static func run(_ task: BGAppRefreshTask) {
        schedule() // keep the chain of background checks going
        let completion = Completion(task)
        let work = Task { @MainActor in
            await RigStore.shared.refreshAll(automatic: true)
            completion.finish(true)
        }
        task.expirationHandler = { work.cancel(); Task { @MainActor in completion.finish(false) } }
    }
    #else
    static func register() {}
    static func schedule() {}
    #endif
}

import SwiftUI

/// Set up which mining alerts this phone shows. Opened from the Mining tab and from Settings → Notifications.
struct MiningAlertsSettingsView: View {
    @AppStorage(MiningAlerts.offlineKey) private var offline = false
    @AppStorage(MiningAlerts.safetyKey) private var safety = false
    @AppStorage(MiningAlerts.hotKey) private var hot = false
    @AppStorage(MiningAlerts.stoppedKey) private var stopped = false
    @AppStorage(MiningAlerts.rejectsKey) private var rejects = false
    @AppStorage(MiningAlerts.marginKey) private var margin = 5
    @State private var notificationError: String?
    var body: some View {
        Form {
            Section { SettingsHero(icon: "bell.badge", title: "Mining alerts", subtitle: "Know when a computer needs you. Alerts never show an address or amounts.", tint: SettingsTint.color("alerts")) }
                .themedRow(standard: Theme.panel)
            SettingsSection("Alert me when") {
                Toggle(isOn: $offline) { SettingsLabel(title: "A computer goes offline", icon: "wifi.slash", tint: Theme.mint) }
                Toggle(isOn: $safety) { SettingsLabel(title: "A safety stop or cooldown happens", icon: "thermometer.high", tint: Theme.mint) }
                Toggle(isOn: $hot) { SettingsLabel(title: "A GPU runs hot", icon: "flame", tint: Theme.mint) }
                if hot {
                    Stepper(value: $margin, in: 1...20) {
                        HStack {
                            Text("Warn me").font(Theme.subheadline)
                            Spacer()
                            Text("\(margin) °C before the limit").font(Theme.subheadline.monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                Toggle(isOn: $stopped) { SettingsLabel(title: "Mining stops by itself", icon: "stop.circle", tint: Theme.mint) }
                Toggle(isOn: $rejects) { SettingsLabel(title: "Rejected shares go above 5%", icon: "exclamationmark.triangle", tint: Theme.mint) }
            }.themedRow()
            SettingsSection("Siri") {
                NavigationLink { SiriVoiceSettingsView() } label: { SettingsLabel(title: "Siri & voice for mining", icon: "waveform", tint: Theme.mint) }
            }.themedRow()
            SettingsSection("How they arrive") {
                DisclosureGroup("When you'll get them") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("While Parano1d is open, every computer is checked about once a minute, so alerts arrive within a minute or two.")
                        Text("While it's closed, iOS decides when the app may check, usually every 15 to 60 minutes and only while the phone is unlocked. Force-quitting the app stops these checks.")
                        Text("A computer counts as offline after two missed checks in a row, and you're told when it's back.")
                        Text("Alerts come only from the signed status your own computers send this phone. Nothing is sent to a notification service.")
                    }.font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                if let notificationError { Text(notificationError).foregroundStyle(.orange) }
                Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                    SettingsLabel(title: "Open iOS notification settings", icon: "gearshape")
                }
            }.themedRow()
        }
        .modifier(WalletSettingsSurface()).navigationTitle("Mining alerts")
        .onChange(of: offline) { _, on in ask(on) { offline = false } }
        .onChange(of: safety) { _, on in ask(on) { safety = false } }
        .onChange(of: hot) { _, on in ask(on) { hot = false } }
        .onChange(of: stopped) { _, on in ask(on) { stopped = false } }
        .onChange(of: rejects) { _, on in ask(on) { rejects = false } }
    }
    private func ask(_ on: Bool, undo: @escaping () -> Void) {
        guard on else { return }
        Task {
            if !(await WalletActivityNotifications.authorize()) {
                undo(); notificationError = "Allow notifications in iOS Settings to receive mining alerts."
            } else {
                MiningAlerts.schedule()
                await RigStore.shared.refreshAll(automatic: true) // record where each computer stands now
            }
        }
    }
}

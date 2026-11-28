import AppIntents
import Foundation

/// "Hey Siri, check my Parano1d balance": read-only. It answers from the balance this phone's own node last
/// verified (never a website or explorer figure), says how old that check is, and needs the iPhone to be
/// unlocked with Face ID or the passcode. It can't send, sign or change anything.
struct CheckBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Check balance"
    static let description = IntentDescription("Says your NOID balance as last verified by this iPhone's own node. Read-only.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if UserDefaults.standard.bool(forKey: "hideBalances") {
            return .result(dialog: "Balances are hidden in Parano1d. Open the app to see yours.")
        }
        guard let owner = try? await LastBalanceStore.shared.current(),
              let snapshot = try? await LastBalanceStore.shared.load(for: owner),
              let amount = Amounts.format(snapshot.micronoid) else {
            return .result(dialog: "There's no verified balance on this iPhone yet. Open Parano1d and let it check the chain first.")
        }
        let age = Date().timeIntervalSince(snapshot.verifiedAt)
        let when = RelativeDateTimeFormatter().localizedString(for: snapshot.verifiedAt, relativeTo: Date())
        let height = snapshot.height.formatted()
        if age < 15 * 60 {
            return .result(dialog: "Your verified balance is \(amount) NOID, checked \(when) at block \(height).")
        }
        return .result(dialog: "Your saved balance is \(amount) NOID, last verified \(when) at block \(height). It may have changed since; open Parano1d to check the chain again.")
    }
}

/// "Hey Siri, what's my mining status?": asks each paired mining computer for its signed status and reads a short
/// summary. Read-only; off until "Mining status with Siri" is turned on. Needs the iPhone unlocked.
struct MiningStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check mining"
    static let description = IntentDescription("Says whether your paired mining computers are mining, their hashrate, the hottest GPU and any safety stop. Read-only.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SiriVoice.miningStatus else { return .result(dialog: "\(SiriVoice.turnedOff)") }
        let store = RigStore.shared
        guard !store.rigs.isEmpty else { return .result(dialog: "No mining computers are paired. Pair one in the Mining tab.") }
        guard !UserDefaults.standard.bool(forKey: "offlineMode") else { return .result(dialog: "Parano1d is in offline mode, so it can't check your computers.") }
        await store.refreshAll(automatic: true)
        let m = store.summary()
        var parts: [String] = []
        for rig in m.rigs.prefix(4) {
            if !rig.online { parts.append("\(rig.name) is offline.") }
            else if let alert = rig.alert { parts.append("\(rig.name): \(alert).") }
            else if rig.running {
                var line = "\(rig.name) is mining" + (rig.hashrate.map { " at \($0)" } ?? "")
                if let shares = rig.shares { line += ", \(shares) shares accepted" }
                if let t = rig.hottestC { line += ", hottest GPU \(t) degrees" }
                parts.append(line + ".")
            } else { parts.append("\(rig.name) is idle.") }
        }
        if m.rigs.count > 4 { parts.append("Plus \(m.rigs.count - 4) more in the app.") }
        let head = m.rigs.count == 1 ? "" : "\(m.mining) of \(m.rigs.count) computers mining. "
        return .result(dialog: "\(head + parts.joined(separator: " "))")
    }
}

struct Parano1dShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckBalanceIntent(),
                    phrases: ["Check my \(.applicationName) balance",
                              "What's my \(.applicationName) balance",
                              "\(.applicationName) balance"],
                    shortTitle: "Check balance",
                    systemImageName: "wallet.pass")
        AppShortcut(intent: MiningStatusIntent(),
                    phrases: ["What's my \(.applicationName) mining status",
                              "How are my \(.applicationName) rigs",
                              "Check my \(.applicationName) mining",
                              "\(.applicationName) mining status"],
                    shortTitle: "Check mining",
                    systemImageName: "hammer")
        AppShortcut(intent: StopMiningIntent(),
                    phrases: ["Stop mining on \(\.$computer) in \(.applicationName)",
                              "Stop \(.applicationName) mining"],
                    shortTitle: "Stop mining",
                    systemImageName: "stop.circle")
        AppShortcut(intent: StartMiningIntent(),
                    phrases: ["Start mining on \(\.$computer) in \(.applicationName)",
                              "Start \(.applicationName) mining"],
                    shortTitle: "Start mining",
                    systemImageName: "play.circle")
    }
}

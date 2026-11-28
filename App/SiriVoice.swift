import AppIntents
import SwiftUI
import UserNotifications

/// Settings → Siri & voice. Everything is off until the person turns it on; turning something on asks for
/// Face ID (or the passcode) and shows what it allows, turning it off needs nothing.
/// Decided by the owner on 26 Nov.
enum SiriVoice {
    static let miningStatusKey = "voice.miningStatus"
    /// "off", "stop" or "startStop": the two mining-control switches are mutually exclusive.
    static let miningControlKey = "voice.miningControl"
    /// In-app Face ID for Start and Stop. On by default (stored as "off" only when turned off).
    static let startStopAuthKey = "mining.startStopFaceIDOff"
    static let chatReadKey = "voice.chatRead"
    static let chatSendKey = "voice.chatSend"
    static let roomReadKey = "voice.roomRead"
    static let turnedOff = "That's turned off in Parano1d → Settings → Siri & voice."

    static var miningStatus: Bool { UserDefaults.standard.bool(forKey: miningStatusKey) }
    static var miningControl: String { UserDefaults.standard.string(forKey: miningControlKey) ?? "off" }
    static var canStop: Bool { ["stop", "startStop"].contains(miningControl) }
    static var canStart: Bool { miningControl == "startStop" }
    static var startStopNeedsFaceID: Bool { !UserDefaults.standard.bool(forKey: startStopAuthKey) }

    /// Posted for every Start or Stop that Siri sends, so it's never silent.
    static func notify(_ title: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = "Sent by Siri from this iPhone."; content.sound = .default
        content.userInfo = ["route": "mining"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "siri-mining-\(UUID().uuidString)", content: content, trigger: nil))
    }
}

/// Settings → Siri & voice switches, saved in the same keys the intents read.
@MainActor final class SiriVoiceStore: ObservableObject {
    static let shared = SiriVoiceStore()
    private let defaults = UserDefaults.standard
    @Published var miningStatus: Bool { didSet { defaults.set(miningStatus, forKey: SiriVoice.miningStatusKey) } }
    @Published var miningControl: String { didSet { defaults.set(miningControl, forKey: SiriVoice.miningControlKey) } }
    @Published var faceIDOff: Bool { didSet { defaults.set(faceIDOff, forKey: SiriVoice.startStopAuthKey) } }
    @Published var chatRead: Bool { didSet { defaults.set(chatRead, forKey: SiriVoice.chatReadKey) } }
    @Published var chatSend: Bool { didSet { defaults.set(chatSend, forKey: SiriVoice.chatSendKey) } }
    @Published var roomRead: Bool { didSet { defaults.set(roomRead, forKey: SiriVoice.roomReadKey) } }
    init() {
        miningStatus = defaults.bool(forKey: SiriVoice.miningStatusKey)
        miningControl = defaults.string(forKey: SiriVoice.miningControlKey) ?? "off"
        faceIDOff = defaults.bool(forKey: SiriVoice.startStopAuthKey)
        chatRead = defaults.bool(forKey: SiriVoice.chatReadKey)
        chatSend = defaults.bool(forKey: SiriVoice.chatSendKey)
        roomRead = defaults.bool(forKey: SiriVoice.roomReadKey)
    }
}

// MARK: Settings page

struct SiriVoiceSettingsView: View {
    @EnvironmentObject private var wallet: WalletState
    /// The switches live in one shared object that every closure reaches, so a switch turned on from
    /// the alert redraws at once. (Written from the alert's closure through @AppStorage or a
    /// @StateObject, the setting was saved but the page on screen didn't redraw.)
    @ObservedObject private var store = SiriVoiceStore.shared
    private var miningStatus: Bool { get { store.miningStatus } nonmutating set { store.miningStatus = newValue } }
    private var miningControl: String { get { store.miningControl } nonmutating set { store.miningControl = newValue } }
    private var faceIDOff: Bool { get { store.faceIDOff } nonmutating set { store.faceIDOff = newValue } }
    private var chatRead: Bool { get { store.chatRead } nonmutating set { store.chatRead = newValue } }
    private var chatSend: Bool { get { store.chatSend } nonmutating set { store.chatSend = newValue } }
    private var roomRead: Bool { get { store.roomRead } nonmutating set { store.roomRead = newValue } }
    @AppStorage(ParanoidLook.key) private var paranoid = false
    /// A switch waiting for its notice to be accepted after Face ID.
    @State private var pending: Pending?
    @State private var error: String?
    private struct Pending: Identifiable { let id = UUID(); let title: String; let notice: String; let apply: () -> Void }

    var body: some View {
        Form {
            Section { SettingsHero(icon: "waveform", title: "Siri & voice", subtitle: "Choose what Siri can do with your wallet. Everything here is off until you turn it on.", tint: SettingsTint.color("alerts")) }
                .themedRow(standard: Theme.panel)
            SettingsSection("Wallet") {
                SettingsLabel(title: "Check balance with Siri · read-only", icon: "wallet.pass", tint: Theme.mint)
                Text("\"What's my Parano1d balance?\" Says the balance this iPhone last verified. Works when the iPhone is unlocked.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
            SettingsSection("Mining") {
                toggle("Mining status with Siri", icon: "hammer", isOn: miningStatus,
                       notice: "Siri will say your computers' status out loud, including in the car.") { miningStatus = $0 }
                toggle("Stop mining with Siri", icon: "stop.circle", isOn: miningControl == "stop",
                       notice: "Anyone who can talk to your unlocked iPhone could stop mining on your computers.") { miningControl = $0 ? "stop" : "off" }
                toggle("Start and stop mining with Siri", icon: "playpause", isOn: miningControl == "startStop",
                       notice: "Anyone who can talk to your unlocked iPhone could start or stop mining on your computers. Only start mining if nothing else is mining on that computer's GPUs.") { miningControl = $0 ? "startStop" : "off" }
                Toggle(isOn: Binding(get: { !faceIDOff }, set: { on in
                    if on { faceIDOff = false }
                    else { ask("Face ID for Start and Stop", "Start and Stop will work with a tap while your wallet is unlocked.") { faceIDOff = true } }
                })) { SettingsLabel(title: "Face ID for Start and Stop", icon: "faceid", tint: Theme.mint) }
                Text("Siri always asks you to confirm a Start or Stop, and every one shows a notification. Siri can't change power, the temperature limit or the safety stop.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
            SettingsSection("Chat") {
                toggle("Read new private messages with Siri", icon: "bubble.left", isOn: chatRead && !paranoid,
                       notice: "Siri will read private messages out loud, including the sender's name. Apple's Siri handles the text. Messages stay end-to-end encrypted on the relay.") { chatRead = $0 }
                    .disabled(paranoid)
                toggle("Send private messages with Siri", icon: "paperplane", isOn: chatSend && !paranoid,
                       notice: "Your dictated messages go through Apple's speech recognition before they're encrypted and sent. Siri reads your message back and you confirm it. Only to your existing contacts.") { chatSend = $0 }
                    .disabled(paranoid)
                if !Edition.isPublic {
                    toggle("Read the #parano1d room with Siri", icon: "person.3", isOn: roomRead && !paranoid,
                           notice: "Siri will read recent public room posts out loud.") { roomRead = $0 }
                        .disabled(paranoid)
                }
                Text(paranoid ? "Off while Parano1d mode is on, because Siri sends speech and text through Apple."
                              : "In CarPlay, messages appear once Apple approves CarPlay messaging for this app.")
                    .font(Theme.caption).foregroundStyle(paranoid ? .orange : Theme.secondary)
            }.themedRow()
            SettingsSection("Never by voice") {
                Text("Sending NOID, tokens or NFTs · approving payment requests · showing keys or the backup · pairing computers · mining power, temperature limit or safety stop.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
            }.themedRow()
        }
        .modifier(WalletSettingsSurface()).navigationTitle("Siri & voice")
        .onChange(of: paranoid) { _, on in if on { chatRead = false; chatSend = false; roomRead = false } }
        // A centered alert that holds its own copy of the choice, so "Turn on" always applies it
        // (the earlier dialog could clear the choice while closing, before the button ran).
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { choice in
            // Applied once the alert has closed: a change made while it closes was saved but not redrawn.
            Button("Turn on") { let apply = choice.apply; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { apply() } }
            Button("Cancel", role: .cancel) {}
        } message: { choice in Text(choice.notice) }
    }

    /// Off: immediate. On: Face ID, then the notice, then it turns on.
    private func toggle(_ title: String, icon: String, isOn: Bool, notice: String, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in
            if on { ask(title, notice) { set(true) } } else { set(false) }
        })) { SettingsLabel(title: title, icon: icon, tint: Theme.mint) }
    }
    private func ask(_ title: String, _ notice: String, apply: @escaping () -> Void) {
        Task {
            do {
                _ = try await wallet.requireAuthentication("Turn on \(title)", fresh: true)
                error = nil
                pending = Pending(title: "Turn on \(title)?", notice: notice, apply: apply)
            } catch { self.error = "Not changed: \(error.localizedDescription)" }
        }
    }
}

// MARK: Mining by voice

/// A paired mining computer, by its name, for "Stop mining on Garage rig".
struct RigEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mining computer"
    static let defaultQuery = RigQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct RigQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [RigEntity] {
        RigStore.shared.rigs.filter { identifiers.contains($0.id.uuidString) }.map { RigEntity(id: $0.id.uuidString, name: $0.label) }
    }
    @MainActor func suggestedEntities() async throws -> [RigEntity] {
        RigStore.shared.rigs.map { RigEntity(id: $0.id.uuidString, name: $0.label) }
    }
}

@MainActor private func pairing(for rig: RigEntity?) -> RigPairing? {
    let rigs = RigStore.shared.rigs
    if let rig { return rigs.first { $0.id.uuidString == rig.id } }
    return rigs.count == 1 ? rigs.first : nil
}

@MainActor private func sendMining(_ cmd: String, to rig: RigPairing) async -> String {
    do {
        var args: [String: String] = [:]
        if cmd == "start" { args["mode"] = "preferred" }
        if cmd == "stop" { MiningAlerts.noteStopRequested(rig.id) }
        _ = try await RigClient.command(cmd, args: args, pairing: rig)
        SiriVoice.notify(cmd == "stop" ? "Mining stopped on \(rig.label) by Siri" : "Mining started on \(rig.label) by Siri")
        await RigStore.shared.refresh(rig)
        return cmd == "stop" ? "Stopped mining on \(rig.label)." : "Started mining on \(rig.label)."
    } catch let failure as RigClient.Failure {
        if failure.phoneControlOff { return "Phone control is off on \(rig.label)." }
        return failure.offline ? "\(rig.label) is offline. Nothing was changed." : failure.message
    } catch { return error.localizedDescription }
}

struct StopMiningIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop mining"
    static let description = IntentDescription("Stops mining on one of your paired computers, after you confirm. Off until turned on in Siri & voice.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false
    @Parameter(title: "Computer") var computer: RigEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SiriVoice.canStop else { return .result(dialog: "\(SiriVoice.turnedOff)") }
        guard !RigStore.shared.rigs.isEmpty else { return .result(dialog: "No mining computers are paired.") }
        guard let rig = pairing(for: computer) else {
            throw $computer.needsValueError("Which computer?")
        }
        try await requestConfirmation(result: .result(dialog: "Stop mining on \(rig.label)?"))
        let said = await sendMining("stop", to: rig)
        return .result(dialog: "\(said)")
    }
}

struct StartMiningIntent: AppIntent {
    static let title: LocalizedStringResource = "Start mining"
    static let description = IntentDescription("Starts mining on one of your paired computers, after you confirm. Off until turned on in Siri & voice.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false
    @Parameter(title: "Computer") var computer: RigEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SiriVoice.canStart else { return .result(dialog: "\(SiriVoice.turnedOff)") }
        guard !RigStore.shared.rigs.isEmpty else { return .result(dialog: "No mining computers are paired.") }
        guard let rig = pairing(for: computer) else {
            throw $computer.needsValueError("Which computer?")
        }
        try await requestConfirmation(result: .result(dialog: "Start mining on \(rig.label)? Only start it if nothing else is mining on its GPUs."))
        let said = await sendMining("start", to: rig)
        return .result(dialog: "\(said)")
    }
}

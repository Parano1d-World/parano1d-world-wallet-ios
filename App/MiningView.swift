import SwiftUI
import CryptoKit
import Security

// Mining runs on the owner's own computer (rig). This phone never mines: it only
// pairs with the rig companion through parano1dworld.com, shows the status the
// rig reports, and sends signed start/stop commands. Commands can never change
// the payout address, pool or miner programs (enforced on the rig).
//
// Protocol (same as the website's Mining page):
//   POST https://parano1dworld.com/api/rig/pair {code, jwk:{kty,crv,x,y}, name}
//        -> {deviceId, fingerprint, name, rigId?}
//   POST https://parano1dworld.com/api/rig/cmd  {deviceId, ts, nonce, cmd, args, sig[, rig]}
//   sig = ECDSA P-256 / SHA-256 over
//         "p1w-rig-v1\n<deviceId>\n<ts>\n<nonce>\n<cmd>\n<JSON args>" , raw r||s, base64url.

/// One paired mining computer. The signing key stays in this device's Keychain
/// (Secure Enclave when available) and is never exported.
struct RigPairing: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    let deviceId: String
    let fingerprint: String
    let deviceName: String
    var rigId: String?
    let secureEnclave: Bool
    let pairedAt: Date
}

enum RigPairCode {
    /// Accepts the rig's pairing QR or a typed code:
    /// https://parano1dworld.com/#Mining/pair/CODE, https://parano1dworld.com/mining/pair/CODE,
    /// paramo1d://mining/pair/CODE, or the 12-character code itself (dashes optional).
    static func parse(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 300 else { return nil }
        var candidate = text
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "https" {
                guard let host = url.host?.lowercased(), host == "parano1dworld.com" || host == "www.parano1dworld.com",
                      url.user == nil, url.password == nil, url.port == nil else { return nil }
                let fragment = url.fragment ?? ""
                if fragment.lowercased().hasPrefix("mining/pair/") { candidate = String(fragment.dropFirst("mining/pair/".count)) }
                else if url.path.lowercased().hasPrefix("/mining/pair/") { candidate = String(url.path.dropFirst("/mining/pair/".count)) }
                else { return nil }
            } else if scheme == "paramo1d" {
                guard url.host?.lowercased() == "mining", url.path.lowercased().hasPrefix("/pair/") else { return nil }
                candidate = String(url.path.dropFirst("/pair/".count))
            } else { return nil }
        }
        let code = candidate.replacingOccurrences(of: "-", with: "").uppercased()
        guard code.count == 12, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return code
    }
    static func display(_ code: String) -> String {
        guard code.count == 12 else { return code }
        let a = code.prefix(4), b = code.dropFirst(4).prefix(4), c = code.suffix(4)
        return "\(a)-\(b)-\(c)"
    }
}

/// A pairing link opened from the camera, a QR or another app, waiting for the Mining screen.
@MainActor final class RigPairRequest: ObservableObject {
    static let shared = RigPairRequest()
    @Published var code: String?
}

enum RigKeys {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.koajent.parano1d.rig",
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    static func create(_ id: UUID) throws -> (publicKey: P256.Signing.PublicKey, enclave: Bool) {
        let data: Data, publicKey: P256.Signing.PublicKey, enclave: Bool
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            data = key.dataRepresentation; publicKey = key.publicKey; enclave = true
        } else {
            let key = P256.Signing.PrivateKey()
            data = key.rawRepresentation; publicKey = key.publicKey; enclave = false
        }
        var add = query(id); add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        _ = SecItemDelete(query(id) as CFDictionary)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AppFailure("Unable to save this phone's mining key.") }
        return (publicKey, enclave)
    }
    static func sign(_ message: Data, for pairing: RigPairing) throws -> Data {
        var q = query(pairing.id); q[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else {
            throw AppFailure("This phone's mining key is missing. Unpair and pair again.")
        }
        if pairing.secureEnclave {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data).signature(for: message).rawRepresentation
        }
        return try P256.Signing.PrivateKey(rawRepresentation: data).signature(for: message).rawRepresentation
    }
    static func remove(_ id: UUID) { _ = SecItemDelete(query(id) as CFDictionary) }
}

enum RigBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// What the rig reported in its last status answer (miner-reported, not chain-verified).
struct RigStatus {
    let running: Bool
    let mode: String?
    let pool: String?
    let worker: String?
    let hashrate: String?
    let accepted: Int?
    let rejected: Int?
    let startedAt: Date?
    let payout: String?
    let stopState: String?
    let preferredMode: String?
    let received: Date
    /// Live card readings from the rig (nvidia-smi on the rig), newest monitor pass.
    struct GPU: Identifiable { let id: Int; let name: String?; let tempC: Double?; let powerW: Double?; let powerLimitW: Double?; let defaultLimitW: Double?; let minLimitW: Double?; let maxLimitW: Double?; let fanPct: Double?; let loadPct: Double? }
    let statsAt: Date?
    let rejectPct: Double?
    let cpuThreads: Int?
    let maxThreads: Int?
    let cpuThreadsAuto: Bool
    let gpus: [GPU]
    let cpuLoadPct: Double?
    /// The rig's own tuning: GPU power as % of each card's default limit (40-100) and the safety stop temperature.
    let gpuPowerPct: Int?
    let gpuMaxC: Int?
    let safetyOn: Bool?
    let safetyEvent: String?
    let safetyEventAt: String?
    /// Hashrate in H/s with a readable unit (H/s up to TH/s); falls back to the miner's own text.
    var hashrateDisplay: String? {
        if let text = hashrate, text.range(of: #"^[0-9.,]+ ?[kKMGTP]H/s$"#, options: .regularExpression) != nil { return text }
        guard let hs = hashrateHs, hs.isFinite, hs >= 0 else { return hashrate }
        let units = ["H/s", "kH/s", "MH/s", "GH/s", "TH/s", "PH/s"]
        var value = hs, i = 0
        while value >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
        return value.formatted(.number.precision(.fractionLength(i == 0 ? 0 : 2)).grouping(.never)) + " " + units[i]
    }
    let hashrateHs: Double?
    init(_ json: [String: Any], received: Date = Date()) {
        let settings = json["settings"] as? [String: Any] ?? [:]
        let telemetry = json["telemetry"] as? [String: Any] ?? [:]
        let launched = json["launched"] as? [String: Any] ?? [:]
        running = json["running"] as? Bool ?? false
        mode = (launched["mode"] as? String) ?? (json["preferredMode"] as? String)
        preferredMode = json["preferredMode"] as? String
        pool = (launched["pool"] as? String) ?? (settings["pool"] as? String)
        worker = settings["worker"] as? String
        hashrate = telemetry["hashrateText"] as? String
        hashrateHs = (telemetry["hashrateHs"] as? NSNumber)?.doubleValue
        let stats = json["stats"] as? [String: Any] ?? [:]
        let names = Dictionary(((json["hardwareSummary"] as? [String: Any])?["gpus"] as? [[String: Any]] ?? []).compactMap { g -> (Int, String)? in
            guard let i = (g["index"] as? NSNumber)?.intValue, let n = g["name"] as? String else { return nil }; return (i, String(n.prefix(40)))
        }, uniquingKeysWith: { a, _ in a })
        let num: (Any?) -> Double? = { ($0 as? NSNumber).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil } }
        gpus = (stats["gpus"] as? [[String: Any]] ?? []).prefix(16).compactMap { g in
            guard let i = (g["index"] as? NSNumber)?.intValue else { return nil }
            return GPU(id: i, name: names[i], tempC: num(g["tempC"]), powerW: num(g["powerW"]), powerLimitW: num(g["powerLimitW"]),
                       defaultLimitW: num(g["defaultLimitW"]), minLimitW: num(g["minLimitW"]), maxLimitW: num(g["maxLimitW"]), fanPct: num(g["fanPct"]), loadPct: num(g["utilPct"]))
        }
        let iso: (String?) -> Date? = { text in
            guard let text else { return nil }
            let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        statsAt = iso(stats["at"] as? String)
        cpuLoadPct = num(stats["cpuLoadPct"])
        let tuning = json["tuning"] as? [String: Any] ?? [:]
        gpuPowerPct = (tuning["gpuPowerPct"] as? NSNumber)?.intValue
        gpuMaxC = (tuning["gpuMaxC"] as? NSNumber)?.intValue
        safetyOn = (tuning["safetyOn"] as? String).map { $0 == "on" }
        cpuThreads = (tuning["cpuThreads"] as? NSNumber)?.intValue
        maxThreads = (tuning["maxThreads"] as? NSNumber)?.intValue
        cpuThreadsAuto = (tuning["cpuThreadsAuto"] as? String) == "on"
        // The rig's own reject % when it sends one; otherwise worked out from the two counts.
        if let pct = num(telemetry["rejectPct"]) { rejectPct = pct }
        else if let a = (telemetry["accepted"] as? NSNumber)?.intValue, let r = (telemetry["rejected"] as? NSNumber)?.intValue, a + r > 0 { rejectPct = Double(r) * 100 / Double(a + r) }
        else { rejectPct = nil }
        safetyEvent = ((json["safetyEvent"] as? [String: Any])?["reason"] as? String).map { String($0.prefix(120)) }
        safetyEventAt = ((json["safetyEvent"] as? [String: Any])?["at"] as? String).map { String($0.prefix(40)) }
        accepted = (telemetry["accepted"] as? NSNumber)?.intValue
        rejected = (telemetry["rejected"] as? NSNumber)?.intValue
        startedAt = (json["startedAt"] as? String).flatMap { text in
            let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        let candidates = [json["payout"], settings["payout"], settings["payoutAddress"], settings["wallet"], settings["address"], launched["wallet"]]
        payout = candidates.compactMap { $0 as? String }.first { AddressValidator.valid($0) }
        stopState = (json["stop"] as? [String: Any])?["state"] as? String
        self.received = received
    }
}

enum RigClient {
    static let origin = URL(string: "https://parano1dworld.com")!
    private static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    struct Failure: LocalizedError {
        let message: String; let status: Int; let offline: Bool
        var code: String? = nil
        var errorDescription: String? { message }
        /// The computer's owner has "Allow control from a phone" turned off (HTTP 423). The pairing stays valid.
        var phoneControlOff: Bool { status == 423 && code == "phone-control-off" }
    }

    private static func post(_ name: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: origin.appendingPathComponent("api/rig/\(name)"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("parano1d-wallet-ios", forHTTPHeaderField: "X-P1W-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard request.httpBody!.count <= 4096 else { throw Failure(message: "Request too large.", status: 413, offline: false) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard data.count <= 64_000, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "The mining service returned an unreadable answer.", status: status, offline: false)
        }
        if status != 200 || json["ok"] as? Bool == false {
            let message = (json["error"] as? String).map { String($0.prefix(200)) } ?? "Mining request failed."
            throw Failure(message: message, status: status, offline: json["rig"] as? String == "offline", code: (json["code"] as? String).map { String($0.prefix(64)) })
        }
        return json
    }

    static func pair(code: String, name: String, label: String) async throws -> RigPairing {
        let id = UUID()
        let key = try RigKeys.create(id)
        let raw = key.publicKey.rawRepresentation          // x || y, 32 bytes each
        let jwk: [String: Any] = ["kty": "EC", "crv": "P-256",
                                  "x": RigBase64URL.encode(raw.prefix(32)), "y": RigBase64URL.encode(raw.suffix(32))]
        do {
            let result = try await post("pair", ["code": RigPairCode.display(code), "jwk": jwk, "name": name])
            guard let deviceId = result["deviceId"] as? String, !deviceId.isEmpty, deviceId.count <= 128 else {
                throw Failure(message: "The rig did not confirm the pairing.", status: 502, offline: false)
            }
            return RigPairing(id: id, label: label, deviceId: deviceId,
                              fingerprint: (result["fingerprint"] as? String) ?? "", deviceName: (result["name"] as? String) ?? name,
                              rigId: result["rigId"] as? String, secureEnclave: key.enclave, pairedAt: Date())
        } catch {
            RigKeys.remove(id)
            throw error
        }
    }

    static func canonical(deviceId: String, ts: Int64, nonce: String, cmd: String, argsJSON: String) -> String {
        ["p1w-rig-v1", deviceId, String(ts), nonce, cmd, argsJSON].joined(separator: "\n")
    }

    static func command(_ cmd: String, args: [String: String] = [:], pairing: RigPairing) async throws -> [String: Any] {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var nonceBytes = [UInt8](repeating: 0, count: 18)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else { throw AppFailure("Random generator unavailable.") }
        let nonce = RigBase64URL.encode(Data(nonceBytes))
        // Match JavaScript's JSON.stringify for flat string maps: keys in insertion order, no spaces.
        let argsJSON = "{" + args.keys.sorted().map { key in
            let k = String(data: try! JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed), encoding: .utf8)!
            let v = String(data: try! JSONSerialization.data(withJSONObject: args[key]!, options: .fragmentsAllowed), encoding: .utf8)!
            return k + ":" + v
        }.joined(separator: ",") + "}"
        let message = Data(canonical(deviceId: pairing.deviceId, ts: ts, nonce: nonce, cmd: cmd, argsJSON: argsJSON).utf8)
        let signature = try RigKeys.sign(message, for: pairing)
        var body: [String: Any] = ["deviceId": pairing.deviceId, "ts": ts, "nonce": nonce, "cmd": cmd,
                                   "args": args, "sig": RigBase64URL.encode(signature)]
        if let rig = pairing.rigId { body["rig"] = rig }
        return try await post("cmd", body)
    }
}

@MainActor final class RigStore: ObservableObject {
    /// One list for the Mining tab and the pairing sheet.
    static let shared = RigStore()
    static let storageKey = "mining.rigs.v1"
    @Published private(set) var rigs: [RigPairing] = []
    @Published var statuses: [UUID: RigStatus] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var revoked: Set<UUID> = []
    /// Computers whose owner has phone control turned off; still paired, not offline.
    @Published var controlOff: Set<UUID> = []
    /// Opens the drag-to-reorder list from any computer's menu or the Mining page.
    @Published var showReorder = false
    private var lastControlOffCheck: [UUID: Date] = [:]
    init() {
        load()
        #if DEBUG
        if StoreShots.on && !ProcessInfo.processInfo.arguments.contains("-storeShotsNoRigs") {
            let now = Date()
            rigs = StoreShots.mining.enumerated().map { index, rig in
                RigPairing(id: UUID(), label: rig.label, deviceId: "rig\(index + 1)", fingerprint: ["3fa9c27e", "b81d40c5"][index % 2], deviceName: rig.label,
                           rigId: nil, secureEnclave: true, pairedAt: now.addingTimeInterval(-86_400 * 12))
            }
            let formatter = ISO8601DateFormatter()
            for (rig, sample) in zip(rigs, StoreShots.mining) {
                let gpu = sample.mode == "gpu"
                var json: [String: Any] = ["running": true, "preferredMode": sample.mode,
                    "launched": ["mode": sample.mode, "pool": "pool.parano1dworld.com"],
                    "settings": ["worker": sample.label.lowercased().replacingOccurrences(of: " ", with: "-"), "payout": StoreShots.payout],
                    "telemetry": ["hashrateText": sample.hashrate, "accepted": sample.accepted, "rejected": gpu ? 41 : 0],
                    "startedAt": formatter.string(from: now.addingTimeInterval(-sample.hours * 3600)),
                    "tuning": ["gpuPowerPct": 85, "gpuMaxC": 83, "safetyOn": "on", "cpuThreads": 8, "maxThreads": 16, "cpuThreadsAuto": "on"]]
                if gpu {
                    json["hardwareSummary"] = ["gpus": [["index": 0, "name": "GeForce RTX 4080"], ["index": 1, "name": "GeForce RTX 4070"]]]
                    json["stats"] = ["at": formatter.string(from: now), "gpus": [
                        ["index": 0, "tempC": 64, "powerW": 268, "powerLimitW": 272, "defaultLimitW": 320, "minLimitW": 150, "maxLimitW": 360, "utilPct": 99, "fanPct": 58],
                        ["index": 1, "tempC": 76, "powerW": 166, "powerLimitW": 170, "defaultLimitW": 200, "minLimitW": 100, "maxLimitW": 220, "utilPct": 98, "fanPct": 71]]]
                }
                statuses[rig.id] = RigStatus(json)
            }
        }
        #endif
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([RigPairing].self, from: data) { rigs = saved }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(rigs) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
    func add(_ pairing: RigPairing) { rigs.append(pairing); save() }
    func rename(_ id: UUID, to label: String) {
        guard let index = rigs.firstIndex(where: { $0.id == id }) else { return }
        rigs[index].label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)); save()
    }
    /// Reorders computers for people with several; the order is saved on this phone.
    func move(_ id: UUID, by offset: Int) {
        guard let index = rigs.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rigs.indices.contains(target) else { return }
        rigs.swapAt(index, target); save()
    }
    func move(fromOffsets source: IndexSet, toOffset destination: Int) { rigs.move(fromOffsets: source, toOffset: destination); save() }
    func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard let index = rigs.firstIndex(where: { $0.id == id }) else { return false }
        return rigs.indices.contains(index + offset)
    }
    func remove(_ id: UUID) {
        rigs.removeAll { $0.id == id }; statuses[id] = nil; errors[id] = nil; revoked.remove(id); controlOff.remove(id); lastControlOffCheck[id] = nil
        RigKeys.remove(id); MiningAlerts.forget(id); save(); saveWidgetSummary()
    }
    func refresh(_ pairing: RigPairing) async {
        #if DEBUG
        if StoreShots.on { return }
        #endif
        do {
            let json = try await RigClient.command("status", pairing: pairing)
            let status = RigStatus(json)
            statuses[pairing.id] = status; errors[pairing.id] = nil; revoked.remove(pairing.id); controlOff.remove(pairing.id)
            MiningAlerts.observe(pairing, status: status)
        } catch let failure as RigClient.Failure {
            if failure.phoneControlOff { markControlOff(pairing.id); return }
            if failure.status == 401 { revoked.insert(pairing.id) }
            errors[pairing.id] = failure.offline ? "The rig, its companion or the tunnel is offline. Mining, if running, continues on the rig." : failure.message
            if failure.offline { MiningAlerts.observeOffline(pairing) }
        } catch {
            errors[pairing.id] = "Couldn't reach parano1dworld.com. Check your connection."
        }
    }
    func markControlOff(_ id: UUID) {
        controlOff.insert(id); statuses[id] = nil; errors[id] = nil; lastControlOffCheck[id] = Date()
    }
    /// Automatic refreshes check a computer with phone control off at most once a minute.
    func refreshAll(automatic: Bool = false) async {
        for rig in rigs {
            if automatic, controlOff.contains(rig.id), let last = lastControlOffCheck[rig.id], Date().timeIntervalSince(last) < 60 { continue }
            await refresh(rig)
        }
        saveWidgetSummary()
    }
    /// What the Mining widget and the "How are my rigs" shortcut show: names, state, hashrate, hottest GPU, any safety stop.
    func summary() -> PhoneWidgetData.Mining {
        PhoneWidgetData.Mining(rigs: rigs.map { rig in
            let status = statuses[rig.id]
            let hottest = status?.gpus.compactMap(\.tempC).max().map { Int($0.rounded()) }
            return .init(name: String(rig.label.prefix(30)), online: (status != nil && errors[rig.id] == nil) || controlOff.contains(rig.id),
                         running: status?.running ?? false, hashrate: status?.running == true ? status?.hashrateDisplay : nil,
                         shares: status?.accepted,
                         hottestC: hottest, alert: controlOff.contains(rig.id) ? "Phone control is off"
                            : status?.safetyEvent.map { "Safety stop: " + String($0.prefix(60)) })
        }, updated: Date())
    }
    func saveWidgetSummary() {
        #if DEBUG
        if StoreShots.on { return }
        #endif
        PhoneWidgetData.saveMining(rigs.isEmpty ? nil : summary())
        Parano1dShortcuts.updateAppShortcutParameters() // so Siri knows each computer's name
    }
}

struct MiningView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle = "system"
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.openURL) private var openURL
    @Environment(\.walletTabActive) private var tabActive
    @ObservedObject private var store = RigStore.shared
    @ObservedObject private var request = RigPairRequest.shared
    @State private var scanning = false
    @State private var pendingCode: String?
    @State private var typedCode = ""
    @State private var showTypeCode = false
    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    /// Shown in a sheet (pairing link with no Mining tab): refresh without the tab-active signal.
    private let standalone: Bool
    init(standalone: Bool = false) { self.standalone = standalone }
    @AppStorage("mining.layout.tiles") private var tiles = false
    @State private var selected: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if store.rigs.isEmpty { emptyState }
                else if store.rigs.count == 1, let rig = store.rigs.first { RigCard(rig: rig, store: store) }
                else {
                    summary
                    if tiles { tileGrid } else { pager }
                    Button { store.showReorder = true } label: {
                        Label("Reorder computers", systemImage: "line.3.horizontal").font(Theme.caption)
                    }.foregroundStyle(Theme.mint)
                }
                if !store.rigs.isEmpty {
                    Button { scanning = true } label: {
                        HStack { SettingsLabel(title: "Add another computer", icon: "plus.circle"); Spacer()
                            Image(systemName: "qrcode.viewfinder").foregroundStyle(Theme.mint) }
                            .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).themedCard(16)
                    NavigationLink { MiningAlertsSettingsView() } label: {
                        HStack { SettingsLabel(title: "Mining alerts", icon: "bell.badge"); Spacer()
                            Text(MiningAlerts.anyOn ? "On" : "Set up").font(Theme.caption).foregroundStyle(MiningAlerts.anyOn ? Theme.mint : Theme.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary) }
                            .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).themedCard(16)
                }
                Button { openURL(URL(string: "https://parano1dworld.com/#Mining")!) } label: {
                    Label("First time mining? Guides for a PC or laptop", systemImage: "book")
                }.font(Theme.subheadline).foregroundStyle(Theme.mint).frame(maxWidth: .infinity, alignment: .leading)
                Text("Mining runs on your own computer. This phone never mines; it shows what your rig reports and can start or stop it. The payout address, pool and miner programs can only be changed on the rig itself.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
                Text("Figures are reported by your rig's miner, not verified by the chain. Hashrate is not earnings: payouts arrive as NOID in your wallet.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(AmbientBackground()).foregroundStyle(Theme.text)
        .navigationTitle("Mining").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $store.showReorder) {
            NavigationStack {
                List {
                    ForEach(store.rigs) { rig in
                        HStack(spacing: 12) { SettingsIcon(systemName: "desktopcomputer"); Text(rig.label).lineLimit(1) }
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in for index in offsets.sorted(by: >) where store.rigs.indices.contains(index) { store.remove(store.rigs[index].id) } }
                }
                .environment(\.editMode, .constant(.active))
                .navigationTitle("Reorder computers").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.showReorder = false } } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { scanning = true } label: { Label("Scan pairing QR", systemImage: "qrcode.viewfinder") }
                    Button { showTypeCode = true } label: { Label("Enter code", systemImage: "keyboard") }
                    Button { openURL(URL(string: "https://parano1dworld.com/#Mining")!) } label: { Label("Set up a mining computer", systemImage: "arrow.up.right") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.mint)
                } primaryAction: { scanning = true }
                .accessibilityLabel("Add a mining computer")
                .accessibilityHint("Tap to scan its pairing QR. Press and hold for more options.")
            }
        }
        .task { await store.refreshAll() }
        .refreshable { await store.refreshAll() }
        .onReceive(ticker) { _ in if (tabActive || standalone) && !wallet.locked { Task { await store.refreshAll(automatic: true) } } }
        .onAppear { takeRequest(); if selected == nil { selected = store.rigs.first?.id } }
        .onChange(of: store.rigs.map(\.id)) { _, ids in if selected.map({ !ids.contains($0) }) ?? true { selected = ids.last } }
        .onChange(of: request.code) { _, _ in takeRequest() }
        .sheet(isPresented: $scanning) {
            RigPairScanner { code in pendingCode = code }
        }
        .sheet(item: Binding(get: { pendingCode.map(PendingCode.init) }, set: { pendingCode = $0?.code })) { item in
            NavigationStack { RigPairConfirm(code: item.code, store: store) }
        }
        .alert("Enter pairing code", isPresented: $showTypeCode) {
            TextField("XXXX-XXXX-XXXX", text: $typedCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Continue") { if let code = RigPairCode.parse(typedCode) { pendingCode = code }; typedCode = "" }
            Button("Cancel", role: .cancel) { typedCode = "" }
        } message: { Text("Use the 12-character code shown under the rig's pairing QR.") }
    }

    private func dot(_ rig: RigPairing) -> Color {
        if store.revoked.contains(rig.id) || store.errors[rig.id] != nil || store.controlOff.contains(rig.id) { return .orange }
        return store.statuses[rig.id]?.running == true ? Theme.mint : Theme.secondary
    }
    /// Count of computers mining, and the Cards / Tiles switch.
    private var summary: some View {
        let mining = store.rigs.filter { store.statuses[$0.id]?.running == true && store.errors[$0.id] == nil }.count
        let offline = store.rigs.filter { (store.errors[$0.id] != nil || store.revoked.contains($0.id)) && !store.controlOff.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(mining > 0 ? Theme.mint : Theme.secondary).frame(width: 9, height: 9)
                Text("\(mining) of \(store.rigs.count) mining").font(Theme.headline)
                if offline > 0 { Text("· \(offline) offline").font(Theme.subheadline).foregroundStyle(.orange) }
                Spacer()
            }
            Picker("Layout", selection: $tiles) {
                Label("Cards", systemImage: "rectangle.on.rectangle").tag(false)
                Label("Tiles", systemImage: "square.grid.2x2").tag(true)
            }.pickerStyle(.segmented)
        }
    }
    /// Swipe between computers; the name chips above jump straight to one.
    private var pager: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.rigs) { rig in
                        Button { withAnimation { selected = rig.id } } label: {
                            HStack(spacing: 6) {
                                Circle().fill(dot(rig)).frame(width: 7, height: 7)
                                Text(rig.label).font(Theme.caption.weight(.semibold)).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selected == rig.id ? Theme.mint.opacity(0.18) : Theme.soft, in: Capsule())
                            .overlay(Capsule().stroke(selected == rig.id ? Theme.mint : Theme.line, lineWidth: 1))
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(selected == rig.id ? .isSelected : [])
                    }
                }.padding(.horizontal, 1)
            }
            TabView(selection: Binding(get: { selected.flatMap { id in store.rigs.contains { $0.id == id } ? id : nil } ?? store.rigs.first?.id }, set: { selected = $0 })) {
                ForEach(store.rigs) { rig in
                    ScrollView { RigCard(rig: rig, store: store).padding(.horizontal, 2).padding(.bottom, 34) }
                        .tag(Optional(rig.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(height: 560)
        }
    }
    /// Compact overview of every computer; tap one to open its card.
    private var tileGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(store.rigs) { rig in
                let status = store.statuses[rig.id]
                Button { selected = rig.id; withAnimation { tiles = false } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(dot(rig)).frame(width: 9, height: 9)
                            Text(rig.label).font(Theme.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        Text(store.controlOff.contains(rig.id) ? "Phone control off" : store.errors[rig.id] != nil ? "Offline" : status?.running == true ? (status?.hashrateDisplay ?? "Mining") : status == nil ? "Checking…" : "Idle")
                            .font(Theme.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(store.errors[rig.id] != nil || store.controlOff.contains(rig.id) ? .orange : Theme.text)
                        Text(status.map { "\($0.accepted ?? 0) shares · " + $0.received.formatted(date: .omitted, time: .shortened) } ?? "—")
                            .font(Theme.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .padding(14).themedCard(16)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(dot(rig).opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
                .contextMenu {
                    Button { selected = rig.id; tiles = false } label: { Label("Open", systemImage: "rectangle.on.rectangle") }
                    Button { Task { await store.refresh(rig) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    if store.rigs.count > 1 { Button { store.showReorder = true } label: { Label("Reorder computers", systemImage: "line.3.horizontal") } }
                }
                .accessibilityLabel("\(rig.label), " + (store.controlOff.contains(rig.id) ? "phone control off" : store.errors[rig.id] != nil ? "offline" : status?.running == true ? "mining \(status?.hashrateDisplay ?? "")" : "idle"))
            }
        }
    }
    private struct PendingCode: Identifiable { let code: String; var id: String { code } }
    private func takeRequest() {
        if let code = request.code { request.code = nil; pendingCode = code }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image("MiningEmblem").resizable().interpolation(.high).scaledToFit().frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mining").font(Theme.editorial(26))
                Text(store.rigs.isEmpty ? "Watch and control your own computers." : "Watch and control your own computers · \(store.rigs.count) paired")
                    .font(Theme.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(14).themedCard(18)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Color.clear.frame(height: 170)
                .overlay(Image("MiningRigHero").resizable().interpolation(.high).scaledToFill(), alignment: .trailing)
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        .overlay(alignment: .bottomLeading) {
                            Text("Your rig, in your pocket").font(Theme.editorial(20)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 3, y: 1).padding(14)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, -4).padding(.top, -4)
                .accessibilityHidden(true)
            Text("Not connected").font(Theme.headline)
            Text("On your mining computer, open the Parano1d Mining dashboard and press Show pairing QR. Then scan it here. You can pair more than one computer, for example at different locations.")
                .font(Theme.subheadline).foregroundStyle(Theme.secondary)
            Button { scanning = true } label: {
                Label("Scan pairing QR", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }.buttonStyle(MintButtonStyle())
            Button("Enter code instead") { showTypeCode = true }.font(Theme.subheadline)
            Button {
                openURL(URL(string: "https://parano1dworld.com/#Mining")!)
            } label: { Label("Set up a mining computer", systemImage: "arrow.up.right") }.font(Theme.subheadline)
        }.padding(18).themedCard(18)
    }
}

/// Confirms a pairing code from the camera, another app or typing, and names the location.
struct RigPairConfirm: View {
    let code: String
    @ObservedObject var store: RigStore
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var working = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("Pairing code", value: RigPairCode.display(code))
                TextField("Name or location (for example Home rig)", text: $label)
            } footer: {
                Text("Only pair a computer you own. This phone gets its own key, so you can revoke it on the rig at any time. The code works once and expires after 10 minutes.")
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            Section {
                Button {
                    Task { await pair() }
                } label: {
                    HStack { Text(working ? "Pairing…" : "Pair this computer"); if working { Spacer(); ProgressView() } }
                }.disabled(working || wallet.locked)
            }
        }
        .navigationTitle("Pair mining computer").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear { if label.isEmpty { label = store.rigs.isEmpty ? "Mining computer" : "Mining computer \(store.rigs.count + 1)" } }
    }
    private func pair() async {
        working = true; error = nil
        defer { working = false }
        do {
            _ = try await wallet.requireAuthentication("Pair a mining computer", fresh: true)
            let name = String((UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").prefix(40))
            let pairing = try await RigClient.pair(code: code, name: name, label: label.isEmpty ? "Mining computer" : String(label.prefix(40)))
            store.add(pairing)
            await store.refresh(pairing)
            dismiss()
        } catch let failure as RigClient.Failure {
            error = failure.phoneControlOff ? "Phone control is off on that computer. Turn on \"Allow control from a phone\" in its mining dashboard, then show a new pairing QR."
                : failure.offline ? "The rig, its companion or the tunnel is offline. Try again when the computer is on." : failure.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RigCard: View {
    let rig: RigPairing
    @ObservedObject var store: RigStore
    @EnvironmentObject private var wallet: WalletState
    @State private var busy = false
    @State private var actionError: String?
    @State private var powerDraft: Double?
    @State private var tempDraft: Int?
    @State private var safetyDraft: Bool?
    @State private var threadsDraft: Int?
    @State private var confirmSafetyOff = false
    @State private var tuneResult: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmUnpair = false
    private var status: RigStatus? { store.statuses[rig.id] }
    private var state: (text: String, color: Color) {
        if store.revoked.contains(rig.id) { return ("Not paired", .orange) }
        if store.controlOff.contains(rig.id) { return ("Phone control off", .orange) }
        if store.errors[rig.id] != nil { return ("Offline", .orange) }
        guard let status else { return ("Checking…", Theme.secondary) }
        return status.running ? ("Mining", Theme.mint) : ("Idle", Theme.secondary)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SettingsIcon(systemName: "desktopcomputer")
                Text(rig.label).font(Theme.headline).lineLimit(1)
                Spacer()
                HStack(spacing: 5) { Circle().fill(state.color).frame(width: 7, height: 7); Text(state.text) }
                    .font(Theme.caption.weight(.semibold)).foregroundStyle(state.color)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(state.color.opacity(0.14), in: Capsule()).overlay(Capsule().strokeBorder(state.color.opacity(0.35), lineWidth: 1))
                Menu {
                    Button("Rename") { newName = rig.label; renaming = true }
                    if store.rigs.count > 1 { Button { store.showReorder = true } label: { Label("Reorder computers", systemImage: "line.3.horizontal") } }
                    Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("Options for \(rig.label)")
            }
            if store.controlOff.contains(rig.id) {
                Text("Phone control is turned off on this computer. To use it from here, open its mining dashboard on that computer and turn on **Allow control from a phone**. Mining (if running) carries on by itself.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { Task { busy = true; await store.refresh(rig); busy = false } } label: {
                        Label(busy ? "Checking…" : "Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }.buttonStyle(MintButtonStyle()).disabled(busy)
                    Button(role: .destructive) { confirmUnpair = true } label: {
                        Label("Unpair", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).tint(.orange)
                }
            }
            if let issue = store.errors[rig.id] {
                Text(issue).font(Theme.caption).foregroundStyle(.orange)
            }
            if let status, !store.controlOff.contains(rig.id) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    statTile("bolt", "Hashrate", status.running ? (status.hashrateDisplay ?? "waiting…") : "—")
                    statTile("checkmark.circle", "Shares", status.running || (status.accepted ?? 0) > 0 ? "\(status.accepted ?? 0)" : "—",
                             detail: (status.rejected ?? 0) > 0 ? "\(status.rejected ?? 0) rejected" + (status.rejectPct.map { " (" + $0.formatted(.number.precision(.fractionLength(1))) + "%)" } ?? "") : nil)
                    statTile("clock", "Running", status.running ? (status.startedAt.map { $0.formatted(.relative(presentation: .named)).replacingOccurrences(of: " ago", with: "") } ?? "—") : "—")
                    statTile("cpu", "Mode", modeName(status.mode))
                }
                if let pct = status.rejectPct, pct >= 5 {
                    Label("Rejects are high. Common causes: two miners on the same GPUs, a GPU overclock that's too high, or a weak connection to the pool.", systemImage: "exclamationmark.triangle")
                        .font(Theme.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = status.safetyEvent {
                    Label("Safety stop: \(reason)", systemImage: "thermometer.high")
                        .font(Theme.caption.weight(.semibold)).foregroundStyle(.white).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !status.gpus.isEmpty { gpuReadings(status) }
                if status.gpuPowerPct != nil || status.cpuThreads != nil { powerControls(status) }
                // A pool only applies to GPU mining; CPU mining runs solo.
                if isGPU(status.mode), let pool = status.pool {
                    detailRow("server.rack", "Pool", pool)
                    if let worker = status.worker { detailRow("person.crop.square", "Worker", worker) }
                }
                HStack(alignment: .top, spacing: 12) {
                    SettingsIcon(systemName: "wallet.pass")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.payout.map(isMine) == true ? "Your payout address" : "Payout address").font(Theme.caption).foregroundStyle(Theme.secondary)
                        Text(status.payout.map(shortAddress) ?? "Not reported").font(.footnote.monospaced()).textSelection(.enabled)
                        if let payout = status.payout, !isMine(payout) {
                            Label("Not a wallet in this app", systemImage: "exclamationmark.triangle").font(Theme.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.top, 2)
                if let stop = status.stopState {
                    Text(stop == "confirmed" ? "Stopped (confirmed: the miner exited)." : stop == "timeout" ? "Stop not confirmed after 60 s. Check the rig." : "Stopping… waiting for the miner to exit.")
                        .font(Theme.caption).foregroundStyle(stop == "timeout" ? .orange : Theme.secondary)
                }
                Text("Updated " + status.received.formatted(date: .omitted, time: .standard) + " · reported by the rig")
                    .font(Theme.caption2).foregroundStyle(Theme.secondary)
            }
            if let actionError { Text(actionError).font(Theme.caption).foregroundStyle(.orange) }
            if store.revoked.contains(rig.id) {
                Text("This phone is no longer paired with that computer. Unpair it here, then scan a new pairing QR.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
                Button(role: .destructive) { confirmUnpair = true } label: {
                    Label("Unpair and remove", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).tint(.orange)
            } else if let status, store.errors[rig.id] == nil, !store.controlOff.contains(rig.id) {
                Button {
                    Task { await send(status.running ? "stop" : "start") }
                } label: {
                    Label(busy ? "Sending…" : status.running ? "Stop mining" : "Start mining", systemImage: status.running ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MintButtonStyle()).disabled(busy || wallet.locked)
                if !status.running {
                    Text("Only start this if nothing else is mining on this computer's GPUs.").font(Theme.caption2).foregroundStyle(Theme.secondary)
                }
            }
            Text("Paired as \(rig.deviceName)" + (rig.fingerprint.isEmpty ? "" : " · key \(rig.fingerprint)"))
                .font(Theme.caption2).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(16).themedCard(18)
        .alert("Rename", isPresented: $renaming) {
            TextField("Name or location", text: $newName)
            Button("Save") { store.rename(rig.id, to: newName.isEmpty ? rig.label : newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Unpair \(rig.label)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair this phone", role: .destructive) { store.remove(rig.id) }
        } message: {
            Text("This removes the pairing and its key from this phone. Also revoke this phone in the rig's dashboard. Mining on the computer is not affected.")
        }
    }
    /// One row per card: temperature (coloured against the rig's limit), power used of the limit, fan and load.
    private func gpuReadings(_ status: RigStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("GPUs", systemImage: "rectangle.stack").font(Theme.subheadline)
            ForEach(status.gpus) { gpu in
                VStack(alignment: .leading, spacing: 6) {
                    Text("GPU \(gpu.id)" + (gpu.name.map { " · " + $0 } ?? "")).font(Theme.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        reading("thermometer.medium", gpu.tempC.map { "\(Int($0.rounded())) °C" } ?? "—", color: tempColor(gpu.tempC, limit: status.gpuMaxC))
                        reading("bolt.fill", gpu.powerW.map { w in "\(Int(w.rounded())) W" + (gpu.powerLimitW.map { " of \(Int($0.rounded())) W" } ?? "") } ?? "—")
                        reading("fan", gpu.fanPct.map { "\(Int($0.rounded()))%" } ?? "—")
                    }
                    if let load = gpu.loadPct { Text("Load \(Int(load.rounded()))%").font(Theme.caption2).foregroundStyle(Theme.secondary) }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.soft.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
            if let at = status.statsAt { Text("Updated " + at.formatted(date: .omitted, time: .standard)).font(Theme.caption2).foregroundStyle(Theme.secondary) }
        }
    }
    private func tempColor(_ temp: Double?, limit: Int?) -> Color {
        guard let temp else { return Theme.text }
        let max = Double(limit ?? 85)
        return temp >= max ? .red : temp >= max - 10 ? .orange : Theme.mint
    }
    private func reading(_ icon: String, _ value: String, color: Color? = nil) -> some View {
        Label(value, systemImage: icon).font(.footnote.monospacedDigit()).foregroundStyle(color ?? Theme.text)
            .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Watts a power % means for one card: its default limit × % / 100, kept inside the card's own range.
    private func watts(_ gpu: RigStatus.GPU, pct: Double) -> Int? {
        guard let def = gpu.defaultLimitW else { return nil }
        var w = def * pct / 100
        if let lo = gpu.minLimitW { w = max(w, lo) }
        if let hi = gpu.maxLimitW { w = min(w, hi) }
        return Int(w.rounded())
    }
    /// GPU power level, temperature limit and safety stop (GPU rigs), CPU threads (CPU mode). Saved on the rig,
    /// which checks every range again; payout, pool and miner programs stay rig-only.
    private func powerControls(_ status: RigStatus) -> some View {
        let pct = powerDraft ?? Double(status.gpuPowerPct ?? 100)
        let maxC = tempDraft ?? (status.gpuMaxC ?? 85)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Controls", systemImage: "slider.horizontal.3").font(Theme.subheadline)
            if status.gpuPowerPct != nil, !status.gpus.isEmpty {
                HStack {
                    Text("GPU power").font(Theme.subheadline)
                    Spacer()
                    Text("\(Int(pct))%").font(Theme.subheadline.monospacedDigit())
                }
                Slider(value: Binding(get: { pct }, set: { powerDraft = $0 }), in: 40...100, step: 5)
                    .tint(Theme.mint).accessibilityLabel("GPU power level")
                let perCard = status.gpus.compactMap { g in watts(g, pct: pct).map { "GPU \(g.id) ≈ \($0) W" } }
                if !perCard.isEmpty { Text(perCard.joined(separator: " · ")).font(Theme.caption2).foregroundStyle(Theme.secondary) }
                Stepper(value: Binding(get: { maxC }, set: { tempDraft = $0 }), in: 60...95, step: 1) {
                    HStack {
                        Text("Temperature limit").font(Theme.subheadline)
                        Spacer()
                        Text("\(maxC) °C").font(Theme.subheadline.monospacedDigit())
                    }
                }
                Toggle(isOn: Binding(get: { safetyDraft ?? (status.safetyOn ?? true) }, set: { on in
                    if on { safetyDraft = true } else { confirmSafetyOff = true }
                })) { Text("Safety stop").font(Theme.subheadline) }.tint(Theme.mint)
                Text((safetyDraft ?? status.safetyOn ?? true) ? "Mining stops if a GPU reaches the limit." : "The temperature stop is off on this computer.")
                    .font(Theme.caption2).foregroundStyle((safetyDraft ?? status.safetyOn ?? true) ? Theme.secondary : .orange)
            }
            if !isGPU(status.mode), let threads = status.cpuThreads {
                Stepper(value: Binding(get: { threadsDraft ?? threads }, set: { threadsDraft = $0 }), in: 1...max(status.maxThreads ?? threads, 1)) {
                    HStack {
                        Text("CPU threads").font(Theme.subheadline)
                        Spacer()
                        Text("\(threadsDraft ?? threads)" + (status.cpuThreadsAuto && threadsDraft == nil ? " (auto)" : "")).font(Theme.subheadline.monospacedDigit())
                    }
                }
            }
            let changed = (powerDraft.map { Int($0) != status.gpuPowerPct } ?? false) || (tempDraft.map { $0 != status.gpuMaxC } ?? false)
                || (safetyDraft.map { $0 != status.safetyOn } ?? false) || (threadsDraft.map { $0 != status.cpuThreads } ?? false)
            if changed {
                Button {
                    Task { await applyTuning(status) }
                } label: {
                    Label(busy ? "Saving…" : "Apply on \(rig.label)", systemImage: "checkmark").frame(maxWidth: .infinity)
                }.buttonStyle(MintButtonStyle()).disabled(busy || wallet.locked)
                if status.running { Text("A new power level restarts the miner briefly.").font(Theme.caption2).foregroundStyle(Theme.secondary) }
            }
            if let tuneResult { Text(tuneResult).font(Theme.caption).foregroundStyle(Theme.mint) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .confirmationDialog("Turn off the safety stop?", isPresented: $confirmSafetyOff, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { safetyDraft = false }
        } message: {
            Text("Mining will keep going even if a GPU passes \(maxC) °C.")
        }
    }
    private func applyTuning(_ status: RigStatus) async {
        busy = true; actionError = nil; tuneResult = nil
        defer { busy = false }
        do {
            _ = try await wallet.requireAuthentication("Change mining settings on \(rig.label)")
            var args: [String: String] = [:]
            if let p = powerDraft, Int(p) != status.gpuPowerPct { args["gpuPowerPct"] = String(Int(p)) }
            if let c = tempDraft, c != status.gpuMaxC { args["gpuMaxC"] = String(c) }
            if let on = safetyDraft, on != status.safetyOn { args["safetyOn"] = on ? "on" : "off" }
            if let n = threadsDraft, n != status.cpuThreads { args["cpuThreads"] = String(n) }
            guard !args.isEmpty else { return }
            let reply = try await RigClient.command("tune", args: args, pairing: rig)
            let applied = reply["applied"] as? String ?? "saved"
            tuneResult = applied == "saved" ? "Saved on \(rig.label)." : applied.prefix(1).uppercased() + applied.dropFirst() + "."
            powerDraft = nil; tempDraft = nil; safetyDraft = nil; threadsDraft = nil
            try? await Task.sleep(nanoseconds: 800_000_000)
            await store.refresh(rig)
        } catch let failure as RigClient.Failure {
            if failure.phoneControlOff { store.markControlOff(rig.id); return }
            actionError = failure.offline ? "The rig is offline. Nothing was changed." : failure.message
            if failure.status == 401 { store.revoked.insert(rig.id) }
        } catch {
            actionError = error.localizedDescription
        }
    }
    private func statTile(_ icon: String, _ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(Theme.caption).foregroundStyle(Theme.secondary).labelStyle(.titleAndIcon)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                if let detail { Text("· " + detail).font(Theme.caption2).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Theme.soft.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
    private func detailRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon)
            Text(title).font(Theme.subheadline)
            Spacer()
            Text(value).font(Theme.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
    private func isGPU(_ mode: String?) -> Bool { (mode ?? "").lowercased().contains("gpu") }
    private func modeName(_ mode: String?) -> String {
        guard let mode, !mode.isEmpty else { return "—" }
        let m = mode.lowercased()
        return m.contains("gpu") ? "GPU" : m.contains("cpu") ? "CPU" : mode.capitalized
    }
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(Theme.caption).foregroundStyle(Theme.secondary)
            Text(value).font(Theme.subheadline).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }
    private func shortAddress(_ address: String) -> String {
        address.count > 18 ? String(address.prefix(8)) + "…" + String(address.suffix(8)) : address
    }
    private func isMine(_ address: String) -> Bool {
        address == wallet.address || wallet.accounts.contains { $0.address == address }
    }
    private func send(_ cmd: String) async {
        busy = true; actionError = nil
        defer { busy = false }
        do {
            if SiriVoice.startStopNeedsFaceID || wallet.locked {
                _ = try await wallet.requireAuthentication(cmd == "stop" ? "Stop mining on \(rig.label)" : "Start mining on \(rig.label)")
            }
            var args: [String: String] = [:]
            if cmd == "start" { args["mode"] = "preferred" }
            if cmd == "stop" { MiningAlerts.noteStopRequested(rig.id) }
            _ = try await RigClient.command(cmd, args: args, pairing: rig)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await store.refresh(rig)
        } catch let failure as RigClient.Failure {
            if failure.phoneControlOff { store.markControlOff(rig.id); return }
            actionError = failure.offline ? "The rig is offline. Nothing was changed." : failure.message
            if failure.status == 401 { store.revoked.insert(rig.id) }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

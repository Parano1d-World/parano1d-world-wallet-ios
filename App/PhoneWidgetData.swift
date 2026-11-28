import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The small summary the iPhone widgets show. The app writes it after its own node verifies a balance and after
/// each signed status from a paired mining computer; the widgets only read it and never contact the network.
/// No address, payout, key or message is stored here. The balance is left out while Hide balances is on.
enum PhoneWidgetData {
    static let balanceKind = "Parano1dPhoneBalance"
    static let miningKind = "Parano1dPhoneMining"
    /// The App Group the app and its widgets share.
    static var group: String { "group.com.koajent.parano1d.wallet.widgets" }
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    // MARK: Balance
    struct Balance { let amount: String?; let hidden: Bool; let verifiedAt: Date?; let height: UInt64? }
    static func saveBalance(amount: String, verifiedAt: Date, height: UInt64) {
        guard let d = defaults else { return }
        d.set(amount, forKey: "balance.amount"); d.set(verifiedAt.timeIntervalSince1970, forKey: "balance.verifiedAt")
        d.set(Int64(clamping: height), forKey: "balance.height")
        reload(balanceKind)
    }
    static func setHidden(_ hidden: Bool) { defaults?.set(hidden, forKey: "balance.hidden"); reload(balanceKind) }
    static func clearBalance() {
        guard let d = defaults else { return }
        ["balance.amount", "balance.verifiedAt", "balance.height"].forEach { d.removeObject(forKey: $0) }
        reload(balanceKind)
    }
    static func balance() -> Balance {
        let d = defaults
        let at = d?.object(forKey: "balance.verifiedAt") as? Double
        let height = d?.object(forKey: "balance.height") as? Int64
        return Balance(amount: d?.string(forKey: "balance.amount"), hidden: d?.bool(forKey: "balance.hidden") ?? false,
                       verifiedAt: at.map { Date(timeIntervalSince1970: $0) }, height: height.map { UInt64(max(0, $0)) })
    }

    // MARK: Mining
    struct Mining: Codable {
        struct Rig: Codable { let name: String; let online: Bool; let running: Bool; let hashrate: String?; var shares: Int? = nil; let hottestC: Int?; let alert: String? }
        let rigs: [Rig]
        let updated: Date
        var mining: Int { rigs.filter(\.running).count }
        var offline: Int { rigs.filter { !$0.online }.count }
    }
    static func saveMining(_ mining: Mining?) {
        guard let d = defaults else { return }
        if let mining, let data = try? JSONEncoder().encode(mining) { d.set(data, forKey: "mining.summary") }
        else { d.removeObject(forKey: "mining.summary") }
        reload(miningKind)
    }
    static func mining() -> Mining? {
        guard let data = defaults?.data(forKey: "mining.summary") else { return nil }
        return try? JSONDecoder().decode(Mining.self, from: data)
    }

    private static func reload(_ kind: String) {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        #endif
    }
}

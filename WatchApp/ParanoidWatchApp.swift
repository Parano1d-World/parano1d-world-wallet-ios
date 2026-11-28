import SwiftUI
import WatchConnectivity
import UserNotifications
import WidgetKit
import WatchKit
#if canImport(UIKit)
import UIKit
#endif

/// Apple Watch companion. It holds no keys and runs no node. Everything goes
/// through the paired iPhone: the phone verifies balances, opens and seals
/// messages, plans payments and signs them only after the app PIN typed here
/// is checked by the phone's own attempt limits.
@main
struct ParanoidWatchApp: App {
    @StateObject private var model = WatchWalletModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WatchRootView().environmentObject(model)
                // Lowering your wrist keeps chat open. The iPhone ends the PIN session after
                // 2 minutes without use, 30 minutes at most, or 30 seconds out of range;
                // watchOS itself locks the watch when it leaves your wrist.
                .onChange(of: phase) { _, now in if now == .active { model.chatPulse["*"] = Date() } }
        }
    }
}

enum WatchTheme {
    /// Follows the iPhone's appearance ("world", "cyber", …, with "+orange" when Paranoid mode is on),
    /// using the same values as the iPhone's Theme.swift.
    private static var style: String { UserDefaults.standard.string(forKey: "watch.style") ?? "system" }
    static var world: Bool { style.hasPrefix("world") }
    static var cyber: Bool { style.hasPrefix("cyber") }
    static var orange: Bool { style.hasSuffix("+orange") }
    private static func hex(_ v: UInt32) -> Color { Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255) }
    static var mint: Color { orange ? hex(0xFF9B36) : world ? hex(0x9BDE7E) : cyber ? hex(0x00FF80) : hex(0x30E374) }
    static var secondary: Color { world ? hex(0xA9B8AC) : cyber ? (orange ? hex(0xCBBCA9) : hex(0x9FC7AF)) : hex(0xA1B6AC) }
    static var panel: Color { world ? hex(0x0C191B) : cyber ? (orange ? hex(0x241E17) : hex(0x102019)) : hex(0x0B1716) }
}

struct WatchContact: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    let changed: Bool
}
struct WatchReceipt: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let status: String
    let direction: String
    let counterparty: String?
    let height: String?
    let time: Date
    var final: Bool { status.hasPrefix("Finalized") }
}
struct WatchMessage: Identifiable, Hashable {
    let id: String
    let incoming: Bool
    let text: String
    let kind: String
    let amount: String?
    let invoice: String?
    let payable: Bool
    let declined: Bool
    let hidden: Bool
    let time: Date
}
struct WatchAccount: Identifiable, Hashable {
    let index: Int
    let name: String
    let address: String
    var id: Int { index }
}
struct WatchConfirmation: Identifiable {
    let id: String
    let title: String
    let to: String
    let name: String?
    let amount: String?
    let fee: String?
    let expires: Date
}

struct WatchFailure: LocalizedError {
    let raw: String
    init(message: String) { raw = message }
    var errorDescription: String? { raw.hasPrefix("phone:") ? String(raw.dropFirst(6)) : raw }
    var needsPIN: Bool { raw == "pin_required" }
    /// The iPhone can finish this payment in its own Send review.
    var handoff: Bool { raw.hasPrefix("phone:") }
}

@MainActor final class WatchWalletModel: NSObject, ObservableObject {
    @Published private(set) var address = ""
    @Published private(set) var name = ""
    @Published private(set) var balance: String?
    @Published private(set) var valueUSD: String?
    @Published private(set) var priceUSD: String?
    @Published private(set) var status = ""
    @Published private(set) var hidden = false
    @Published private(set) var sendsEnabled = false
    @Published private(set) var community = false
    @Published private(set) var qr: Data?
    @Published private(set) var updated: Date?
    @Published private(set) var contacts: [WatchContact] = []
    @Published private(set) var receipts: [WatchReceipt] = []
    @Published private(set) var avatars: [String: Data] = [:]
    @Published private(set) var reachable = false
    @Published private(set) var accounts: [WatchAccount] = []
    @Published private(set) var selectedAccount = 0
    @Published var confirmation: WatchConfirmation?
    /// Mirrors the iPhone appearance so views redraw when it changes.
    @Published private(set) var style = UserDefaults.standard.string(forKey: "watch.style") ?? "system"
    /// Last time the iPhone said a conversation changed ("*" = app became active).
    @Published var chatPulse: [String: Date] = [:]
    @Published var nftPulse = Date.distantPast
    /// A conversation to open, e.g. after tapping a message notification.
    @Published var openChat: WatchContact?
    /// Messages last shown per contact, kept only in memory so reopening is instant.
    var conversationCache: [String: [WatchMessage]] = [:]
    private static let storageKey = "watch.lastSnapshot.v2"

    override init() {
        super.init()
        #if DEBUG
        // Simulator-only sample content for App Store screenshots (launch argument -storeShots).
        if WatchStoreShots.on { apply(WatchStoreShots.snapshot, persist: false); return }
        #endif
        if let saved = UserDefaults.standard.dictionary(forKey: Self.storageKey) { apply(saved, persist: false) }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// Opens the conversation a tapped message notification belongs to.
    func route(contactID: String) {
        guard contactID.count == 64 else { return }
        if let contact = contacts.first(where: { $0.id == contactID }) { openChat = contact; return }
        Task { await refreshContacts(); if let contact = contacts.first(where: { $0.id == contactID }) { openChat = contact } }
    }

    func apply(_ context: [String: Any], persist: Bool = true) {
        guard let version = context["v"] as? Int, version == 1 || version == 2 else { return }
        address = (context["address"] as? String).map { String($0.prefix(128)) } ?? ""
        name = (context["name"] as? String).map { String($0.prefix(64)) } ?? ""
        hidden = context["hidden"] as? Bool ?? false
        sendsEnabled = context["sends"] as? Bool ?? false
        community = context["community"] as? Bool ?? false
        balance = hidden ? nil : (context["balance"] as? String).map { String($0.prefix(40)) }
        valueUSD = hidden ? nil : (context["value_usd"] as? String).map { String($0.prefix(24)) }
        priceUSD = (context["price_usd"] as? String).map { String($0.prefix(24)) }
        status = (context["status"] as? String).map { String($0.prefix(80)) } ?? ""
        qr = (context["qr"] as? Data).flatMap { $0.count <= 64 * 1024 ? $0 : nil }
        updated = (context["updated"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if context["contacts"] != nil { contacts = Self.contacts(context["contacts"]) } // absent = iPhone could not read them; keep the last list
        accounts = (context["accounts"] as? [[String: Any]] ?? []).prefix(20).compactMap { row in
            guard let index = row["index"] as? Int, let address = row["address"] as? String else { return nil }
            return WatchAccount(index: index, name: String((row["name"] as? String ?? "Account").prefix(32)), address: String(address.prefix(128)))
        }
        selectedAccount = context["selected"] as? Int ?? 0
        let style = (context["style"] as? String).map { String($0.prefix(16)) } ?? "system"
        if UserDefaults.standard.string(forKey: "watch.style") != style { UserDefaults.standard.set(style, forKey: "watch.style"); self.style = style }
        receipts = (context["receipts"] as? [[String: Any]] ?? []).prefix(20).compactMap(Self.receipt)
        if persist {
            var stored = context
            if hidden { stored.removeValue(forKey: "balance"); stored.removeValue(forKey: "value_usd") }
            UserDefaults.standard.set(stored, forKey: Self.storageKey)
        }
        WatchGlance.save(balance: balance, hidden: hidden, status: status, price: priceUSD, updated: updated,
                         pending: receipts.filter { !$0.final }.count)
    }

    static func contacts(_ raw: Any?) -> [WatchContact] {
        (raw as? [[String: Any]] ?? []).prefix(40).compactMap { row in
            guard let id = row["id"] as? String, id.count == 64, let name = row["name"] as? String,
                  let address = row["address"] as? String else { return nil }
            return WatchContact(id: id, name: String(name.prefix(40)), address: String(address.prefix(128)), changed: row["changed"] as? Bool ?? false)
        }
    }
    static func receipt(_ row: [String: Any]) -> WatchReceipt? {
        guard let id = row["id"] as? String, (1...80).contains(id.count) else { return nil }
        return WatchReceipt(id: id, title: String((row["title"] as? String ?? "Payment").prefix(40)),
                            summary: String((row["summary"] as? String ?? "").prefix(80)),
                            status: String((row["status"] as? String ?? "").prefix(80)),
                            direction: row["direction"] as? String == "received" ? "received" : "sent",
                            counterparty: (row["counterparty"] as? String).map { String($0.prefix(40)) },
                            height: (row["height"] as? String).map { String($0.prefix(12)) },
                            time: Date(timeIntervalSince1970: row["time"] as? Double ?? 0))
    }

    /// Sends a request to the iPhone and waits for its reply.
    func call(_ message: [String: Any]) async throws -> [String: Any] {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            throw WatchFailure(message: "Phone not connected. Keep your iPhone nearby with Parano1d installed.")
        }
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message, replyHandler: { continuation.resume(returning: $0) },
                                errorHandler: { _ in continuation.resume(throwing: WatchFailure(message: "The iPhone did not answer. Open Parano1d on your iPhone and try again.")) })
        }
        guard reply["ok"] as? Bool == true else { throw WatchFailure(message: reply["error"] as? String ?? "The iPhone refused this request.") }
        return reply
    }

    func refreshContacts() async {
        #if DEBUG
        if WatchStoreShots.on { return }
        #endif
        if let reply = try? await call(["type": "contacts"]) { contacts = Self.contacts(reply["contacts"]) }
    }
    func loadAvatar(_ id: String) async {
        guard avatars[id] == nil, let reply = try? await call(["type": "avatar", "id": id]),
              let png = reply["png"] as? Data, png.count <= 64 * 1024 else { return }
        avatars[id] = png
    }
    func lock() { Task { _ = try? await call(["type": "lock"]) } }
    func decide(_ approve: Bool) {
        guard let pending = confirmation else { return }
        confirmation = nil
        Task { _ = try? await call(["type": "confirm_decision", "id": pending.id, "approve": approve && pending.expires > Date()]) }
    }

    fileprivate func received(receipt info: [String: Any]) {
        guard info["type"] as? String == "receipt", let item = Self.receipt(info) else { return }
        receipts.removeAll { $0.id == item.id }
        receipts.insert(item, at: 0)
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = (item.summary.isEmpty ? "Payment" : item.summary) + (item.height.map { " · block \($0)" } ?? " · verified on iPhone")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "receipt-" + item.id, content: content, trigger: nil))
    }
    fileprivate func received(confirmRequest info: [String: Any]) {
        guard info["type"] as? String == "confirm_request", let id = info["id"] as? String, id.count <= 64,
              let to = info["to"] as? String, let expires = info["expires"] as? Double else { return }
        confirmation = WatchConfirmation(id: id, title: String((info["title"] as? String ?? "Approve payment").prefix(60)),
                                         to: String(to.prefix(128)), name: (info["name"] as? String).map { String($0.prefix(40)) },
                                         amount: (info["amount"] as? String).map { String($0.prefix(24)) },
                                         fee: (info["fee"] as? String).map { String($0.prefix(24)) },
                                         expires: Date(timeIntervalSince1970: expires))
        WKInterfaceDevice.current().play(.notification)
    }
}

extension WatchWalletModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable; if !context.isEmpty { self.apply(context) } }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.received(receipt: userInfo) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if message["type"] as? String == "chat_update", let id = message["id"] as? String, id.count == 64 {
                self.chatPulse[id] = Date()
            } else if message["type"] as? String == "nft_update" {
                self.nftPulse = Date()
            } else { self.received(confirmRequest: message) }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }
}

extension WatchWalletModel: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard info["route"] as? String == "chat", let id = info["contactID"] as? String else { return }
        await MainActor.run { self.route(contactID: id) }
    }
}

/// Shares a small, privacy-respecting summary with the complications.
enum WatchGlance {
    static func save(balance: String?, hidden: Bool, status: String, price: String?, updated: Date?, pending: Int) {
        guard let defaults = UserDefaults(suiteName: WatchEdition.appGroup) else { return }
        defaults.set(hidden ? nil : balance, forKey: "glance.balance")
        defaults.set(hidden, forKey: "glance.hidden")
        defaults.set(status, forKey: "glance.status")
        defaults.set(price, forKey: "glance.price")
        defaults.set(updated?.timeIntervalSince1970, forKey: "glance.updated")
        defaults.set(pending, forKey: "glance.pending")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: Root

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchWalletModel
    var body: some View {
        Group {
            if model.address.isEmpty {
                VStack(spacing: 10) {
                    Image("Brand").resizable().scaledToFit().frame(width: 44, height: 44)
                    Text("Open Parano1d Wallet on your iPhone").font(.headline).multilineTextAlignment(.center)
                    Text("Your balance, contacts and receipts appear here after the iPhone app verifies them.")
                        .font(.footnote).foregroundStyle(WatchTheme.secondary).multilineTextAlignment(.center)
                }.padding()
            } else {
                NavigationStack {
                    TabView {
                        WatchBalanceView()
                        WatchPayMenu()
                        WatchContactPicker(mode: .chat)
                        WatchNFTGallery()
                        WatchMoreMenu()
                    }
                    // Swipe left and right between pages; the dots always show how many pages there are,
                    // so scrolling inside a page is never confused with moving to the next one.
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .navigationDestination(item: $model.openChat) { contact in WatchConversationView(contact: contact) }
                }.tint(WatchTheme.mint).id(model.style)
            }
        }
        .sheet(item: $model.confirmation) { request in WatchConfirmSheet(request: request) }
    }
}

struct WatchBalanceView: View {
    @EnvironmentObject private var model: WatchWalletModel
    private var label: Font { WatchTheme.cyber ? .caption2.monospaced().weight(.semibold) : .caption2.weight(WatchTheme.world ? .heavy : .semibold) }
    private func caps(_ text: String) -> String { WatchTheme.world ? text.uppercased() : text }
    private var usdLine: String? {
        if model.hidden { return nil }
        if let value = model.valueUSD { return "≈ \(value) USD" }
        if model.balance == nil { return "USD after the balance check" }
        return model.priceUSD == nil ? nil : "USD value unavailable"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image("Brand").resizable().scaledToFit().frame(width: 18, height: 18)
                    Text(model.name.isEmpty ? "Wallet" : model.name).font(.footnote).foregroundStyle(WatchTheme.secondary).lineLimit(1)
                }
                if let price = model.priceUSD {
                    Text(caps("NOID " + price)).font(label).foregroundStyle(WatchTheme.mint).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(WatchTheme.panel))
                        .overlay(Capsule().strokeBorder(WatchTheme.mint.opacity(0.45), lineWidth: 1))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("NOID price \(price), estimate")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(caps("Balance")).font(label).foregroundStyle(WatchTheme.secondary).tracking(WatchTheme.world ? 1 : 0)
                    Text(model.hidden ? "Hidden" : (model.balance ?? "—"))
                        .font(.system(size: 30, weight: .semibold, design: WatchTheme.cyber ? .monospaced : .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                        .privacySensitive()
                    Text("NOID").font(.caption.weight(.semibold)).foregroundStyle(WatchTheme.mint)
                    if let line = usdLine { Text(caps(line)).font(.caption2).foregroundStyle(WatchTheme.secondary).lineLimit(1).minimumScaleFactor(0.7).privacySensitive() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: WatchTheme.cyber ? 4 : 14, style: .continuous).fill(WatchTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: WatchTheme.cyber ? 4 : 14, style: .continuous).strokeBorder(WatchTheme.mint.opacity(WatchTheme.world || WatchTheme.cyber ? 0.6 : 0.25), lineWidth: WatchTheme.cyber ? 2 : 1))
                if !model.status.isEmpty { Text(model.status).font(.caption2).foregroundStyle(WatchTheme.secondary) }
                if let updated = model.updated {
                    Text("From iPhone · \(updated, style: .relative) ago").font(.caption2).foregroundStyle(WatchTheme.secondary)
                }
                if !model.reachable { Label("Phone not connected · saved", systemImage: "iphone.slash").font(.caption2).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }.navigationTitle("Home")
    }
}

struct WatchPayMenu: View {
    @EnvironmentObject private var model: WatchWalletModel
    var body: some View {
        List {
            NavigationLink { WatchContactPicker(mode: .pay) } label: { Label("Send NOID", systemImage: "arrow.up.circle.fill") }
            NavigationLink { WatchContactPicker(mode: .request) } label: { Label("Request NOID", systemImage: "arrow.down.circle.fill") }
            NavigationLink { WatchActivityView() } label: {
                HStack {
                    Label("Receipts", systemImage: "checkmark.seal.fill")
                    let recent = model.receipts.filter { $0.final && $0.time > Date().addingTimeInterval(-86400) }.count
                    if recent > 0 { Spacer(); Text("\(recent)").font(.caption2.weight(.bold)).foregroundStyle(WatchTheme.mint) }
                }
            }
            NavigationLink { WatchReceiveView() } label: { Label("Receive", systemImage: "qrcode") }
        }.navigationTitle("Pay")
    }
}

struct WatchMoreMenu: View {
    @EnvironmentObject private var model: WatchWalletModel
    var body: some View {
        List {
            if model.accounts.count > 1 {
                NavigationLink { WatchAccountsView() } label: {
                    Label(model.accounts.first(where: { $0.index == model.selectedAccount })?.name ?? "Account", systemImage: "person.crop.circle")
                }
            }
            if model.community { WatchCommunityEntry() }
            Button { model.lock() } label: { Label("Lock watch session", systemImage: "lock.fill") }
            Text("Watch send and confirmation settings are on your iPhone: Settings → Wallet → Apple Watch.")
                .font(.caption2).foregroundStyle(WatchTheme.secondary)
        }.navigationTitle("More")
    }
}

struct WatchReceiveView: View {
    @EnvironmentObject private var model: WatchWalletModel
    var body: some View {
        VStack(spacing: 6) {
            if let data = model.qr, let image = UIImage(data: data) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("QR code for your public Parano1d address")
            }
            Text(String(model.address.prefix(10)) + "…" + String(model.address.suffix(6)))
                .font(.caption2.monospaced()).foregroundStyle(WatchTheme.secondary)
        }.padding(.horizontal, 6).navigationTitle("Receive")
    }
}

// MARK: Confirmation of an iPhone send

struct WatchConfirmSheet: View {
    @EnvironmentObject private var model: WatchWalletModel
    let request: WatchConfirmation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Label("Confirm iPhone send", systemImage: "iphone.and.arrow.forward").font(.headline).foregroundStyle(WatchTheme.mint)
                Text(request.title).font(.footnote)
                if let name = request.name { Text("To " + name).font(.footnote.weight(.semibold)) }
                if let amount = request.amount {
                    Text(amount + " NOID").font(.system(size: 26, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                }
                if !request.to.isEmpty {
                    Text(request.to).font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Recipient address")
                }
                if let fee = request.fee { row("Network fee", fee + " NOID") }
                Text("Expires \(request.expires, style: .relative)").font(.caption2).foregroundStyle(WatchTheme.secondary)
                Button("Address and amount are correct") { model.decide(true) }.tint(WatchTheme.mint)
                Button("Decline", role: .destructive) { model.decide(false) }
            }
        }
        .interactiveDismissDisabled()
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).font(.caption2).foregroundStyle(WatchTheme.secondary); Spacer(); Text(value).font(.caption.monospacedDigit()) }
    }
}

// MARK: Contacts

struct WatchAvatar: View {
    @EnvironmentObject private var model: WatchWalletModel
    let contact: WatchContact
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let data = model.avatars[contact.id], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Group {
                    if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.42)) }
                    else { Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)) }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(WatchTheme.panel).foregroundStyle(WatchTheme.mint)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().stroke(WatchTheme.mint.opacity(0.35), lineWidth: 1))
        .task { await model.loadAvatar(contact.id) }
        .accessibilityHidden(true)
    }
    private var initials: String {
        let parts = contact.name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "" : String(parts).uppercased()
    }
}

struct WatchContactPicker: View {
    enum Mode { case pay, chat, request }
    @EnvironmentObject private var model: WatchWalletModel
    let mode: Mode
    @State private var search = ""
    private var shown: [WatchContact] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.contacts : model.contacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        Group {
            if mode == .pay && !model.sendsEnabled {
                WatchNotice(icon: "applewatch.slash", title: "Watch sends are off",
                            text: "On your iPhone, open Settings → Wallet → Apple Watch and turn on sends.")
            } else if model.contacts.isEmpty && mode == .chat && model.community {
                List {
                    WatchCommunityEntry()
                    Text("Your private chats appear here once your iPhone shares them. Open Parano1d on your iPhone and unlock it.")
                        .font(.caption2).foregroundStyle(WatchTheme.secondary)
                }
            } else if model.contacts.isEmpty {
                WatchNotice(icon: "person.crop.circle.badge.plus", title: "No contacts yet",
                            text: "Add contacts in Parano1d chat on your iPhone. They appear here automatically.")
            } else {
                List {
                    if mode == .chat && model.community { WatchCommunityEntry() }
                    if model.contacts.count > 6 { TextField("Search", text: $search) }
                    ForEach(shown) { contact in
                        NavigationLink {
                            switch mode {
                            case .pay: WatchPayView(contact: contact)
                            case .chat: WatchConversationView(contact: contact)
                            case .request: WatchRequestView(contact: contact)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                WatchAvatar(contact: contact)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(contact.name).font(.headline).lineLimit(1)
                                    if contact.changed && mode == .pay {
                                        Text("Address changed").font(.caption2).foregroundStyle(.orange)
                                    } else {
                                        Text(String(contact.address.prefix(8)) + "…").font(.caption2.monospaced()).foregroundStyle(WatchTheme.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(mode == .pay ? "Send to" : mode == .request ? "Request from" : "Chat")
        .task { await model.refreshContacts() }
    }
}

struct WatchNotice: View {
    let icon: String, title: String, text: String
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(WatchTheme.mint)
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(text).font(.footnote).foregroundStyle(WatchTheme.secondary).multilineTextAlignment(.center)
            }.padding(.horizontal, 4)
        }
    }
}

// MARK: Keypad

/// Large number keys for PINs and amounts: much easier than the system text entry on a watch.
struct WatchKeypad: View {
    @Binding var text: String
    let decimal: Bool
    let limit: Int
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]
    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) { ForEach(row, id: \.self) { key($0) } }
            }
            HStack(spacing: 4) {
                if decimal { key(".") } else { Color.clear.frame(maxWidth: .infinity, minHeight: 30) }
                key("0")
                Button { if !text.isEmpty { text.removeLast() } } label: {
                    Image(systemName: "delete.left").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.plain).background(WatchTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Delete")
            }
        }
    }
    private func key(_ digit: String) -> some View {
        Button { press(digit) } label: {
            Text(digit).font(.system(size: 19, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.plain).background(WatchTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
    private func press(_ digit: String) {
        guard text.count < limit else { return }
        if digit == "." {
            guard decimal, !text.contains(".") else { return }
            text = text.isEmpty ? "0." : text + "."
            return
        }
        if let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 6 { return } // NOID has 6 decimals
        if text == "0" && decimal { text = digit } else { text += digit }
        WKInterfaceDevice.current().play(.click)
    }
}

struct WatchAmountDisplay: View {
    let amount: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(amount.isEmpty ? "0" : amount)
                .font(.system(size: 24, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(amount.isEmpty ? WatchTheme.secondary : .primary)
            Text("NOID").font(.caption2.weight(.semibold)).foregroundStyle(WatchTheme.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
}

// MARK: PIN

struct WatchPINSheet: View {
    let title: String
    let action: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").font(.title3).foregroundStyle(WatchTheme.mint)
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(pin.isEmpty ? "Enter PIN" : String(repeating: "●", count: pin.count))
                    .font(.system(size: pin.isEmpty ? 14 : 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(pin.isEmpty ? WatchTheme.secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 24).accessibilityLabel("PIN, \(pin.count) digits")
                WatchKeypad(text: $pin, decimal: false, limit: 12)
                if let error { Text(error).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center) }
                Button {
                    busy = true; error = nil
                    Task {
                        defer { busy = false }
                        do { try await action(pin); pin = ""; dismiss() }
                        catch { pin = ""; self.error = error.localizedDescription }
                    }
                } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Confirm")) }
                .disabled(busy || pin.count < 4).tint(WatchTheme.mint)
                Text("Checked on your iPhone. Your iPhone must be unlocked.").font(.caption2).foregroundStyle(WatchTheme.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

/// Offers to finish a payment on the iPhone when the watch can't approve it alone.
struct WatchHandoffButton: View {
    @EnvironmentObject private var model: WatchWalletModel
    let contact: WatchContact
    let amount: String
    @State private var sent = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sent {
                Label("Check your iPhone to finish", systemImage: "iphone").font(.caption2).foregroundStyle(WatchTheme.mint)
            } else {
                Button { Task {
                    do { _ = try await model.call(["type": "pay_handoff", "id": contact.id, "amount": amount]); sent = true }
                    catch { self.error = error.localizedDescription }
                } } label: { Label("Continue on iPhone", systemImage: "iphone.and.arrow.forward") }
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
    }
}

// MARK: Pay

struct WatchPayView: View {
    @EnvironmentObject private var model: WatchWalletModel
    let contact: WatchContact
    var presetAmount: String? = nil
    @State private var amount = ""
    @State private var review: [String: Any]?
    @State private var busy = false
    @State private var error: String?
    @State private var handoff = false
    @State private var confirming = false
    @State private var result: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { WatchAvatar(contact: contact, size: 30); Text(contact.name).font(.headline).lineLimit(1) }
                if let result {
                    Label(result, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(WatchTheme.mint)
                    Text("Your receipt appears here once the iPhone verifies the payment is final.").font(.caption2).foregroundStyle(WatchTheme.secondary)
                } else if let review {
                    // Step 1 of 2: confirm the exact recipient address and amount.
                    Text("Confirm").font(.caption.weight(.semibold)).foregroundStyle(WatchTheme.mint)
                    Text((review["amount"] as? String ?? "") + " NOID")
                        .font(.system(size: 28, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                    Text("To " + contact.name).font(.footnote.weight(.semibold))
                    Text(review["address"] as? String ?? "").font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Recipient address")
                    row("Network fee", (review["fee"] as? String ?? "") + " NOID")
                    row("Total", (review["total"] as? String ?? "") + " NOID")
                    if let account = review["account"] as? String {
                        Text("From " + String(account.prefix(8)) + "…").font(.caption2.monospaced()).foregroundStyle(WatchTheme.secondary)
                    }
                    // Step 2 of 2 is the PIN, checked on the iPhone.
                    Button("Address and amount are correct") { confirming = true }.tint(WatchTheme.mint)
                    Button("Cancel", role: .cancel) { self.review = nil }
                } else {
                    if contact.changed {
                        Label("Address changed since your last payment", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                    }
                    WatchAmountDisplay(amount: amount)
                    WatchKeypad(text: $amount, decimal: true, limit: 18)
                    HStack {
                        ForEach(["1", "5", "10"], id: \.self) { preset in
                            Button(preset) { amount = preset }.buttonStyle(.bordered).font(.caption)
                        }
                    }
                    Button { prepare() } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Review")) }
                        .disabled(busy || amount.isEmpty).tint(WatchTheme.mint)
                }
                if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
                if handoff && result == nil { WatchHandoffButton(contact: contact, amount: amount) }
            }.padding(.horizontal, 2)
        }
        .navigationTitle("Send")
        .onAppear { if amount.isEmpty, let presetAmount { amount = presetAmount } }
        .sheet(isPresented: $confirming) {
            WatchPINSheet(title: "Approve " + (review?["total"] as? String ?? "") + " NOID") { pin in
                guard let review else { return }
                do {
                    // The iPhone refuses to sign unless this address and amount match exactly.
                    let reply = try await model.call(["type": "pay_approve", "review": review["review"] ?? "", "digest": review["digest"] ?? "",
                                                      "amount": review["amount"] ?? "", "address": review["address"] ?? "",
                                                      "id": contact.id, "pin": pin])
                    self.review = nil
                    result = reply["stage"] as? String == "broadcast" ? "Submitted · awaiting confirmation" : "Signed · iPhone will submit"
                } catch let failure as WatchFailure where failure.handoff {
                    self.review = nil; handoff = true; error = failure.localizedDescription
                }
            }
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).font(.caption2).foregroundStyle(WatchTheme.secondary); Spacer(); Text(value).font(.caption.monospacedDigit()) }
    }
    private func prepare() {
        #if DEBUG
        if WatchStoreShots.on { review = WatchStoreShots.review(amount: amount, address: contact.address); return }
        #endif
        busy = true; error = nil; handoff = false
        Task {
            defer { busy = false }
            do {
                let reply = try await model.call(["type": "pay_review", "id": contact.id, "amount": amount.trimmingCharacters(in: .whitespaces)])
                if let expires = reply["expires"] as? Double, Date(timeIntervalSince1970: expires) > Date() { review = reply }
                else { error = "The review expired. Try again." }
            } catch let failure as WatchFailure where failure.handoff {
                handoff = true; error = failure.localizedDescription
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Request

struct WatchRequestView: View {
    @EnvironmentObject private var model: WatchWalletModel
    let contact: WatchContact
    @State private var amount = ""
    @State private var memo = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false
    @State private var unlocking = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { WatchAvatar(contact: contact, size: 30); Text(contact.name).font(.headline).lineLimit(1) }
                if done {
                    Label("Request sent", systemImage: "checkmark.circle.fill").foregroundStyle(WatchTheme.mint)
                    Text("Status: unpaid. You'll get a receipt when a payment is verified.").font(.caption2).foregroundStyle(WatchTheme.secondary)
                } else {
                    WatchAmountDisplay(amount: amount)
                    WatchKeypad(text: $amount, decimal: true, limit: 18)
                    TextField("Note (optional)", text: $memo)
                    Button { send() } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Send request")) }
                        .disabled(busy || amount.isEmpty).tint(WatchTheme.mint)
                }
                if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Request")
        .sheet(isPresented: $unlocking) {
            WatchPINSheet(title: "Unlock to request") { pin in _ = try await model.call(["type": "unlock", "pin": pin]); send() }
        }
    }
    private func send() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { _ = try await model.call(["type": "request_create", "id": contact.id, "amount": amount, "memo": memo]); done = true }
            catch let failure as WatchFailure where failure.needsPIN { unlocking = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Chat

struct WatchConversationView: View {
    @EnvironmentObject private var model: WatchWalletModel
    let contact: WatchContact
    @State private var messages: [WatchMessage] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var error: String?
    @State private var unlocking = false
    @State private var pendingRetry: (() -> Void)?
    @State private var loading = false
    @State private var visible = false
    private let quickReplies = ["On my way", "Sent!", "Thanks", "Call you soon"]
    private let refreshClock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    // Newest first: write at the top, the latest message sits right under it.
                    TextField("Message", text: $draft).submitLabel(.send).onSubmit { send(draft) }.id("compose")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(quickReplies, id: \.self) { reply in Button(reply) { send(reply) }.buttonStyle(.bordered).font(.caption2) } }
                    }
                    if busy { ProgressView() }
                    if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
                    if messages.isEmpty && loading { ProgressView().padding(.vertical, 8) }
                    ForEach(messages.reversed()) { message in bubble(message).id(message.id) }
                    NavigationLink { WatchRequestView(contact: contact) } label: { Label("Request NOID", systemImage: "arrow.down.circle") }.font(.caption)
                }
            }
            .onChange(of: messages.last?.id) { _, _ in withAnimation { proxy.scrollTo("compose", anchor: .top) } }
        }
        .navigationTitle(contact.name)
        .onAppear {
            visible = true
            if messages.isEmpty, let cached = model.conversationCache[contact.id] { messages = cached }
            load()
        }
        .onDisappear { visible = false }
        // New message from this contact, or the app came back to the screen.
        .onChange(of: model.chatPulse[contact.id]) { _, _ in if visible { load() } }
        .onChange(of: model.chatPulse["*"]) { _, _ in if visible { load() } }
        .onReceive(refreshClock) { _ in if visible && model.reachable && !unlocking { load() } }
        .sheet(isPresented: $unlocking) {
            WatchPINSheet(title: "Unlock messages") { pin in
                _ = try await model.call(["type": "unlock", "pin": pin])
                let retry = pendingRetry; pendingRetry = nil
                retry?()
            }
        }
    }
    @ViewBuilder private func bubble(_ message: WatchMessage) -> some View {
        HStack {
            if !message.incoming { Spacer(minLength: 16) }
            VStack(alignment: .leading, spacing: 3) {
                if message.kind == "request" {
                    Label("Requests " + (message.amount ?? "") + " NOID", systemImage: "arrow.down.circle").font(.caption.weight(.semibold))
                    if message.declined {
                        Text("Declined").font(.caption2).foregroundStyle(WatchTheme.secondary)
                    } else if message.incoming {
                        if message.payable, model.sendsEnabled, let amount = message.amount {
                            NavigationLink("Review & pay") { WatchPayView(contact: contact, presetAmount: amount) }.font(.caption2).tint(WatchTheme.mint)
                        } else if let amount = message.amount {
                            WatchHandoffButton(contact: contact, amount: amount).font(.caption2)
                        }
                        if let invoice = message.invoice {
                            Button("Decline", role: .destructive) { decline(invoice: invoice, amount: message.amount ?? "") }.font(.caption2)
                        }
                    } else {
                        Text("Sent · unpaid until a verified receipt").font(.caption2).foregroundStyle(WatchTheme.secondary)
                    }
                } else if message.kind == "payment" || message.kind == "receipt" {
                    Label(message.kind == "payment" ? "Payment" + (message.amount.map { " · " + $0 + " NOID" } ?? "") : "Payment update", systemImage: "checkmark.seal")
                        .font(.caption.weight(.semibold))
                }
                if !message.text.isEmpty {
                    Text(message.text).font(.footnote).foregroundStyle(message.hidden ? WatchTheme.secondary : .primary)
                }
                Text(message.time, style: .time).font(.system(size: 9)).foregroundStyle(WatchTheme.secondary)
            }
            .padding(7)
            .background(message.incoming ? WatchTheme.panel : WatchTheme.mint.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            if message.incoming { Spacer(minLength: 16) }
        }
    }
    private func run(_ work: @escaping () async throws -> Void, retry: @escaping () -> Void) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await work() }
            catch let failure as WatchFailure where failure.needsPIN { pendingRetry = retry; unlocking = true }
            catch { self.error = error.localizedDescription }
        }
    }
    /// Refreshes quietly: cached messages stay on screen while the iPhone answers.
    private func load() {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do { try await fetch() }
            catch let failure as WatchFailure where failure.needsPIN { pendingRetry = { load() }; unlocking = true }
            catch { if messages.isEmpty { self.error = error.localizedDescription } }
        }
    }
    private func fetch() async throws {
            let reply = try await model.call(["type": "conversation", "id": contact.id])
            let rows: [WatchMessage] = (reply["messages"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return WatchMessage(id: id, incoming: row["in"] as? Bool ?? false, text: String((row["text"] as? String ?? "").prefix(1000)),
                                    kind: row["kind"] as? String ?? "text", amount: row["amount"] as? String,
                                    invoice: row["invoice"] as? String, payable: row["payable"] as? Bool ?? false,
                                    declined: row["declined"] as? Bool ?? false, hidden: row["hidden"] as? Bool ?? false,
                                    time: Date(timeIntervalSince1970: row["time"] as? Double ?? 0))
            }
            error = nil
            // Keep a just-sent message on screen until the iPhone's copy arrives.
            let now = Date()
            let pending = messages.filter { sent in
                sent.id.hasPrefix("local-") && now.timeIntervalSince(sent.time) < 30
                    && !rows.contains { !$0.incoming && $0.text == sent.text && abs($0.time.timeIntervalSince(sent.time)) < 120 }
            }
            let merged = rows + pending
            if merged != messages { messages = merged }
            model.conversationCache[contact.id] = rows
    }
    /// Shows the message immediately, then confirms it with the iPhone.
    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let local = WatchMessage(id: "local-" + UUID().uuidString, incoming: false, text: text, kind: "text", amount: nil,
                                 invoice: nil, payable: false, declined: false, hidden: false, time: Date())
        draft = ""
        messages.append(local)
        run({
            do {
                _ = try await model.call(["type": "send_message", "id": contact.id, "text": text])
            } catch {
                messages.removeAll { $0.id == local.id }
                draft = text
                throw error
            }
            try await fetch()
        }, retry: { send(text) })
    }
    private func decline(invoice: String, amount: String) {
        run({
            _ = try await model.call(["type": "request_decline", "id": contact.id, "invoice": invoice, "amount": amount])
            load()
        }, retry: { decline(invoice: invoice, amount: amount) })
    }
}

// MARK: NFTs

struct WatchNFT: Identifiable, Hashable { let id: String; let name: String; let serial: String; let collection: String; let height: String }

struct WatchNFTGallery: View {
    @EnvironmentObject private var model: WatchWalletModel
    @State private var items: [WatchNFT] = []
    @State private var images: [String: Data] = [:]
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        Group {
            if let error, items.isEmpty {
                WatchNotice(icon: "photo.on.rectangle", title: "NFTs", text: error)
            } else if loaded && items.isEmpty {
                WatchNotice(icon: "photo.on.rectangle", title: "No NFTs", text: "NFTs verified in this wallet on your iPhone appear here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(items) { item in
                            NavigationLink { WatchNFTDetail(item: item, image: images[item.id]) } label: { tile(item) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("NFTs")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.black) }.accessibilityLabel("Refresh NFTs") } }
        .task {
            await load()
            // Until the iPhone has verified holdings, look again every few seconds (up to 3 minutes).
            for _ in 0..<36 where items.isEmpty {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await load()
            }
        }
        .onChange(of: model.nftPulse) { _, _ in Task { await load() } }
    }
    private func tile(_ item: WatchNFT) -> some View {
        VStack(spacing: 2) {
            Group {
                if let data = images[item.id], let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").foregroundStyle(WatchTheme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(WatchTheme.panel) }
            }
            .frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.name).font(.system(size: 10)).lineLimit(1)
        }
        .task { await image(item.id) }
    }
    private func load() async {
        do {
            let reply = try await model.call(["type": "nfts"])
            items = (reply["items"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return WatchNFT(id: id, name: row["name"] as? String ?? "NFT", serial: row["serial"] as? String ?? "",
                                collection: row["collection"] as? String ?? "", height: row["height"] as? String ?? "")
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
    private func image(_ id: String) async {
        guard images[id] == nil, let reply = try? await model.call(["type": "nft_image", "id": id]),
              let data = reply["png"] as? Data, data.count <= 48 * 1024 else { return }
        images[id] = data
    }
}

struct WatchNFTDetail: View {
    let item: WatchNFT
    let image: Data?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let image, let picture = UIImage(data: image) { Image(uiImage: picture).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)) }
                Text(item.name).font(.headline)
                if !item.serial.isEmpty { Text("#" + item.serial).font(.caption2).foregroundStyle(WatchTheme.secondary) }
                Text("Collection " + item.collection + "…").font(.caption2.monospaced()).foregroundStyle(WatchTheme.secondary)
                if !item.height.isEmpty { Label("Ownership verified at block \(item.height)", systemImage: "checkmark.seal").font(.caption2).foregroundStyle(WatchTheme.mint) }
                Text("Send NFTs from your iPhone.").font(.caption2).foregroundStyle(WatchTheme.secondary)
            }
        }.navigationTitle("NFT")
    }
}

// MARK: Receipts

struct WatchActivityView: View {
    @EnvironmentObject private var model: WatchWalletModel
    var body: some View {
        Group {
            if model.receipts.isEmpty {
                WatchNotice(icon: "checkmark.seal", title: "No receipts yet", text: "Payments appear here once your iPhone verifies them.")
            } else {
                List(model.receipts) { receipt in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(receipt.summary.isEmpty ? receipt.title : receipt.summary,
                              systemImage: receipt.direction == "received" ? "arrow.down.left" : "arrow.up.right")
                            .font(.headline).lineLimit(2).privacySensitive()
                        if let name = receipt.counterparty { Text((receipt.direction == "received" ? "From " : "To ") + name).font(.caption2) }
                        Label(receipt.status.isEmpty ? "Not verified" : receipt.status,
                              systemImage: receipt.final ? "checkmark.seal.fill" : "clock")
                            .font(.caption2).foregroundStyle(receipt.final ? WatchTheme.mint : WatchTheme.secondary)
                        HStack {
                            if receipt.id.count == 64 { Text(String(receipt.id.prefix(8)) + "…").font(.caption2.monospaced()) }
                            Text(receipt.time, style: .relative)
                        }.font(.caption2).foregroundStyle(WatchTheme.secondary)
                    }
                }
            }
        }.navigationTitle("Receipts")
    }
}

// MARK: Accounts

/// Switches the iPhone's selected account (PIN required). Sends and receipts follow it.
struct WatchAccountsView: View {
    @EnvironmentObject private var model: WatchWalletModel
    @State private var choice: WatchAccount?
    @State private var done = false
    var body: some View {
        List(model.accounts) { account in
            Button { if account.index != model.selectedAccount { choice = account } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).font(.headline).lineLimit(1)
                        Text(String(account.address.prefix(8)) + "…").font(.caption2.monospaced()).foregroundStyle(WatchTheme.secondary)
                    }
                    Spacer()
                    if account.index == model.selectedAccount { Image(systemName: "checkmark").foregroundStyle(WatchTheme.mint) }
                }
            }
        }
        .navigationTitle("Accounts")
        .sheet(item: $choice) { account in
            WatchPINSheet(title: "Switch to \(account.name)") { pin in
                _ = try await model.call(["type": "account_select", "index": account.index, "pin": pin])
            }
        }
    }
}

#if DEBUG
/// Simulator-only sample content for App Store screenshots. Compiled out of release builds and
/// active only when the watch app is launched with -storeShots.
enum WatchStoreShots {
    static let on = ProcessInfo.processInfo.arguments.contains("-storeShots")
    private static func id(_ seed: String) -> String {
        var value: UInt64 = seed.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }
        var out = ""
        while out.count < 64 { value = value &* 6364136223846793005 &+ 1442695040888963407; out += String(format: "%016llx", value) }
        return String(out.prefix(64))
    }
    static var snapshot: [String: Any] {
        ["v": 2, "address": "o1" + String(id("own").prefix(58)), "name": "Main", "sends": true, "community": true,
         "balance": "92.520896", "value_usd": "10.99", "price_usd": "0.1188", "status": "Verified",
         "updated": Date().timeIntervalSince1970, "style": UserDefaults.standard.string(forKey: "watch.style") ?? "system",
         "contacts": ["Alex", "Jordan", "Maya"].map { ["id": id($0), "name": $0, "address": "o1" + String(id($0 + "a").prefix(58))] }]
    }
    static func review(amount: String, address: String) -> [String: Any] {
        let value = Double(amount) ?? 25
        return ["amount": amount.isEmpty ? "25" : amount, "address": address, "fee": "0.0001",
                "total": String(format: "%.4f", value + 0.0001), "account": "o1" + String(id("own").prefix(58)),
                "expires": Date().addingTimeInterval(600).timeIntervalSince1970]
    }
}
#endif

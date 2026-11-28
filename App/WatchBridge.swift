import SwiftUI
import Combine
import LocalAuthentication
import UserNotifications
#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import WatchConnectivity

/// iPhone side of the Apple Watch companion.
///
/// The watch never holds wallet keys. It asks the phone to do everything:
/// read contacts and conversations, send encrypted messages, plan a NOID
/// payment, and sign it after the user types the app PIN on the watch. The
/// PIN travels only over WatchConnectivity's encrypted link, is checked by
/// the same `AppLockStore` attempt limits as the phone, and is never stored.
///
/// When the watch can't approve on its own (a changed contact
/// address, or a locked iPhone) it hands the payment to the iPhone, which
/// opens its normal Send review. With "Confirm iPhone sends on Apple Watch"
/// on, the iPhone also asks the watch to confirm each send before signing.
///
/// Protocol (Wear OS mirrors these names).
@MainActor final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    static let settingKey = "watch.sendsEnabled.v1"
    static let confirmPhoneSendsKey = "watch.confirmPhoneSends.v1"
    /// Posted when a watch hand-off should open the iPhone Send review.
    static let handoffOpened = Notification.Name("WatchBridgeHandoffOpened")
    /// The hand-off waiting for the app to open (recipient address, amount).
    static var pendingHandoff: (address: String, amount: String)?
    private static let declinedKey = "watch.declinedInvoices.v1"
    private static let lastBalanceKey = "watch.lastVerifiedBalance.v1"
    /// Inactivity timeout and hard cap for the PIN session used by messages.
    private static let sessionIdle: TimeInterval = 120
    private static let sessionMaximum: TimeInterval = 1800

    private weak var wallet: WalletState?
    private weak var node: DeviceNode?
    private weak var nearby: NearbyTransport?
    private weak var live: LiveData?
    private weak var quotes: PriceFeed?
    private var session: (context: LAContext, until: Date, started: Date)?
    private var reviews: [String: Review] = [:]
    private var usedApprovals: Set<String> = []
    private var lastSnapshot: [String: String] = [:]
    private var announcedReceipts: Set<String> = []
    private var confirmations: [String: CheckedContinuation<Bool, Error>] = [:]
    /// Messages already opened during this PIN session, so reopening a chat on the
    /// watch is instant. Cleared whenever the session ends.
    private var openedRows: [String: [String: Any]] = [:]
    private var unreachableLock: Task<Void, Never>?
    private var started = false
    private var lastArguments: (address: String, walletName: String, balance: String?, status: String, hidden: Bool)?
    /// Public identity remembered from the last unlocked moment. The app clears its
    /// accounts when it locks (by default whenever it leaves the screen); the watch
    /// still needs the public addresses, while every sensitive action needs the PIN.
    private struct Identity { var root: String; var owner: String; var verified: Bool; var accounts: [WalletAccount]; var selected: UInt32 }
    private var identity: Identity?
    private func remember() {
        guard let wallet, !wallet.locked, let root = wallet.accounts.first(where: { $0.index == 0 })?.address,
              AddressValidator.valid(wallet.address), let local = wallet.localWallet else { return }
        identity = Identity(root: root, owner: wallet.address, verified: local.recoveryVerified, accounts: wallet.accounts, selected: wallet.selectedIndex)
    }
    /// The wallet's selected public address, live when unlocked, remembered when locked.
    private var owner: String? { wallet?.locked == false && AddressValidator.valid(wallet?.address ?? "") ? wallet?.address : identity?.owner }

    struct Review {
        let id: String
        let digest: String
        let plan: [String: Any]
        let expectedTxid: String
        let contactID: String
        let address: String
        let amountRaw: String
        let expires: Date
    }

    // MARK: Setup

    func attach(wallet: WalletState, node: DeviceNode, nearby: NearbyTransport, live: LiveData? = nil, quotes: PriceFeed? = nil) {
        self.wallet = wallet; self.node = node; self.nearby = nearby
        if let live {
            self.live = live
            // Tell the watch as soon as this iPhone finishes verifying NFT holdings.
            holdingsWatch = live.$holdingsHeight.combineLatest(live.$holdingsVerifiedLocally)
                .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
                .sink { [weak self] _, verified in if verified { self?.pulse(type: "nft_update") } }
        }
        if let quotes { self.quotes = quotes }
        guard WCSession.isSupported(), !started else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        NotificationCenter.default.addObserver(forName: LocalPaymentHistory.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.publishReceipts() }
        }
        NotificationCenter.default.addObserver(forName: ContactBook.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.republish() }
        }
        NotificationCenter.default.addObserver(forName: PrivateChatBlocks.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.republish() }
        }
    }

    var root: String? { wallet?.accounts.first(where: { $0.index == 0 })?.address ?? identity?.root }
    private var sendsEnabled: Bool { UserDefaults.standard.bool(forKey: Self.settingKey) }
    private static func lastPaidKey(_ contactID: String) -> String { "watch.lastPaidAddress." + contactID }
    private var declined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.prefix(500)), forKey: Self.declinedKey) }
    }
    private var watchReady: Bool {
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    // MARK: Snapshot (phone → watch)

    /// Re-sends the last snapshot with fresh contacts, receipts and settings.
    func republish() {
        lastSnapshot = [:]
        guard let last = lastArguments else { return }
        publish(address: last.address, walletName: last.walletName, balance: last.balance, status: last.status, hidden: last.hidden)
    }

    func publish(address: String, walletName: String, balance: String?, status: String, hidden: Bool) {
        remember()
        lastArguments = (address, walletName, balance, status, hidden)
        guard WCSession.isSupported() else { return }
        let price = priceText()
        let signature = ["address": address, "name": walletName, "status": status, "hidden": String(hidden),
                         "balance": hidden ? "" : (balance ?? ""), "sends": String(sendsEnabled), "price": price ?? "",
                         "confirm": String(UserDefaults.standard.bool(forKey: Self.confirmPhoneSendsKey)),
                         "accounts": (identity?.accounts.map { "\($0.index):\($0.name)" } ?? []).joined(separator: ","),
                         "selected": String(identity?.selected ?? 0),
                         "style": (UserDefaults.standard.string(forKey: DisplayStyle.storageKey) ?? "system") + (ParanoidLook.enabled ? "+orange" : "")]
        guard signature != lastSnapshot else { return }
        Task { @MainActor in
            var context: [String: Any] = ["v": 2, "address": address, "name": walletName, "status": status,
                                          "hidden": hidden, "sends": sendsEnabled, "updated": Date().timeIntervalSince1970,
                                          "community": WatchBridgeEdition.community,
                                          "style": (UserDefaults.standard.string(forKey: DisplayStyle.storageKey) ?? "system") + (ParanoidLook.enabled ? "+orange" : "")]
            if let balance, !hidden {
                context["balance"] = balance
                if let value = usdEstimate(balance) { context["value_usd"] = value }
            }
            if let price { context["price_usd"] = price; context["price_updated"] = quotes?.updated?.timeIntervalSince1970 ?? 0 }
            if AddressValidator.valid(address), let png = ReceiveView.qr(address)?.pngData(), png.count <= 48 * 1024 { context["qr"] = png }
            if let rows = await contactRows() { context["contacts"] = rows }
            context["receipts"] = await receiptRows(hidden: hidden)
            if let saved = identity {
                context["accounts"] = saved.accounts.prefix(20).map { account -> [String: Any] in
                    ["index": Int(account.index), "name": String(account.name.prefix(32)), "address": account.address]
                }
                context["selected"] = Int(saved.selected)
            }
            guard watchReady else { return }
            do { try WCSession.default.updateApplicationContext(context); lastSnapshot = signature } catch {}
        }
    }

    private func priceText() -> String? {
        guard let price = quotes?.currentPrice, price > 0 else { return nil }
        return Self.money(price, digits: 6)
    }
    private func usdEstimate(_ balance: String) -> String? {
        guard let price = quotes?.currentPrice, price > 0, let amount = Decimal(string: balance.replacingOccurrences(of: ",", with: "")) else { return nil }
        return Self.money(amount * price, digits: 2)
    }
    private static func money(_ value: Decimal, digits: Int) -> String {
        let format = NumberFormatter()
        format.numberStyle = .currency; format.currencyCode = "USD"
        format.maximumFractionDigits = digits; format.minimumFractionDigits = min(2, digits)
        return format.string(from: value as NSDecimalNumber) ?? ""
    }

    /// Last list read successfully. The contact file is protected while the iPhone is locked;
    /// a failed read must not tell the watch "no chats", so it returns this instead (nil if none yet).
    private var lastContactRows: [[String: Any]]?
    private func contactRows() async -> [[String: Any]]? {
        guard let contacts = try? await ContactBook.shared.load() else { return lastContactRows }
        let rows: [[String: Any]] = contacts.filter { !PrivateChatBlocks.contains($0.id) }.prefix(40).map { contact -> [String: Any] in
            var row: [String: Any] = ["id": contact.id, "name": String(contact.name.prefix(40)), "address": contact.address]
            if let previous = UserDefaults.standard.string(forKey: Self.lastPaidKey(contact.id)), previous != contact.address { row["changed"] = true }
            return row
        }
        lastContactRows = rows
        return rows
    }

    private func receiptRows(hidden: Bool) async -> [[String: Any]] {
        guard let root, let owner, AddressValidator.valid(owner),
              let rows = try? await LocalPaymentHistory.shared.load(root: root, owner: owner) else { return [] }
        let names = Dictionary(((try? await ContactBook.shared.load()) ?? []).map { ($0.address, $0.name) }, uniquingKeysWith: { first, _ in first })
        let recent = rows.sorted { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }.prefix(10)
        var output = recent.compactMap { row -> [String: Any]? in
            guard let id = row["txid"] as? String else { return nil }
            var item: [String: Any] = ["id": id, "title": HistoryRows.title(row),
                                       "summary": HistoryRows.summary(row, hideAmounts: hidden),
                                       "status": String((row["local_status"] as? String ?? "").prefix(80)),
                                       "direction": "sent", "account": owner,
                                       "time": row["timestamp"] as? Double ?? 0]
            if let recipient = row["recipient"] as? String, let name = names[recipient] { item["counterparty"] = String(name.prefix(40)) }
            if let height = row["verified_balance_height"] as? String { item["height"] = height }
            return item
        }
        output.append(contentsOf: (UserDefaults.standard.array(forKey: "watch.incomingReceipts.v1") as? [[String: Any]] ?? [])
            .filter { $0["account"] as? String == owner }
            .map { row -> [String: Any] in var copy = row; if hidden { copy["summary"] = "NOID received" }; return copy })
        return Array(output.sorted { ($0["time"] as? Double ?? 0) > ($1["time"] as? Double ?? 0) }.prefix(12))
    }

    /// Sends a one-off receipt to the watch the first time a payment is verified final,
    /// so it appears there (and as a watch notification) without opening anything.
    private func publishReceipts() async {
        guard let wallet else { return }
        let rows = await receiptRows(hidden: wallet.hideBalances)
        guard watchReady else { return }
        for row in rows {
            guard let id = row["id"] as? String, let status = row["status"] as? String, status.hasPrefix("Finalized"),
                  !announcedReceipts.contains(id) else { continue }
            let key = "watch.receiptAnnounced." + id
            guard !UserDefaults.standard.bool(forKey: key) else { announcedReceipts.insert(id); continue }
            UserDefaults.standard.set(true, forKey: key); announcedReceipts.insert(id)
            var info = row; info["type"] = "receipt"
            WCSession.default.transferUserInfo(info)
        }
        republish()
    }

    /// Called whenever the iPhone node verifies a balance. A verified increase
    /// becomes a "NOID received" receipt on the watch, labeled with its block.
    func observeVerifiedBalance(owner: String, micronoid: String, height: UInt64) {
        guard AddressValidator.valid(owner), let units = UInt64(micronoid) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: Self.lastBalanceKey) ?? [:]
        let previous = saved[owner] as? [String: Any]
        saved[owner] = ["units": NSNumber(value: units), "height": NSNumber(value: height)]
        UserDefaults.standard.set(saved, forKey: Self.lastBalanceKey)
        guard let previous, let oldUnits = (previous["units"] as? NSNumber)?.uint64Value,
              let oldHeight = (previous["height"] as? NSNumber)?.uint64Value, height > oldHeight, units > oldUnits,
              let amount = Amounts.format(String(units - oldUnits)) else { return }
        let hidden = wallet?.hideBalances ?? true
        let receipt: [String: Any] = ["id": "balance-\(owner.prefix(12))-\(height)", "title": "NOID received",
                                      "summary": "Balance up \(amount) NOID", "status": "Finalized · verified balance at block \(height)",
                                      "direction": "received", "account": owner, "height": String(height),
                                      "time": Date().timeIntervalSince1970]
        var incoming = UserDefaults.standard.array(forKey: "watch.incomingReceipts.v1") as? [[String: Any]] ?? []
        incoming.insert(receipt, at: 0)
        UserDefaults.standard.set(Array(incoming.prefix(20)), forKey: "watch.incomingReceipts.v1")
        guard watchReady else { return }
        var info = receipt; info["type"] = "receipt"
        if hidden { info["summary"] = "NOID received" }
        WCSession.default.transferUserInfo(info)
        republish()
    }

    // MARK: Requests (watch → phone)

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let request = message
        Task { @MainActor in
            let reply: [String: Any]
            do { reply = try await self.handle(request) }
            catch { reply = ["ok": false, "error": String(error.localizedDescription.prefix(240))] }
            replyHandler(reply)
        }
    }

    private func handle(_ request: [String: Any]) async throws -> [String: Any] {
        guard let wallet, let type = request["type"] as? String else { throw AppFailure("Open Parano1d Wallet on your iPhone.") }
        remember()
        guard wallet.localWallet != nil || identity != nil else { throw AppFailure("Open Parano1d on your iPhone and unlock it once to connect the watch.") }
        switch type {
        case "contacts":
            guard let rows = await contactRows() else { throw AppFailure("Unlock your iPhone once to show your chats here.") }
            return ["ok": true, "contacts": rows]
        case "avatar":
            return ["ok": true, "png": try await avatarPNG(contactID: request["id"] as? String ?? "") as Any]
        case "unlock":
            _ = try await authenticate(pin: request["pin"] as? String ?? "")
            return ["ok": true, "until": session?.until.timeIntervalSince1970 ?? 0]
        case "lock":
            endSession(); return ["ok": true]
        case "conversation":
            return ["ok": true, "messages": try await conversation(contactID: request["id"] as? String ?? "")]
        case "send_message":
            try await sendMessage(contactID: request["id"] as? String ?? "", text: request["text"] as? String ?? "")
            return ["ok": true]
        case "request_create":
            try await createRequest(contactID: request["id"] as? String ?? "", amount: request["amount"] as? String ?? "", memo: request["memo"] as? String ?? "")
            return ["ok": true]
        case "request_decline":
            try await declineRequest(contactID: request["id"] as? String ?? "", invoice: request["invoice"] as? String ?? "", amount: request["amount"] as? String ?? "")
            return ["ok": true]
        case "pay_review":
            return try await payReview(request)
        case "pay_approve":
            return try await payApprove(request)
        case "pay_handoff":
            return try await handoff(contactID: request["id"] as? String ?? "", amount: request["amount"] as? String ?? "")
        case "confirm_decision":
            guard let id = request["id"] as? String, let waiting = confirmations.removeValue(forKey: id) else {
                throw AppFailure("This iPhone confirmation is no longer waiting.")
            }
            waiting.resume(returning: request["approve"] as? Bool == true)
            return ["ok": true]
        case "account_select":
            guard let index = (request["index"] as? NSNumber)?.uint32Value else { throw AppFailure("Choose an account.") }
            let context = try await authenticate(pin: request["pin"] as? String ?? "")
            let summary = try await WalletVault.shared.selectAccount(index, context: context)
            // While the app is locked, only the watch's remembered identity changes;
            // the iPhone reads the saved selection when it is next unlocked.
            if wallet.locked {
                if var saved = identity { saved.owner = summary.address; saved.accounts = summary.accounts; saved.selected = summary.selectedIndex; identity = saved }
                if let last = lastArguments { lastArguments = (summary.address, last.walletName, nil, "Switched account · open the iPhone app to verify", last.hidden) }
            } else { wallet.apply(summary); remember() }
            reviews.removeAll()
            republish()
            return ["ok": true]
        case "nfts":
            return ["ok": true, "items": try await nftRows()]
        case "nft_image":
            return ["ok": true, "png": await nftImage(request["id"] as? String ?? "") as Any]
        default:
            if let reply = try await WatchBridgeEdition.handle(type, request, bridge: self) { return reply }
            throw AppFailure("This watch request is not supported by the iPhone app.")
        }
    }

    // MARK: PIN session

    /// Verifies the app PIN with the phone's own attempt limits and returns a
    /// Keychain context that can open the wallet without Face ID. Requires the
    /// iPhone to be unlocked (the wallet key is device-unlock protected).
    private func authenticate(pin: String) async throws -> LAContext {
        guard pin.count >= 4, pin.count <= 64 else { throw AppFailure("Enter your Parano1d app PIN.") }
        try requireUnlockedPhone()
        guard try await AppLockStore.shared.kind() != nil else { throw AppFailure("Set an app PIN on your iPhone (Settings → Wallet) to confirm from the watch.") }
        guard try await WalletVault.shared.hasPINAccess() else { throw AppFailure("Unlock Parano1d once on your iPhone with your app PIN to enable watch confirmation.") }
        try await AppLockStore.shared.verify(pin)
        let context = LAContext()
        guard context.setCredential(Data(pin.utf8), type: .applicationPassword) else { throw AppFailure("PIN confirmation is unavailable.") }
        endSession()
        let now = Date()
        session = (context, now.addingTimeInterval(Self.sessionIdle), now)
        return context
    }
    /// The session slides forward with use, up to a hard maximum.
    func activeContext() throws -> LAContext {
        guard let current = session, Date() < current.until else { endSession(); throw AppFailure("pin_required") }
        // Chats and the wallet key are only readable while the iPhone itself is unlocked.
        guard UIApplication.shared.isProtectedDataAvailable else { throw AppFailure("Unlock your iPhone to read and send messages.") }
        let cap = current.started.addingTimeInterval(Self.sessionMaximum)
        session = (current.context, min(Date().addingTimeInterval(Self.sessionIdle), cap), current.started)
        return current.context
    }
    private func endSession() {
        session?.context.setCredential(nil, type: .applicationPassword)
        session?.context.invalidate()
        session = nil
        openedRows = [:]
    }
    /// The wallet key and payment files are protected until the iPhone is unlocked.
    private func requireUnlockedPhone() throws {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw AppFailure("phone:Unlock your iPhone to finish. You can also continue this on your iPhone.")
        }
    }

    // MARK: Chat

    func profile(context: LAContext) async throws -> (card: [String: Any], id: String) {
        guard let root, let invitation = try await MessagingProfileStore.shared.invitation(for: root) else {
            throw AppFailure("Set up chat on your iPhone first.")
        }
        let own = try await ConnectedContact.inspect(invitation)
        guard own.address == root else { throw AppFailure("Messaging identity does not match this wallet.") }
        return (own.card, own.id)
    }
    private func contact(_ id: String) async throws -> ConnectedContact {
        guard let found = (try await ContactBook.shared.load()).first(where: { $0.id == id }) else { throw AppFailure("This contact is no longer saved on your iPhone.") }
        return found
    }

    private func conversation(contactID: String) async throws -> [[String: Any]] {
        let context = try activeContext()
        let contact = try await contact(contactID)
        guard !PrivateChatBlocks.contains(contact.id) else { return [] }
        let own = try await profile(context: context)
        let packets = try await MessageArchive.shared.packets(identity: own.id)
            .filter { $0.contactID == contact.id }.sorted { $0.date > $1.date }.prefix(40)
        let declined = self.declined
        var rows: [[String: Any]] = []
        for packet in packets.reversed() {
            if var cached = openedRows[packet.id] {
                if let invoice = cached["invoice"] as? String, declined.contains(invoice) { cached["declined"] = true; cached["payable"] = false }
                rows.append(cached); continue
            }
            guard let envelope = try? JSONSerialization.jsonObject(with: packet.envelope) as? [String: Any],
                  let opened = try? await WalletVault.shared.message(["op": packet.received ? "chat_open_archived" : "chat_open_saved", "envelope": envelope,
                                                                       "contact": contact.card, "now_ms": UInt64(Date().timeIntervalSince1970 * 1000)], context: context)
            else { continue }
            var row: [String: Any] = ["id": packet.id, "in": packet.received, "time": packet.date.timeIntervalSince1970]
            if let card = ChatPaymentPreview(opened) {
                row["kind"] = card.kind == .request ? "request" : card.kind == .receipt ? "receipt" : "payment"
                if let amount = card.amount { row["amount"] = amount }
                if let invoice = card.invoiceID {
                    row["invoice"] = invoice
                    if declined.contains(invoice) { row["declined"] = true }
                }
                // A request is payable from the watch only when it pays the contact's own saved address.
                row["payable"] = card.kind == .request && packet.received && card.address == contact.address
                    && !(card.invoiceID.map(declined.contains) ?? false)
                if !card.note.isEmpty { row["text"] = String(card.note.prefix(256)) }
            } else if let text = opened["text"] as? String {
                if packet.received, let reason = PublicChatSafety.contentReason(text) { row["text"] = "Message hidden: " + reason; row["hidden"] = true }
                else { row["text"] = String(SharedAvatar.displayText(text).prefix(1000)) }
            } else { continue }
            if openedRows.count > 400 { openedRows = [:] }
            openedRows[packet.id] = row
            rows.append(row)
        }
        return rows
    }

    /// Seals an envelope for a contact, saves it and delivers it the same way the phone does.
    private func deliver(_ result: [String: Any], contact: ConnectedContact, own: (card: [String: Any], id: String)) async throws {
        guard let envelope = result["envelope"] as? [String: Any], let id = envelope["id"] as? String else { throw AppFailure("The message could not be sealed.") }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        try await MessageArchive.shared.append(.init(id: id, contactID: contact.id, received: false, date: Date(), envelope: data), identity: own.id)
        if let nearby, nearby.enabled { try? await nearby.offer(data) }
        if UserDefaults.standard.bool(forKey: "chatOnlineDeliveryEnabled"), wallet?.offlineMode == false {
            try await MessageRelay.shared.send(data)
            if let context = try? activeContext() { await InstantAlerts.ping(recipient: contact.id, context: context) }
        }
    }

    private func sendMessage(contactID: String, text raw: String) async throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, CommunityReply.fits(text) else { throw AppFailure("Messages must be 1 to 4,096 bytes.") }
        if let reason = PublicChatSafety.contentReason(text) { throw AppFailure(reason + " breaks the chat rules.") }
        let context = try activeContext()
        let contact = try await contact(contactID)
        guard !PrivateChatBlocks.contains(contact.id) else { throw AppFailure("You blocked this contact.") }
        let own = try await profile(context: context)
        let result = try await WalletVault.shared.message(["op": "chat_seal", "sender": own.card, "contact": contact.card, "text": text,
                                                           "now_ms": UInt64(Date().timeIntervalSince1970 * 1000)], context: context)
        try await deliver(result, contact: contact, own: own)
    }

    /// Creates a payment request to a contact, paid to this wallet's messaging address (same as the phone).
    private func createRequest(contactID: String, amount raw: String, memo rawMemo: String) async throws {
        guard let units = Amounts.parse(raw), let value = UInt64(units), value > 0, let amount = Amounts.format(units) else { throw AppFailure("Enter a positive NOID amount.") }
        let memo = String(rawMemo.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard memo.utf8.count <= 256 else { throw AppFailure("The note is too long.") }
        if !memo.isEmpty, let reason = PublicChatSafety.contentReason(memo) { throw AppFailure(reason + " breaks the chat rules.") }
        let context = try activeContext()
        let contact = try await contact(contactID)
        guard !PrivateChatBlocks.contains(contact.id) else { throw AppFailure("You blocked this contact.") }
        let own = try await profile(context: context)
        let invoiceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let result = try await WalletVault.shared.message(["op": "chat_seal_invoice", "sender": own.card, "contact": contact.card, "invoice_id": invoiceID,
                                                           "amount": amount, "memo": memo, "now_ms": UInt64(Date().timeIntervalSince1970 * 1000)], context: context)
        try await deliver(result, contact: contact, own: own)
    }

    /// Declines a request: marks it declined here and tells the requester in an encrypted message.
    private func declineRequest(contactID: String, invoice: String, amount: String) async throws {
        guard invoice.count == 32, invoice.allSatisfy({ $0.isHexDigit }) else { throw AppFailure("This request can't be declined from the watch.") }
        let context = try activeContext()
        let contact = try await contact(contactID)
        let own = try await profile(context: context)
        var set = declined; set.insert(invoice); declined = set
        let label = Amounts.parse(amount).flatMap { Amounts.format($0) }.map { " for \($0) NOID" } ?? ""
        let result = try await WalletVault.shared.message(["op": "chat_seal", "sender": own.card, "contact": contact.card,
                                                           "text": "Declined your payment request\(label).",
                                                           "now_ms": UInt64(Date().timeIntervalSince1970 * 1000)], context: context)
        try await deliver(result, contact: contact, own: own)
    }

    private func avatarPNG(contactID: String) async throws -> Data? {
        guard SharedAvatar.hex(contactID),
              let avatar = await PeerAvatarStore.shared.avatar(identity: contactID, root: root, publicOnly: false),
              avatar.kind == "character", let recipe = avatar.character else { return nil }
        let renderer = ImageRenderer(content: CharacterAvatarArt(configuration: recipe).frame(width: 72, height: 72))
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }

    // MARK: NFTs (view only; holdings verified on this iPhone)

    private func ownedNFTs() throws -> [NativeItem] {
        guard let live, let owner = wallet?.address else { return [] }
        // View only: current verified holdings, or the last verified holdings saved on this iPhone
        // (their block height is sent with each row so the watch can label them).
        guard live.holdingsVerifiedLocally || live.savedHoldingsHeight != nil else { throw AppFailure("Open the NFTs tab on your iPhone once to load your NFTs.") }
        return live.holdings.filter { $0.type == "nft" && $0.text("owner") == owner }
    }
    private func nftRows() async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for item in try ownedNFTs().prefix(40) {
            let hash = item.text("metadata_hash")
            let name = hash.count == 64 ? (try? await AssetMedia.shared.loadName(hash: hash)) : nil
            rows.append(["id": item.id, "name": String((name ?? "NFT #" + item.text("serial")).prefix(48)),
                         "serial": item.text("serial"), "collection": String(item.collection.prefix(16)),
                         "height": (live?.holdingsHeight ?? live?.savedHoldingsHeight).map { String($0) } ?? ""])
        }
        return rows
    }
    /// Uses only artwork already cached on the iPhone unless "Show NFT artwork" is on.
    private func nftImage(_ id: String) async -> Data? {
        guard let item = try? ownedNFTs().first(where: { $0.id == id }) else { return nil }
        let hash = item.text("metadata_hash")
        guard hash.count == 64 else { return nil }
        let display: AssetDisplay?
        if (UserDefaults.standard.object(forKey: "externalMedia") as? Bool ?? true), wallet?.offlineMode == false { display = try? await AssetMedia.shared.load(hash: hash) }
        else { display = try? await AssetMedia.shared.loadCached(hash: hash) }
        guard let image = display?.image else { return nil }
        // Detailed artwork can exceed the watch message limit at full quality, so step the
        // size and quality down until it fits instead of sending nothing.
        for (side, quality) in [(240.0, 0.7), (200.0, 0.6), (160.0, 0.5), (120.0, 0.45), (96.0, 0.4)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let size = CGSize(width: side, height: side)
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= 40 * 1024 { return data }
        }
        return nil
    }

    // MARK: Payments

    private func payReview(_ request: [String: Any]) async throws -> [String: Any] {
        guard sendsEnabled else { throw AppFailure("Turn on Sends from Apple Watch in Settings → Wallet on your iPhone.") }
        guard let wallet, let node, (wallet.localWallet?.recoveryVerified ?? identity?.verified) == true else { throw AppFailure("Finish your wallet backup on the iPhone before sending.") }
        guard !wallet.offlineMode else { throw AppFailure("Your iPhone is in Offline mode.") }
        try requireUnlockedPhone()
        let contact = try await contact(request["id"] as? String ?? "")
        guard let owner else { throw AppFailure("Open Parano1d on your iPhone and unlock it once to connect the watch.") }
        guard !PrivateChatBlocks.contains(contact.id), contact.address != owner else { throw AppFailure("Choose another contact.") }
        guard let requested = Amounts.parse(request["amount"] as? String ?? ""), let units = UInt64(requested), units > 0 else { throw AppFailure("Enter a positive NOID amount.") }
        // Cases the watch can't approve on its own are handed to the iPhone ("phone:" prefix).
        if let previous = UserDefaults.standard.string(forKey: Self.lastPaidKey(contact.id)), previous != contact.address {
            throw AppFailure("phone:\(contact.name)'s address changed since your last payment. Confirm it on your iPhone.")
        }
        guard let root else { throw AppFailure("Open Parano1d Wallet on your iPhone.") }
        let directory = try PaymentStorage.directory(root: root)
        let pending = try await NativeCore.shared.call(["op": "payment_pending", "journal_directory": directory.path])
        // Several NOID payments may be pending; a pending token/NFT transfer reserves everything.
        let open = PendingLedger.unresolved(pending)
        if open.contains(where: { ($0["claims"] as? [String: Any])?["exclusive"] as? Bool == true }) {
            throw AppFailure("A transaction that reserves your whole wallet is still settling. Try again once it confirms.")
        }
        if open.count >= 20 { throw AppFailure("Twenty transactions are pending. Wait for some to confirm.") }
        let plan = try await node.paymentOperation(["op": "payment_plan", "owner": owner, "address": contact.address, "use_cached": false,
                                                    "amount": Amounts.format(requested) ?? "", "journal_directory": directory.path])
        guard plan["owner"] as? String == owner, plan["to"] as? String == contact.address,
              let plannedAmount = plan["amount"] as? String, Amounts.parse(plannedAmount) == requested,
              let fee = plan["fee"] as? String, let feeRaw = Amounts.parse(fee),
              let unsigned = plan["unsigned_intent"] as? String, let digest = plan["review_id"] as? String,
              let chain = plan["chain_id"] as? String else { throw AppFailure("The payment plan differs from your request.") }
        let reviewRequest: [String: Any] = ["op": "payment_review", "unsigned_intent": unsigned, "review_id": digest, "owner": owner, "to": contact.address,
                                            "amount_micronoid": requested, "fee_micronoid": feeRaw, "maximum_fee_micronoid": "100000", "chain_id": chain,
                                            "send_max": false, "using_saved_state": plan["using_saved_state"] as? Bool ?? false]
        let checked = try await NativeCore.shared.call(reviewRequest)
        guard let txid = checked["txid"] as? String else { throw AppFailure("The payment review failed.") }
        let id = UUID().uuidString
        let expires = Date().addingTimeInterval(90)
        reviews = reviews.filter { $0.value.expires > Date() }
        reviews[id] = Review(id: id, digest: digest, plan: reviewRequest, expectedTxid: txid, contactID: contact.id, address: contact.address,
                             amountRaw: requested, expires: expires)
        let total = (UInt64(requested) ?? 0) + (UInt64(feeRaw) ?? 0)
        return ["ok": true, "review": id, "digest": digest, "name": contact.name, "address": contact.address,
                "account": owner, "amount": Amounts.format(requested) ?? plannedAmount, "fee": Amounts.format(feeRaw) ?? fee,
                "total": Amounts.format(String(total)) ?? "", "expires": expires.timeIntervalSince1970]
    }

    private func payApprove(_ request: [String: Any]) async throws -> [String: Any] {
        guard sendsEnabled else { throw AppFailure("Sends from Apple Watch are turned off on your iPhone.") }
        guard let node, let root, let owner else { throw AppFailure("Open Parano1d Wallet on your iPhone.") }
        let reviewID = request["review"] as? String ?? ""
        guard let review = reviews[reviewID] else { throw AppFailure("This review is no longer valid. Review the payment again.") }
        // Exactly one approval per review: expired, changed or repeated approvals are rejected.
        guard !usedApprovals.contains(reviewID) else { throw AppFailure("This approval was already used.") }
        guard Date() < review.expires else { reviews.removeValue(forKey: reviewID); throw AppFailure("This review expired. Review the payment again.") }
        // The watch sends back the exact address and amount the user confirmed on screen.
        guard request["digest"] as? String == review.digest, request["amount"] as? String == Amounts.format(review.amountRaw),
              request["address"] as? String == review.address, request["id"] as? String == review.contactID else {
            throw AppFailure("The confirmed address or amount differs from the payment. Nothing was sent.")
        }
        // The contact must still have the reviewed address.
        guard (try? await contact(review.contactID))?.address == review.address else { throw AppFailure("The contact changed after review. Review again.") }
        // The PIN is checked first (with the phone's attempt limits), so a typo does not burn the review.
        let context = try await authenticate(pin: request["pin"] as? String ?? "")
        guard reviews[reviewID] != nil, !usedApprovals.contains(reviewID) else { throw AppFailure("This approval was already used.") }
        usedApprovals.insert(reviewID); reviews.removeValue(forKey: reviewID)
        guard review.plan["owner"] as? String == owner else { throw AppFailure("The selected account changed after review. Review again.") }
        let epoch = try await node.paymentOperation(["op": "payment_epoch_check", "owner": owner,
                                                     "unsigned_intent": review.plan["unsigned_intent"] ?? "", "review_id": review.digest])
        guard epoch["review_id"] as? String == review.digest else { throw AppFailure("The payment review expired. Review again.") }
        var authorization = review.plan
        authorization["offline_delivery"] = false
        // The wallet core also checks that what the watch showed and confirmed is this payment.
        authorization["confirmed_to"] = request["address"] as? String ?? ""
        authorization["confirmed_amount_micronoid"] = Amounts.parse(request["amount"] as? String ?? "") ?? ""
        authorization["confirmed_review_id"] = request["digest"] as? String ?? ""
        let authorized = try await WalletVault.shared.authorizePayment(authorization, source: .watch, context: context)
        guard authorized["txid"] as? String == review.expectedTxid, let intent = authorized["intent_hex"] as? String else {
            throw AppFailure("The signed payment differs from the review. Nothing was sent.")
        }
        UserDefaults.standard.set(review.address, forKey: Self.lastPaidKey(review.contactID))
        try? await LocalPaymentHistory.shared.record(root: root, owner: owner, id: review.expectedTxid, kind: "NOID transfer",
                                                     amount: review.amountRaw, recipient: review.address,
                                                     status: "Authorized from Apple Watch · settlement not verified")
        let sent = try await node.paymentOperation(["op": "broadcast_send", "intent_hex": intent, "txid": review.expectedTxid])
        guard sent["txid"] as? String == review.expectedTxid else { return ["ok": true, "txid": review.expectedTxid, "stage": "signed"] }
        try? await LocalPaymentHistory.shared.record(root: root, owner: owner, id: review.expectedTxid, kind: "NOID transfer",
                                                     status: "Submitted from Apple Watch · confirmation not verified")
        Task { await PaymentReconciliation.refreshPending(root: root, node: node) }
        return ["ok": true, "txid": review.expectedTxid, "stage": "broadcast"]
    }

    /// Hands a payment the watch can't approve to the iPhone's own Send review.
    /// Nothing is signed here; the iPhone asks for its usual authentication.
    private func handoff(contactID: String, amount: String) async throws -> [String: Any] {
        let contact = try await contact(contactID)
        guard !PrivateChatBlocks.contains(contact.id) else { throw AppFailure("You blocked this contact.") }
        let formatted = Amounts.parse(amount).flatMap { Amounts.format($0) } ?? ""
        Self.pendingHandoff = (contact.address, formatted)
        if UIApplication.shared.applicationState == .active {
            NotificationCenter.default.post(name: Self.handoffOpened, object: nil)
        } else {
            let content = UNMutableNotificationContent()
            content.title = "Finish payment on iPhone"
            content.body = formatted.isEmpty ? "Review the payment to \(contact.name)." : "Review \(formatted) NOID to \(contact.name)."
            content.sound = .default
            content.userInfo = ["route": "watch_pay"]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-handoff", content: content, trigger: nil))
        }
        return ["ok": true]
    }

    // MARK: Watch confirmation of iPhone sends

    /// When "Confirm iPhone sends on Apple Watch" is on, asks the watch to approve
    /// a payment already reviewed and authenticated on the iPhone. Throws if the
    /// watch declines, can't be reached, or doesn't answer in time.
    func confirmOnWatchIfRequired(title: String, recipient: String, amount: String?, fee: String?) async throws {
        guard UserDefaults.standard.bool(forKey: Self.confirmPhoneSendsKey), WCSession.isSupported() else { return }
        guard watchReady else { throw AppFailure("Apple Watch confirmation is on, but no paired watch has Parano1d installed. Turn it off in Settings → Wallet → Apple Watch.") }
        var waited = 0
        while !WCSession.default.isReachable && waited < 30 {
            try await Task.sleep(nanoseconds: 1_000_000_000); waited += 1
        }
        guard WCSession.default.isReachable else { throw AppFailure("Open Parano1d on your Apple Watch to confirm this payment, then try again.") }
        let names = Dictionary(((try? await ContactBook.shared.load()) ?? []).map { ($0.address, $0.name) }, uniquingKeysWith: { first, _ in first })
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "confirm_request", "id": id, "title": String(title.prefix(60)), "to": recipient,
                                      "expires": Date().addingTimeInterval(60).timeIntervalSince1970]
        if let name = names[recipient] { message["name"] = String(name.prefix(40)) }
        if let amount { message["amount"] = amount }
        if let fee { message["fee"] = fee }
        let approved: Bool = try await withCheckedThrowingContinuation { continuation in
            confirmations[id] = continuation
            WCSession.default.sendMessage(message, replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.confirmations.removeValue(forKey: id)?.resume(throwing: AppFailure("The watch did not receive the confirmation request.")) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.confirmations.removeValue(forKey: id)?.resume(throwing: AppFailure("The watch confirmation timed out. Nothing was sent."))
            }
        }
        guard approved else { throw AppFailure("Declined on Apple Watch. Nothing was sent.") }
    }

    /// Tells an open watch app that a contact's conversation changed. Carries only
    /// the contact ID; the watch fetches the messages through the PIN session.
    private var holdingsWatch: AnyCancellable?
    private func pulse(type: String) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled, session.isReachable else { return }
        session.sendMessage(["type": type], replyHandler: nil, errorHandler: nil)
    }
    func chatArrived(contactID: String) {
        let session = WCSession.default
        guard contactID.count == 64, session.activationState == .activated, session.isWatchAppInstalled, session.isReachable else { return }
        session.sendMessage(["type": "chat_update", "id": contactID], replyHandler: nil, errorHandler: nil)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.lastSnapshot = [:] }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.lastSnapshot = [:] }
    }
    /// The message session ends if the watch stays out of reach for 30 seconds.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.unreachableLock?.cancel()
            guard !reachable else { return }
            self.unreachableLock = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled, !WCSession.default.isReachable { self.endSession() }
            }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

/// Phone-side controls for the Apple Watch (Settings → Wallet → Apple Watch).
struct WatchSendSettingsView: View {
    @EnvironmentObject private var wallet: WalletState
    @AppStorage(WatchBridge.settingKey) private var enabled = false
    @AppStorage(WatchBridge.confirmPhoneSendsKey) private var confirmPhone = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Toggle("Allow sends from Apple Watch", isOn: $enabled)
            } header: { Text("Send from the watch") } footer: {
                Text("Watch sends go only to your saved contacts. You review the amount and fee on the watch and confirm with your app PIN; this iPhone checks the PIN, signs and broadcasts. Your iPhone must be unlocked and nearby. There's no amount limit. A contact whose address changed continues on the iPhone.")
            }.themedRow()
            Section {
                Toggle("Confirm iPhone sends on Apple Watch", isOn: Binding(get: { confirmPhone }, set: setConfirm))
                if let error { Text(error).font(Theme.caption).foregroundStyle(.orange) }
            } header: { Text("Second confirmation") } footer: {
                Text("After you approve a send on this iPhone, your watch shows the payment and you approve it there too. Keep Parano1d open on the watch while sending. Turning this off requires your iPhone authentication.")
            }.themedRow()
        }
        .modifier(WalletSettingsSurface()).navigationTitle("Apple Watch")
        .onChange(of: enabled) { _, _ in WatchBridge.shared.republish() }
    }
    private func setConfirm(_ on: Bool) {
        guard !on else { confirmPhone = true; WatchBridge.shared.republish(); return }
        Task {
            do { _ = try await wallet.requireAuthentication("Turn off Apple Watch confirmation", fresh: true); confirmPhone = false; error = nil; WatchBridge.shared.republish() }
            catch { self.error = error.localizedDescription }
        }
    }
}
#else
/// Mac (Catalyst) and other platforms without WatchConnectivity: no watch features.
@MainActor final class WatchBridge {
    static let shared = WatchBridge()
    static let handoffOpened = Notification.Name("WatchBridgeHandoffOpened")
    static var pendingHandoff: (address: String, amount: String)?
    func attach(wallet: WalletState, node: DeviceNode, nearby: NearbyTransport, live: LiveData? = nil, quotes: PriceFeed? = nil) {}
    func publish(address: String, walletName: String, balance: String?, status: String, hidden: Bool) {}
    func republish() {}
    func observeVerifiedBalance(owner: String, micronoid: String, height: UInt64) {}
    func confirmOnWatchIfRequired(title: String, recipient: String, amount: String?, fee: String?) async throws {}
    func chatArrived(contactID: String) {}
}
struct WatchSendSettingsView: View {
    var body: some View {
        Form { Text("Apple Watch features are available on iPhone.").foregroundStyle(Theme.secondary) }
            .modifier(WalletSettingsSurface()).navigationTitle("Apple Watch")
    }
}
#endif

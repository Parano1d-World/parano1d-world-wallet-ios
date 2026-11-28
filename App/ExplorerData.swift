import SwiftUI

actor ExplorerClient {
    static let shared = ExplorerClient()
    static let website = URL(string: "https://parano1d-scan.com")!
    private let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    func query(_ path: String) async throws -> [String: Any] {
        let url = Self.website.appendingPathComponent("api").appendingPathComponent(path)
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppFailure("Explorer unavailable. Please try again later.") }
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < 2 * 1024 * 1024 else { throw AppFailure("Explorer response exceeded the limit.") }
            bytes.append(byte)
        }
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AppFailure("Invalid explorer response.") }
        return result
    }
    func address(_ address: String) async throws -> [String: Any] {
        guard AddressValidator.valid(address) else { throw AppFailure("Invalid explorer address.") }
        let result = try await query("address/" + address)
        guard result["address"] as? String == address else { throw AppFailure("Explorer returned a different address.") }
        return result
    }
}
/// Explorer pages open in the Parano1d World explorer when it answers its status check,
/// and in NOID Scan otherwise, so a link never lands on a site that is down.
enum ExplorerPages {
    static let primary = URL(string: "https://parano1dworld.com")!
    static func primaryTransaction(_ id: String) -> URL { URL(string: "https://parano1dworld.com/#Explorer/tx/" + id)! }
    static func backupTransaction(_ id: String) -> URL { ExplorerClient.website.appendingPathComponent("tx").appendingPathComponent(id) }
    private static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    /// True only when the explorer's own status endpoint answers 200 within a few seconds.
    static func primaryAvailable() async -> Bool {
        var request = URLRequest(url: primary.appendingPathComponent("api/explorer/status"))
        request.timeoutInterval = 4; request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
    /// In Parano1d mode the app sends no status request: the browser opens the Parano1d World page directly.
    static func transaction(_ id: String) async -> URL {
        if NodeEndpoints.paranoid { return primaryTransaction(id) }
        return await primaryAvailable() ? primaryTransaction(id) : backupTransaction(id)
    }
}
struct TransactionExplorerLink: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @Environment(\.openURL) private var openURL
    @State private var opening = false
    let transactionID: String
    var body: some View {
        if transactionID.count == 64, Data(hex: transactionID)?.count == 32 {
            Button {
                guard !opening else { return }
                opening = true
                Task { let url = await ExplorerPages.transaction(transactionID); opening = false; openURL(url) }
            } label: {
                Label("Look up transaction in explorer", systemImage: "arrow.up.right.square")
            }.disabled(opening)
        }
    }
}
@MainActor final class PriceFeed: ObservableObject {
    @Published private(set) var price: Decimal?
    @Published private(set) var updated: Date?
    @Published private(set) var source = ""
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var nextAttempt = Date.distantPast
    private var generation = UUID()
    init() {
        if let saved=UserDefaults.standard.dictionary(forKey:"public.noid.usdQuote"),
           let raw=saved["price"] as? String,let value=Decimal(string:raw),value>0,
           let date=saved["updated"] as? Date,date<=Date() {
            price=value;updated=date;source=saved["source"] as? String ?? "Saved quote"
        }
    }
    /// How old a USD quote may be and still be shown. NOID Scan updates its quote every several minutes,
    /// so a 5-minute limit left the price and USD values blank most of the time.
    nonisolated static let maxQuoteAge: TimeInterval = 1800
    /// The one price every screen uses (price chip, balance USD, sends, watch): nil once the quote is too old.
    var currentPrice: Decimal? {
        guard let updated, Date().timeIntervalSince(updated) <= Self.maxQuoteAge, updated.timeIntervalSinceNow <= 60 else { return nil }
        return price
    }
    func usd(_ amount: String?) -> String? {
        guard let amount, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), value >= 0, let price = currentPrice else { return nil }
        return Self.currency(value * price)
    }
    nonisolated static func currency(_ amount: Decimal) -> String? {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "USD"; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount))
    }
    nonisolated static func quoteDate(_ text:String)->Date? {
        let fractional=ISO8601DateFormatter()
        fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return fractional.date(from:text) ?? ISO8601DateFormatter().date(from:text)
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; nextAttempt = .distantPast }
    func refresh() {
        guard task == nil, Date() >= nextAttempt else { return }
        nextAttempt = Date().addingTimeInterval(60); let token = generation
        task = Task {
            defer { if token == generation { task = nil } }
            if let quote = await PriceSources.best() {
                guard token == generation, !Task.isCancelled else { return }
                price = quote.usd; updated = quote.updated; source = quote.source; error = nil
                UserDefaults.standard.set(["price":NSDecimalNumber(decimal:quote.usd).stringValue,"updated":quote.updated,"source":quote.source],forKey:"public.noid.usdQuote")
            } else if token == generation {
                error = "A fresh USD quote is unavailable."; nextAttempt = Date().addingTimeInterval(10)
            }
        }
    }
}
/// NOID/USD sources, best first: SafeTrade's public NOID/USDT ticker (the main market), then the
/// Parano1d World price feed, then NOID Scan. Parano1d mode uses only the Parano1d World feed.
/// USDT is treated as $1. The source is kept internally (never shown) for diagnostics.
/// Each is tried in turn; a source that fails is skipped for five minutes so a down feed never slows the price.
actor PriceSources {
    struct Quote { let usd: Decimal; let updated: Date; let source: String }
    static let shared = PriceSources()
    static let primary = URL(string: "https://parano1dworld.com/api/explorer/price")!
    static let safetrade = URL(string: "https://safe.trade/api/v2/peatio/public/markets/noidusdt/tickers")!
    /// A SafeTrade price is used only when the market traded at least this much USDT in 24 hours.
    static let minimumVolumeUSDT: Decimal = 100
    private var skipUntil: [String: Date] = [:]
    private let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    static func best() async -> Quote? { await shared.best() }
    private func best() async -> Quote? {
        let order = UserDefaults.standard.bool(forKey: "node.paranoidMode.v1") ? ["primary"] : ["safetrade", "primary", "scan"]
        for name in order {
            if let until = skipUntil[name], until > Date() { continue }
            if let quote = try? await fetch(name), Self.fresh(quote) { skipUntil[name] = nil; return quote }
            skipUntil[name] = Date().addingTimeInterval(300)
        }
        return nil
    }
    private static func fresh(_ quote: Quote) -> Bool {
        quote.usd > 0 && quote.updated.timeIntervalSinceNow <= 60 && Date().timeIntervalSince(quote.updated) <= PriceFeed.maxQuoteAge
    }
    private func json(_ url: URL, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.timeoutInterval = timeout; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 256 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure("Price source unavailable.") }
        return object
    }
    private static func decimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 { return number.decimalValue }
        if let text = value as? String, let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), number > 0 { return number }
        return nil
    }
    /// Reads SafeTrade's public ticker. Refuses a missing or zero price, thin markets and bad times.
    static func safetradeQuote(_ body: [String: Any]) throws -> Quote {
        guard let ticker = body["ticker"] as? [String: Any], let usd = decimal(ticker["last"]),
              let volume = decimal(ticker["volume"]) ?? decimal(ticker["vol"]), volume >= minimumVolumeUSDT,
              let at = decimal(body["at"]) ?? decimal(ticker["at"]) else { throw AppFailure("Invalid price.") }
        let seconds = NSDecimalNumber(decimal: at).doubleValue
        guard seconds.isFinite, seconds > 1_600_000_000 else { throw AppFailure("Invalid price.") }
        return Quote(usd: usd, updated: Date(timeIntervalSince1970: seconds), source: "SafeTrade")
    }
    static func isFresh(_ quote: Quote) -> Bool { fresh(quote) }
    private func fetch(_ name: String) async throws -> Quote {
        switch name {
        case "primary":
            let body = try await json(Self.primary, timeout: 5)
            guard let usd = Self.decimal(body["usd"]), let text = body["updated"] as? String, let date = PriceFeed.quoteDate(text) else { throw AppFailure("Invalid price.") }
            return Quote(usd: usd, updated: date, source: "Parano1d World")
        case "scan":
            let stats = try await ExplorerClient.shared.query("stats")
            guard let quote = stats["price"] as? [String: Any], let usd = Self.decimal(quote["usd"]),
                  let text = quote["updated"] as? String, let date = PriceFeed.quoteDate(text) else { throw AppFailure("Invalid price.") }
            return Quote(usd: usd, updated: date, source: "NOID Scan")
        case "safetrade":
            // Peatio public ticker (checked live 24 Nov): {"at": "<unix seconds>", "ticker": {"last",
            // "volume"/"vol" = 24h volume in USDT, "amount" = 24h volume in NOID, ...}}.
            return try Self.safetradeQuote(try await json(Self.safetrade, timeout: 5))
        default:
            throw AppFailure("Unknown price source.")
        }
    }
}
struct ActivityView: View {
    var embedded = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.walletTabActive) private var tabActive
    @State private var localRows:[[String:Any]]=[]
    private let historyClock=Timer.publish(every:30,on:.main,in:.common).autoconnect()
    private var displayedRows:[[String:Any]] {HistoryRows.merge(transactions,localRows)}
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var node: DeviceNode
    @State private var transactions: [[String: Any]] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var lastExplorerAttempt = Date.distantPast
    @State private var snapshotOwner = ""
    @State private var snapshotDate: Date?
    @State private var expandedIDs:Set<String>=[]
    /// Only the most recent 5 show at first; "Show more" reveals the rest.
    @State private var visibleCount=5
    var body: some View {
        Group {
            if embedded {historyContent}
            else {ScrollView {historyContent.padding(24)}.background(AmbientBackground()).navigationTitle("Transaction history").navigationBarTitleDisplayMode(.inline)}
        }
        .task(id: "\(wallet.address)-\(wallet.offlineMode)-\(wallet.locked)") { visibleCount=5; await refresh(force:true) }
        .refreshable { await refresh(force:true) }
        .onReceive(historyClock) { _ in
            if tabActive,phase == .active,!wallet.locked,!loading {Task {await refresh()}}
        }
        .onChange(of:phase) {_,newPhase in
            if newPhase == .active,tabActive,!wallet.locked {Task {await refresh(force:true)}}
        }
        .onChange(of:node.verifiedHeight) {oldHeight,newHeight in
            if oldHeight != newHeight,tabActive,phase == .active,!wallet.locked {Task {await refresh()}}
        }
        .onReceive(NotificationCenter.default.publisher(for:LocalPaymentHistory.changed).receive(on:RunLoop.main)) { _ in
            if tabActive,phase == .active,!wallet.locked,!loading {Task {await refresh()}}
        }
        .onChange(of:node.running) {wasRunning,isRunning in
            if wasRunning && !isRunning && tabActive && phase == .active && !wallet.locked && !loading {
                Task {await refresh()}
            }
        }
    }
    private func showMoreLabel(_ remaining:Int)->some View {
        HStack(spacing:6) {
            Text("Show more").font(Theme.subheadline.weight(.semibold))
            Text("\(remaining) older").font(Theme.caption).foregroundStyle(Theme.secondary)
            Image(systemName:embedded ? "chevron.right" : "chevron.down").font(Theme.caption)
        }.foregroundStyle(Theme.mint).frame(maxWidth:.infinity).padding(.vertical,12).themedCard(14)
        .accessibilityLabel("Show more transactions, \(remaining) older")
    }
    private var historyContent:some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("Transaction history",systemImage:"clock.arrow.circlepath").font(Theme.editorial(embedded ? 24 : 34))
                    Spacer()
                }
                if let date=snapshotDate {Text("Saved history · " + date.formatted(date:.abbreviated,time:.shortened)).font(Theme.caption).foregroundStyle(Theme.secondary)}
                if !embedded {
                    Text("Explorer history is partial and is not independent proof of settlement.").font(Theme.footnote).foregroundStyle(Theme.secondary)
                }
                HStack(spacing:12) {
                    Button { Task { await refresh(force:true) } } label: {
                        ThemedLabel("Refresh activity", systemImage: "arrow.clockwise")
                    }
                    .disabled(wallet.offlineMode || wallet.locked || loading)
                    Spacer()
                    if loading { ProgressView().accessibilityLabel("Refreshing activity") }
                }.font(Theme.subheadline).foregroundStyle(Theme.mint)
                if node.running {
                    Text("The device node is catching up. Recent payments may appear as verification advances.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                if let error { Text(error).font(Theme.footnote).foregroundStyle(.orange) }
                ForEach(Array(displayedRows.prefix(embedded ? 5 : visibleCount).enumerated()), id: \.offset) { _, transaction in
                    if let id = transaction["txid"] as? String, id.count == 64, Data(hex: id)?.count == 32 {
                        ActivityTransactionRow(transaction:transaction,id:id,hideAmounts:wallet.hideBalances,isExpanded:Binding(
                            get:{expandedIDs.contains(id)},
                            set:{if $0 {expandedIDs.insert(id)} else {expandedIDs.remove(id)}}
                        ))
                    }
                }
                if displayedRows.count > (embedded ? 5 : visibleCount) {
                    let remaining = displayedRows.count - (embedded ? 5 : visibleCount)
                    Group {
                        if embedded {
                            NavigationLink {ActivityView()} label: {showMoreLabel(remaining)}
                        } else {
                            Button {withAnimation {visibleCount += 20}} label: {showMoreLabel(remaining)}
                        }
                    }.buttonStyle(.plain)
                }
                if loaded && displayedRows.isEmpty {
                    Text(embedded ? "No recent activity in the available history." : "No activity was returned in this explorer's available history. This does not prove the wallet has never been used.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                if !embedded,AddressValidator.valid(wallet.address), !wallet.offlineMode {
                    Link("View address in explorer", destination: ExplorerClient.website.appendingPathComponent("address").appendingPathComponent(wallet.address))
                }
            }
    }
    private func refresh(force:Bool=false) async {
        guard !wallet.locked else{localRows=[];transactions=[];snapshotOwner="";snapshotDate=nil;expandedIDs=[];return}
        let address=wallet.address
        if snapshotOwner != address {
            localRows=[];transactions=[];snapshotDate=nil;loaded=false;snapshotOwner=address;expandedIDs=[]
            if let chain=try? DisplaySnapshotStore.chainID(),
               let saved=try? await DisplaySnapshotStore.shared.load(kind:"history",owner:address,chain:chain) {
                guard !Task.isCancelled,!wallet.locked,wallet.address==address else{return}
                transactions=saved.payload["transactions"] as? [[String:Any]] ?? [];snapshotDate=saved.date;loaded=true
            }
        }
        if let root=wallet.accounts.first(where:{$0.index==0})?.address {
            do {
                let rows=try await LocalPaymentHistory.shared.load(root:root,owner:address)
                guard !Task.isCancelled,!wallet.locked,wallet.address==address else{return}
                localRows=rows
            } catch {self.error=error.localizedDescription}
        }
        guard !wallet.offlineMode,!loading,AddressValidator.valid(address),force || Date().timeIntervalSince(lastExplorerAttempt)>=20 else{return}
        lastExplorerAttempt=Date()
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await ExplorerClient.shared.address(address)
            let activity = result["activity"] as? [String: Any]
            guard !Task.isCancelled, !wallet.locked, !wallet.offlineMode, wallet.address == address else { return }
            guard let rows=activity?["transactions"] as? [[String:Any]] else {throw AppFailure("History response was incomplete. Saved history retained.")}
            transactions=HistoryRows.merge(transactions,rows);loaded=true;snapshotDate=Date()
            if let chain=try? DisplaySnapshotStore.chainID(),let date=snapshotDate {
                try? await DisplaySnapshotStore.shared.save(kind:"history",owner:address,chain:chain,payload:["transactions":transactions],date:date)
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct ActivityTransactionRow:View {
    let transaction:[String:Any]
    let id:String
    let hideAmounts:Bool
    @Binding var isExpanded:Bool
    private var directionIcon:String {
        let title=HistoryRows.title(transaction).lowercased()
        if title.contains("received") {return "arrow.down.left"}
        if title.contains("sent") || title.contains("transfer") {return "arrow.up.right"}
        return "clock.arrow.circlepath"
    }
    private var subtitle:String {
        let date: String
        if let stamp=transaction["timestamp"] as? NSNumber {
            date=Date(timeIntervalSince1970:stamp.doubleValue).formatted(date:.abbreviated,time:.shortened)
        } else {date="Date unavailable"}
        if let (_,address)=HistoryRows.counterparty(transaction) {return date+" · "+SaveableAddress.shortened(address)}
        return date+" · "+String(id.prefix(8))+"…"+String(id.suffix(6))
    }
    var body:some View {
        DisclosureGroup(isExpanded:$isExpanded) {
            ActivityTransactionDetails(transaction:transaction,id:id)
                .padding(.top,10)
        } label: {
            HStack(spacing:12) {
                Image(systemName:directionIcon).font(.system(size:16,weight:.medium))
                    .foregroundStyle(Theme.mint).frame(width:26)
                VStack(alignment:.leading,spacing:3) {
                    Text(HistoryRows.summary(transaction,hideAmounts:hideAmounts)).font(Theme.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(Theme.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength:4)
            }.contentShape(Rectangle())
        }
        .padding(.horizontal,14).padding(.vertical,10)
        .themedCard(14)
        .accessibilityHint(isExpanded ? "Collapse transaction details" : "Expand transaction details")
    }
}

private struct ActivityTransactionDetails:View {
    let transaction:[String:Any]
    let id:String
    @EnvironmentObject private var wallet:WalletState
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            if let status=transaction["local_status"] as? String {Text(status).font(Theme.caption).foregroundStyle(Theme.secondary)}
            else {Text("Explorer-reported activity · verify a receipt before relying on settlement").font(Theme.caption).foregroundStyle(Theme.secondary)}
            if let (prefix,address)=HistoryRows.counterparty(transaction) {SaveableAddress(address:address,prefix:prefix)}
            if let collection=transaction["collection_id"] as? String {LabeledContent("Collection",value:collection).font(Theme.caption)}
            if let serial=transaction["serial"] as? String {LabeledContent("NFT number",value:serial).font(Theme.caption)}
            if let asset=transaction["asset_id"] as? String {LabeledContent("Token ID",value:asset).font(Theme.caption)}
            if let height=transaction["height"] as? NSNumber {LabeledContent("Block",value:height.stringValue).font(Theme.caption)}
            if transaction["local_kind"] as? String == "NOID transfer",
               let amount=Amounts.format(transaction["local_amount"] as? String ?? "") {
                LabeledContent("Payment to recipient",value:wallet.amount(amount+" NOID")).font(Theme.caption)
            }
            if let fee=transaction["fee_micronoid"] as? NSNumber,fee.doubleValue>=0,fee.doubleValue<9007199254740992,let amount=Amounts.format(fee.stringValue) {
                LabeledContent("Network fee",value:wallet.amount(amount+" NOID")).font(Theme.caption)
            }
            if let received=UInt64(transaction["address_received_micronoid"] as? String ?? ""),
               let spent=UInt64(transaction["address_spent_micronoid"] as? String ?? "") {
                if spent > received,let decrease=Amounts.format(String(spent-received)) {
                    LabeledContent("Total decrease · payment and fee",value:wallet.amount(decrease+" NOID")).font(Theme.caption)
                } else if received > spent,let increase=Amounts.format(String(received-spent)) {
                    LabeledContent("Total increase",value:wallet.amount(increase+" NOID")).font(Theme.caption)
                }
                if spent > 0 {
                    DisclosureGroup("How this transaction used your NOID") {
                        VStack(alignment:.leading,spacing:8) {
                            if let amount=Amounts.format(String(spent)) {LabeledContent("Inputs from your address",value:wallet.amount(amount+" NOID"))}
                            if let amount=Amounts.format(String(received)) {LabeledContent("Returned to your address",value:wallet.amount(amount+" NOID"))}
                            Text("A transaction can spend whole inputs and return the unused amount to your address as change. The amount that left your wallet is inputs minus returned change.").foregroundStyle(Theme.secondary)
                        }.font(Theme.caption).padding(.top,6)
                    }.font(Theme.caption)
                }
            }
            if let raw=transaction["verified_balance_micronoid"] as? String,
               let balance=Amounts.format(raw),
               let block=transaction["verified_balance_height"] as? String,
               let height=UInt64(block) {
                LabeledContent("Balance at verification",value:wallet.amount(balance+" NOID")).font(Theme.caption)
                Text("Wallet balance verified at block \(height.formatted())").font(Theme.caption2).foregroundStyle(Theme.secondary)
            }
            Text(id).font(.caption2.monospaced()).textSelection(.enabled)
            TransactionExplorerLink(transactionID:id)
            NavigationLink("Verify payment receipt") {ReceiptVerificationView(transactionID:id)}
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

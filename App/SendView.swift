import SwiftUI
import UIKit

enum SendLayout {
    static let storageKey="send.layout.v1"
    static let standard="standard"
    static let quick="quick"
}
enum SendAssetKind:String,CaseIterable {
    case noid="NOID",token="Tokens",nft="NFTs"
}

/// One journal per master identity, shared by all account indices.
enum PaymentStorage {
    static func directory(root:String) throws -> URL {
        guard AddressValidator.valid(root) else{throw AppFailure("Invalid root wallet identity.")}
        let base=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("Payments",isDirectory:true).appendingPathComponent(root,isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        let directoryValues=try base.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard directoryValues.isDirectory == true,directoryValues.isSymbolicLink != true else {throw AppFailure("Invalid payment storage directory.")}
        // createDirectory's attributes do not upgrade files from older installs.
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:base.path)
        let records=try FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        for file in records {
            let name=file.lastPathComponent
            let journal=name == "payment.lock" || name == "pending.json" || name == "pending.next" || name == "settlement.next" ||
                ((name.hasPrefix("settled-") || name.hasPrefix("expired-") || name.hasPrefix("display-")) && name.hasSuffix(".json"))
            guard journal else {continue}
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile == true,values.isSymbolicLink != true else {throw AppFailure("Invalid payment record path.")}
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:file.path)
        }
        var url=base;var attributes=URLResourceValues();attributes.isExcludedFromBackup=true;try url.setResourceValues(attributes)
        return base
    }
}
struct SendView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @AppStorage(SendLayout.storageKey) private var sendLayout=SendLayout.standard
    var initialRecipient:String=""
    var initialAsset:String="NOID"
    var initialAmount:String=""
    @EnvironmentObject private var wallet:WalletState
    @EnvironmentObject private var node:DeviceNode
    @EnvironmentObject private var live:LiveData
    @EnvironmentObject private var quotes:PriceFeed
    @Environment(\.scenePhase) private var phase
    @Environment(\.walletTabActive) private var tabActive
    @FocusState private var inputFocused: Bool
    @State private var recipient=""
    @State private var amount=""
    @State private var assetSelection="NOID"
    @State private var standardKind:SendAssetKind = .noid
    @State private var sendMax=false
    @State private var tokenNames:[String:String]=[:]
    @State private var nativeReview=false
    @State private var nativeRequest:[String:Any]=[:]
    @State private var confirmSend=false
    @State private var scanAddress=false
    @State private var plan:[String:Any]?
    @State private var review:[String:Any]?
    @State private var pending:[String:Any]?
    /// Every unsettled transaction in this wallet's ledger (build 165).
    @State private var ledgerEntries:[[String:Any]]=[]
    /// A recipient that looks like a known address: blocked until confirmed by retyping.
    @State private var lookalikeAlert:AddressSafety.Lookalike?
    @State private var busy=false
    @State private var error:String?
    @State private var status:String?
    @State private var generation=UUID()
    @State private var visible=false
    @State private var pendingLoaded=false
    @State private var checkingSettlement=false
    @State private var lastSettlementCheck=Date.distantPast
    @State private var addressEntries:[SavedWalletAddress]=[]
    @State private var contactCategories:[SavedContactCategory]=[]
    @AppStorage("send.contactCategoriesVisible") private var showContactCategories=true
    @State private var connectedContacts:[ConnectedContact]=[]
    @State private var recentAddresses:[String]=[]
    @State private var checkingContact:String?
    @AppStorage(ContactFavorites.storageKey) private var contactFavorites="[]"
    @State private var showAddressBook=false
    @State private var saveRecipient=false
    @State private var showVerification=false
    @AppStorage("asset.tokenNames.v1") private var savedTokenNames=Data()
    private let settlementClock=Timer.publish(every:20,on:.main,in:.common).autoconnect()
    private var unresolved:Bool { ["authorized","preparing"].contains(pending?["state"] as? String ?? "") }
    /// A token/NFT operation (or a migrated older payment) reserves everything until it settles.
    private var exclusivePending:Bool { ledgerEntries.contains { ($0["claims"] as? [String:Any])?["exclusive"] as? Bool == true } }
    /// NOID payments may be pending together when they use different coins (checked by the core).
    private var readyForReview:Bool { pendingLoaded && !exclusivePending && ledgerEntries.count < 20 && !checkingSettlement && !busy }
    /// Token and NFT transfers may also be pending together; the planner skips every
    /// slot a pending transaction uses (one token balance can't fund two until settled).
    private var readyForNative:Bool { pendingLoaded && !exclusivePending && ledgerEntries.count < 20 && !checkingSettlement && !busy }
    private var reservedMicronoid:UInt64 { ledgerEntries.reduce(UInt64(0)) { $0 &+ (UInt64($1["local_reserved_total"] as? String ?? "") ?? UInt64($1["local_fee"] as? String ?? "") ?? 0) } }
    @ViewBuilder private var pendingLedgerList:some View {
        if !ledgerEntries.isEmpty {
            Panel {
                Label("Pending transactions · \(ledgerEntries.count)",systemImage:"clock.arrow.circlepath").font(Theme.headline)
                if let raw=node.balanceMicronoid,let verified=UInt64(raw) {
                    let available=verified >= reservedMicronoid ? verified - reservedMicronoid : 0
                    LabeledContent("Verified balance",value:(Amounts.format(String(verified)) ?? "—")+" NOID")
                    LabeledContent("Reserved in pending",value:(Amounts.format(String(reservedMicronoid)) ?? "—")+" NOID")
                    LabeledContent("Available to send",value:(Amounts.format(String(available)) ?? "—")+" NOID").fontWeight(.semibold)
                }
                ForEach(Array(ledgerEntries.enumerated()),id:\.offset) { _,entry in
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:entry["operation_kind"] as? String == "native" ? "square.stack" : "arrow.up.right").foregroundStyle(.orange).frame(width:22)
                        VStack(alignment:.leading,spacing:3) {
                            Text(PendingText.title(entry)).font(Theme.subheadline)
                            Text(PendingText.detail(entry)).font(Theme.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength:4)
                        Text(entry["state"] as? String == "preparing" ? "Signing" : "Pending").font(Theme.caption.weight(.semibold)).foregroundStyle(.orange)
                    }.padding(.vertical,4).accessibilityElement(children:.combine)
                }
                if exclusivePending {
                    Text("A transaction that reserves your whole wallet is settling. New transactions can start once it confirms.").font(Theme.caption).foregroundStyle(Theme.secondary)
                } else {
                    Text("You can keep sending NOID, tokens and NFTs. Each transaction uses different coins and items, so nothing can be spent twice. A token balance or NFT already in a pending transfer stays locked until it settles.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
    @ViewBuilder private var pendingReservationDetails:some View {
        if pending?["state"] as? String == "authorized" {
            Label("Pending · locally reserved",systemImage:"clock.arrow.circlepath")
                .font(Theme.caption).foregroundStyle(.orange)
            if let raw=pending?["local_amount"] as? String,let value=Amounts.format(raw) {
                LabeledContent("Transfer amount",value:value+" NOID")
            }
            if let raw=pending?["local_fee"] as? String,let value=Amounts.format(raw) {
                LabeledContent("Network fee reserved",value:value+" NOID")
            }
            if let raw=pending?["local_reserved_total"] as? String,let value=Amounts.format(raw) {
                LabeledContent("Amount + fee reserved",value:value+" NOID")
            } else if let request=pending?["local_native_request"] as? [String:Any] {
                if let action=request["action"] as? String {
                    Text(action.replacingOccurrences(of:"_",with:" ").capitalized+" pending").font(Theme.caption)
                }
                Text("This asset and its NOID network fee are locally reserved. Verified holdings stay visible; new transfers wait for reconciliation.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            Text("Available for new transfers · 0 until this reservation is resolved")
                .font(Theme.caption).foregroundStyle(.orange)
        }
    }

    private var root:String? {wallet.accounts.first(where:{$0.index==0})?.address}
    private var availableAssets:[NativeItem] {
        let tokens=Dictionary(grouping:live.holdings.filter{$0.type=="token" && $0.text("owner")==wallet.address},by:\.asset)
        let combined=tokens.keys.sorted().compactMap { asset -> NativeItem? in
            guard let entries=tokens[asset],let first=entries.first else{return nil}
            var total:UInt64=0
            for entry in entries {
                guard let value=UInt64(entry.text("units")) else{return nil}
                let (next,overflow)=total.addingReportingOverflow(value)
                guard !overflow else{return nil};total=next
            }
            var fields=first.fields;fields["units"]=String(total)
            return NativeItem(fields:fields)
        }
        let orderedTokens=combined.sorted { left,right in
            let first=tokenValue(left),second=tokenValue(right)
            if let first,let second,first != second {return first>second}
            if first != nil && second == nil {return true}
            if first == nil && second != nil {return false}
            return left.asset<right.asset
        }
        let ownedNFTs=live.holdings.filter{$0.type=="nft" && $0.text("owner")==wallet.address}
            .sorted { $0.collection == $1.collection ? (UInt64($0.text("serial")) ?? 0)<(UInt64($1.text("serial")) ?? 0) : $0.collection<$1.collection }
        return orderedTokens+ownedNFTs
    }
    private var selectedNative:NativeItem? {availableAssets.first { $0.sendSelectionID==assetSelection }}
    private func prepareAssetsIfNeeded() {
        guard visible,assetSelection != "NOID",!nativeHoldingsAtVerifiedParent,node.enabled,!wallet.locked,!wallet.offlineMode,
              plan == nil,review == nil,!node.running,!live.refreshing,AddressValidator.valid(wallet.address) else{return}
        if let hash=node.verifiedHash,node.nativeStateHash==hash {
            live.refresh(owner:wallet.address,offline:false,force:true)
        } else if node.retryAt.map({Date() >= $0}) ?? true {
            node.synchronize(unlocked:true,offline:false,force:true,owner:wallet.address)
        }
    }
    private var nativeHoldingsAtVerifiedParent:Bool {
        guard let hash=node.verifiedHash else{return false}
        return live.holdingsVerifiedLocally && live.holdingsHash==hash && node.nativeStateHash==hash
    }
    /// Specific reason the gateway-free planner cannot run yet. Planning needs
    /// the installed asset State, refreshed holdings and the verified header
    /// to name the same block; this says which of them is behind.
    private var nativeBlockReason:String {
        let suffix=" No transaction was signed."
        guard node.enabled else {return "Enable the device node to send tokens and NFTs from this phone."+suffix}
        guard let chain=node.verifiedHeight,node.verifiedHash != nil else {return "Wait for the device node to verify a chain boundary."+suffix}
        guard let state=node.nativeStateHeight else {return "Asset State is not installed yet (chain verified at block \(chain)). Keep the app open on a stable connection while it downloads."+suffix}
        if node.nativeStateHash != node.verifiedHash {
            return "Asset State is at block \(state); the verified chain is at block \(chain). The phone applies recent verified blocks to catch up; sending opens when both match."+suffix
        }
        return "Refresh holdings at verified block \(chain), then review this transfer."+suffix
    }
    // The chain token denomination is six decimal places. Count only locally
    // verified, unlocked token openings; the planner independently selects
    // and checks the exact inputs again before producing a review.
    private func spendableTokenUnits(_ item:NativeItem)->UInt64? {
        guard nativeHoldingsAtVerifiedParent,let height=node.verifiedHeight else{return nil}
        let (candidate,overflowedHeight)=height.addingReportingOverflow(1)
        guard !overflowedHeight else{return nil}
        var total:UInt64=0
        for entry in live.holdings where entry.type=="token" && entry.asset==item.asset && entry.text("owner")==wallet.address {
            guard let units=UInt64(entry.text("units")),let unlock=UInt64(entry.text("unlock_height")),
                  let reserved=entry.fields["reserved"] as? Bool else{return nil}
            if reserved || unlock>candidate {continue}
            let (next,overflow)=total.addingReportingOverflow(units)
            guard !overflow else{return nil}
            total=next
        }
        return total
    }
    private func transferableTokenUnits(_ item:NativeItem)->UInt64? {
        if GatewayConfiguration.saved == nil {return spendableTokenUnits(item)}
        return UInt64(item.text("units"))
    }
    private var assetTitle:String {
        if assetSelection == "NOID" {return "NOID"}
        guard let item=selectedNative else{return "Choose asset"}
        return item.type == "nft" ? "NFT #"+item.text("serial") : tokenNames[item.asset] ?? "Native token"
    }
    private func tokenValue(_ item:NativeItem)->Decimal? {
        guard let usd=quotes.currentPrice,let units=Decimal(string:item.text("units")),
              let market=live.markets.first(where:{$0.asset==item.asset}),
              let numerator=Decimal(string:market.text("price_numerator")),
              let denominator=Decimal(string:market.text("price_denominator")),denominator>0 else{return nil}
        return units / 1_000_000 * numerator / denominator * usd
    }
    private func usdForAmount(_ raw:String)->String? {
        guard let display=Amounts.format(raw) else{return nil}
        return quotes.usd(display)
    }
    private func tokenLabel(_ item:NativeItem)->String {
        let name=tokenNames[item.asset] ?? (String(item.asset.prefix(12))+"…")
        let quantity=wallet.amount(Amounts.format(item.text("units")) ?? "—")
        let usd=tokenValue(item).flatMap {PriceFeed.currency($0)}.map {" · \($0)"} ?? ""
        return "\(name) · \(quantity)\(usd)"
    }
    private var noidAvailable:String? {node.balance(for:wallet.address)}
    private var noidAmountValid:Bool {sendMax ? node.enabled : (Amounts.parse(amount).flatMap {UInt64($0)} ?? 0)>0}
    private var tokenAmountValid:Bool {
        guard let item=selectedNative,let requested=Amounts.parse(amount).flatMap({UInt64($0)}),requested>0,
              let available=transferableTokenUnits(item) else{return false}
        return requested<=available
    }
    var body: some View {
        stateObservedForm
        .safeAreaInset(edge:.top) { UnavailableNotice(needs:[.backup,.deviceNode]).padding(.horizontal,16).padding(.top,4) }
        .sheet(item:$lookalikeAlert) { LookalikeConfirmView(alert:$0) }
        .onChange(of:phase){_,state in if state == .background{generation=UUID();plan=nil;review=nil;busy=false;status="Review again after returning to the app."} else if state == .active && tabActive {Task {await loadPending()}}}
        .onDisappear { handleDisappearance() }
        .task(id:live.holdings.map(\.id).joined()) {
            await loadTokenNames()
            if assetSelection == "NOID",initialAsset != "NOID",
               let item=availableAssets.first(where:{$0.id==initialAsset || $0.sendSelectionID==initialAsset}) {
                assetSelection=item.sendSelectionID
            }
            if let item=selectedNative {standardKind=item.type == "nft" ? .nft : .token}
            if standardKind != .noid,selectedNative == nil,
               let item=availableAssets.first(where:{$0.type == (standardKind == .nft ? "nft" : "token")}) {
                assetSelection=item.sendSelectionID
            }
        }
    }

    private var stateObservedForm: some View {
        presentedForm
        .onChange(of:tabActive) { _, active in
            node.transactionFlowActive=active
            if !active {generation=UUID();plan=nil;review=nil;busy=false;inputFocused=false}
            else {Task {await loadPending()}}
        }
        .onChange(of:nativeReview){_,presented in if !presented && visible && tabActive {node.transactionFlowActive=true}}
        .onChange(of:sendMax){_,_ in plan=nil;review=nil}
        .onChange(of:assetSelection){_,selection in
            if selection != "NOID",let item=selectedNative,item.id == initialAsset,Amounts.parse(initialAmount) != nil {
                amount=initialAmount
            } else {amount=""}
            sendMax=false;plan=nil;review=nil
            if selection == "NOID" {standardKind = .noid}
            else if let item=selectedNative {standardKind = item.type == "nft" ? .nft : .token}
        }
        .onChange(of:recipient){_,_ in plan=nil;review=nil}
        .onChange(of:amount){_,_ in plan=nil;review=nil}
        .onChange(of:wallet.address){_,_ in clear();Task{await loadPending();await loadAddresses()}}
        .onChange(of:wallet.locked){_,locked in if locked{clear()}}
        .onChange(of:wallet.offlineMode){_,_ in clear();Task{await loadPending()}}
    }

    private var presentedForm: some View {
        ScrollViewReader { scroll in
            scrollingForm(scroll)
        }
        .onAppear {visible=true;node.transactionFlowActive=tabActive}
        // Token/NFT sends need State, holdings and the verified header at the same block. Bring them
        // up to date as soon as an asset is chosen instead of waiting for the next periodic refresh.
        .task(id:"\(assetSelection)|\(node.verifiedHash ?? "")|\(node.nativeStateHash ?? "")|\(live.holdingsHash ?? "")|\(node.running)|\(live.refreshing)") {prepareAssetsIfNeeded()}
        .onReceive(settlementClock){_ in if visible && tabActive && phase == .active {Task{await checkPendingSettlement()}}}
        .onReceive(NotificationCenter.default.publisher(for:PaymentReconciliation.changed).receive(on:RunLoop.main)){_ in Task{await loadPending()}}
        .onReceive(NotificationCenter.default.publisher(for:WalletAddressBook.changed).receive(on:RunLoop.main)){_ in Task{await loadAddresses()}}
        .onReceive(NotificationCenter.default.publisher(for:ContactBook.changed).receive(on:RunLoop.main)){_ in Task{await loadAddresses()}}
        .onReceive(NotificationCenter.default.publisher(for:LocalPaymentHistory.changed).receive(on:RunLoop.main)){_ in Task{await loadAddresses()}}
        .sheet(isPresented:$showAddressBook){NavigationStack{WalletAddressBookView(select:{address in
            plan=nil;review=nil;showAddressBook=false;selectQuickRecipient(address)
        }).toolbar{ToolbarItem(placement:.cancellationAction){Button("Done"){showAddressBook=false}}}}}
        .sheet(isPresented:$saveRecipient){SaveWalletAddressView(address:recipient)}
        .sheet(isPresented:$showVerification){NavigationStack {
            if let id=pending?["txid"] as? String {ReceiptVerificationView(transactionID:id)}
            else {ReceiptLookupView(scope:.all)}
        }}
        .task{
            if recipient.isEmpty,AddressValidator.valid(initialRecipient){recipient=initialRecipient}
            if amount.isEmpty,Amounts.parse(initialAmount) != nil {amount=initialAmount}
            if assetSelection == "NOID",initialAsset != "NOID",let item=availableAssets.first(where:{$0.id==initialAsset || $0.sendSelectionID==initialAsset}){assetSelection=item.sendSelectionID}
            node.transactionFlowActive=tabActive;await loadPending();await loadAddresses();await checkPendingSettlement()
            if availableAssets.isEmpty && !wallet.offlineMode && !wallet.address.isEmpty {
                await live.refreshAndWait(owner:wallet.address,offline:false)
            }
        }
        .sheet(isPresented:$scanAddress){AddressScanner{recipient=$0;plan=nil;review=nil}}
        .sheet(isPresented:$nativeReview){OperationReview(request:nativeRequest)}
        .confirmationDialog("Confirm this payment",isPresented:$confirmSend,titleVisibility:.visible) {
            Button(wallet.offlineMode ? "Authenticate and save" : "Authenticate and send") {authorize()}
            Button("Cancel",role:.cancel) {}
        } message: {
            Text(paymentConfirmationMessage)
        }
    }

    private var paymentConfirmationMessage: String {
        let rawAmount: String = review?["amount_micronoid"] as? String ?? ""
        let displayAmount: String = Amounts.format(rawAmount) ?? "—"
        let destination: String = review?["to"] as? String ?? ""
        let fee: String = Amounts.format(review?["fee_micronoid"] as? String ?? "") ?? "—"
        let total: String = Amounts.format(review?["total_micronoid"] as? String ?? "") ?? "—"
        return "Send \(displayAmount) NOID to \(destination) with a \(fee) NOID network fee (\(total) NOID in total). Submitted payments cannot be undone."
    }

    private func scrollingForm(_ scroll: ScrollViewProxy) -> some View {
        paymentForm
        .navigationTitle("Send").navigationBarTitleDisplayMode(.inline).disabled(wallet.locked)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement:.topBarTrailing) {
                Menu {
                    Picker("Send layout",selection:$sendLayout) {
                        Text("Standard Send").tag(SendLayout.standard)
                        Text("Quick Send").tag(SendLayout.quick)
                    }
                    Button("Verify a receipt",systemImage:"checkmark.shield") {inputFocused=false;showVerification=true}
                    Button("Address book",systemImage:"person.crop.circle") {inputFocused=false;showAddressBook=true}
                } label: {ThemedLabel("More", systemImage: "ellipsis.circle")}
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { inputFocused=false } }
        }
        .onChange(of:busy) { _, value in if value { withAnimation { scroll.scrollTo("payment-progress",anchor:.center) } } }
        .onChange(of:error) { _, value in if value != nil { withAnimation { scroll.scrollTo("payment-error",anchor:.center) } } }
        .onChange(of:review != nil) { _, value in if value { withAnimation { scroll.scrollTo("payment-review",anchor:.top) } } }
    }

    private var paymentForm: some View {
        Group {
        if sendLayout == SendLayout.quick { quickPaymentForm }
        else {standardPaymentForm}
        }
    }
    private var standardPaymentForm:some View {
        Form {
            recoverySection
            if review == nil {
                assetSection.disabled(busy)
                amountSection.disabled(busy)
                recipientSection.disabled(busy)
                standardSummary
                pendingSummary
                standardReviewAction
            } else {
                reviewSection.disabled(busy)
                Button("Edit payment") {plan=nil;review=nil}.disabled(busy)
            }
            if busy {ProgressView("Preparing payment… Keep the app open.").id("payment-progress")}
            if let status {
                Section("Payment status") {
                    Label(status,systemImage:"info.circle").font(Theme.subheadline)
                    if let id=pending?["txid"] as? String {
                        NavigationLink("View receipt and verify confirmation") {ReceiptVerificationView(transactionID:id)}
                            .buttonStyle(ThemedButtonStyle())
                    }
                }.themedRow()
            }
            if let error {Text(error).foregroundStyle(.orange).id("payment-error")}

        }.scrollContentBackground(.hidden).background(AmbientBackground())
    }

    private var quickPaymentForm:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text("Quick Send").font(Theme.editorial(32))
                        Text("Choose a person, asset and amount.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Image("Brand").resizable().scaledToFit().frame(width:38,height:38)
                }
                if review == nil {
                    quickEntryActions
                    quickPeople
                    quickSelectedRecipient
                    quickAssetAmount
                    quickReviewAction
                } else {quickReviewDetails}
                if unresolved || !pendingLoaded || pending?["state"] as? String == "expired" {quickPendingPayment}
                pendingLedgerList
                if busy {ProgressView("Preparing payment…").id("payment-progress")}
                if let status {Panel {Text(status).font(Theme.caption);if let id=pending?["txid"] as? String {NavigationLink("View receipt") {ReceiptVerificationView(transactionID:id)}}}}
                if let error {Text(error).foregroundStyle(.orange).font(Theme.caption).id("payment-error")}
            }.padding(16).frame(maxWidth:640).frame(maxWidth:.infinity)
        }.background(AmbientBackground()).foregroundStyle(Theme.text)
            .scrollDismissesKeyboard(.interactively)
    }
    private var quickEntryActions:some View {
        HStack(spacing:10) {
            Button {inputFocused=false;scanAddress=true} label: {
                ThemedLabel("Scan QR", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth:.infinity,minHeight:54)
            }.buttonStyle(ThemedButtonStyle(prominent: true)).tint(Theme.mint)
            PasteButton(payloadType:String.self) {values in
                inputFocused=false
                if let pasted=values.first,let address=ScannedAddress.parse(pasted) {recipient=address;error=nil}
                else {error="Clipboard does not contain a valid Parano1d address."}
            }.labelStyle(.titleAndIcon).frame(maxWidth:.infinity,minHeight:54)
                .themedCard(14)
                .overlay(RoundedRectangle(cornerRadius:14).stroke(Theme.line))
                .accessibilityLabel("Paste recipient address")
        }.font(Theme.control)
    }
    private var quickPeople:some View {
        VStack(alignment:.leading,spacing:12) {
            if !recentAddresses.isEmpty {
                Text("Recent recipients").font(Theme.headline)
                quickPeopleStrip(recentAddresses)
            }
            HStack {Text("Connected contacts").font(Theme.headline);Spacer();Button("All contacts") {showAddressBook=true}.font(Theme.caption)}
            if connectedContacts.isEmpty {Text("Your connected chat contacts appear here.").font(Theme.caption).foregroundStyle(Theme.secondary)}
            else {
                let favorites=ContactFavorites.read(contactFavorites)
                quickPeopleStrip(connectedContacts.filter { contact in
                    !showContactCategories || !addressEntries.contains(where: { entry in
                        entry.address == contact.address && contactCategories.contains(where:{$0.name==entry.category})
                    })
                }.sorted {
                    if favorites.contains($0.id) != favorites.contains($1.id) {return favorites.contains($0.id)}
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }.map(\.address))
            }
            if showContactCategories {
                ForEach(contactCategories) {category in
                    let addresses=addressEntries.filter{$0.category==category.name}.map(\.address)
                    if !addresses.isEmpty {
                        HStack {ContactIconView(name:category.name,icon:category.icon,size:27);Text(category.name).font(Theme.headline)}
                        quickPeopleStrip(addresses)
                    }
                }
            }
            if !addressEntries.isEmpty {
                HStack {
                    Text("Saved addresses").font(Theme.headline)
                    Spacer()
                    Button(showContactCategories ? "Categories on" : "Categories off") {showContactCategories.toggle()}.font(Theme.caption)
                    Button("Address book") {showAddressBook=true}.font(Theme.caption)
                }
                quickPeopleStrip(addressEntries.filter { entry in
                    !showContactCategories || entry.category.isEmpty || !contactCategories.contains(where:{$0.name==entry.category})
                }.map(\.address))
            }
        }
    }
    private func quickPeopleStrip(_ addresses:[String])->some View {
        ScrollView(.horizontal,showsIndicators:false) {
            LazyHStack(spacing:10) {
                ForEach(QuickRecipientOrder.unique(addresses),id:\.self) {address in
                    quickPersonButton(address)
                }
            }.padding(.vertical,2)
        }
    }
    private func quickPersonButton(_ address:String)->some View {
        Button {selectQuickRecipient(address)} label: {
            VStack(spacing:5) {
                quickAvatar(address,size:46)
                Text(quickName(address)).font(Theme.caption).lineLimit(1).frame(width:90)
            }.frame(width:100).frame(minHeight:80)
                .background(recipient == address ? Theme.mint.opacity(0.15) : Theme.panel,in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).stroke(recipient == address ? Theme.mint : Theme.line))
        }.buttonStyle(.plain).accessibilityLabel("Send to \(quickName(address)), \(address)")
    }
    @ViewBuilder private func quickAvatar(_ address:String,size:CGFloat)->some View {
        if let contact=connectedContacts.first(where:{$0.address==address}) {
            PeerAvatar(identity:contact.id,name:contact.name,size:size,
                       fallbackIcon:addressEntries.first(where:{$0.address==address})?.icon ?? "initials")
        } else if let saved=addressEntries.first(where:{$0.address==address}) {
            ContactIconView(name:saved.name,icon:saved.icon,size:size)
        } else {ChatAvatar(name:quickName(address),size:size)}
    }
    private func quickName(_ address:String)->String {
        if let contact=connectedContacts.first(where:{$0.address==address}) {return contact.name}
        if let saved=addressEntries.first(where:{$0.address==address}) {return saved.name}
        return SaveableAddress.shortened(address)
    }
    private func selectQuickRecipient(_ address:String) {
        guard AddressValidator.valid(address),address != wallet.address,!wallet.locked else{return}
        guard let contact=connectedContacts.first(where:{$0.address==address}) else {recipient=address;error=nil;return}
        checkingContact=address
        Task { @MainActor in
            defer {if checkingContact==address {checkingContact=nil}}
            do {
                let checked=try await ConnectedContact.inspect(contact.invitation)
                guard !wallet.locked,checkingContact==address,checked.id==contact.id,checked.address==address,checked.boxKey==contact.boxKey else {
                    throw AppFailure("This contact no longer matches its signed invitation. Reconnect it before paying.")
                }
                recipient=address;error=nil
            }catch {if !wallet.locked {self.error=error.localizedDescription}}
        }
    }
    private var quickSelectedRecipient:some View {
        Panel {
            HStack {
                Text("To").font(Theme.headline)
                Spacer()
                if AddressValidator.valid(recipient) {Button("Save") {saveRecipient=true}.font(Theme.caption)}
            }
            if AddressValidator.valid(recipient) {
                HStack(spacing:12) {
                    quickAvatar(recipient,size:42)
                    VStack(alignment:.leading,spacing:3) {
                        Text(quickName(recipient)).font(Theme.headline)
                        HighlightedAddress(address:recipient)
                    }
                    Spacer();Image(systemName:"checkmark.circle.fill").foregroundStyle(Theme.mint)
                }
            }
            if checkingContact != nil {ProgressView("Checking signed contact…")}
            TextField("Enter a receiving address",text:$recipient).font(.caption.monospaced())
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($inputFocused)
                .accessibilityLabel("Full recipient address")
            if !recipient.isEmpty && !AddressValidator.valid(recipient) {Text("Enter a valid o1… address.").font(Theme.caption).foregroundStyle(.orange)}
        }
    }
    private var quickAssetAmount:some View {
        Panel {
            Picker("Asset type",selection:Binding(get:{standardKind},set:{chooseStandardKind($0)})) {
                ForEach(SendAssetKind.allCases,id:\.self) {kind in Text(kind.rawValue).tag(kind)}
            }.pickerStyle(.segmented)
            HStack(alignment:.center,spacing:12) {
                assetChoice(size:48)
                Spacer(minLength:4)
                if standardKind == .nft {
                    Text(selectedNative.map {"#"+$0.text("serial")} ?? "Choose NFT").font(Theme.subheadline)
                } else {
                    VStack(alignment:.trailing,spacing:5) {
                        HStack(spacing:8) {
                            if sendMax {Text("Max").font(Theme.editorial(30))}
                            else {
                                TextField("0",text:$amount).font(Theme.editorial(34)).keyboardType(.decimalPad)
                                    .focused($inputFocused).multilineTextAlignment(.trailing).frame(maxWidth:135)
                                    .accessibilityLabel("Amount to send")
                            }
                            Button("Max") {setMaximum()}
                                .disabled(standardKind == .noid ? !node.enabled : selectedNative == nil)
                                .font(Theme.control).buttonStyle(ThemedButtonStyle())
                        }
                        Text(quickBalance).font(Theme.caption2).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                }
            }
            if standardKind != .nft {
                HStack(spacing:8) {
                    ForEach([25,50,75],id:\.self) {percent in
                        Button("\(percent)%") {
                            if standardKind == .noid {setPercentage(percent)}
                            else if let item=selectedNative {setTokenPercentage(percent,item)}
                        }.disabled(standardKind == .noid ? noidAvailable == nil : selectedNative == nil)
                    }
                    if sendMax {Button("Edit amount") {sendMax=false;amount=""}}
                }.buttonStyle(ThemedButtonStyle()).font(Theme.control)
                if !sendMax,standardKind == .noid,let raw=Amounts.parse(amount),let usd=usdForAmount(raw) {
                    HStack {Text("Estimated value");Spacer();Text(wallet.amount(usd))}.font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            } else {Text("One NFT selected").font(Theme.caption).foregroundStyle(Theme.secondary)}
        }
    }
    @ViewBuilder private func assetChoice(size:CGFloat)->some View {
        if standardKind == .noid {
            HStack(spacing:8) {AssetSelectionIcon(size:size);Text("NOID").font(Theme.headline)}
                .accessibilityElement(children:.combine)
        } else {
            NavigationLink {
                SendAssetPicker(items:availableAssets,names:tokenNames,noidBalance:noidAvailable,selection:$assetSelection,kind:standardKind)
            } label: {
                HStack(spacing:8) {
                    if let item=selectedNative {AssetSelectionIcon(item:item,size:size)}
                    else {Image(systemName:standardKind == .nft ? "square.3.layers.3d" : "circle.hexagongrid").frame(width:size,height:size)}
                    Text(selectedNative == nil ? (standardKind == .nft ? "Choose NFT" : "Choose token") : assetTitle)
                        .font(Theme.headline).lineLimit(1)
                    Image(systemName:"chevron.down").font(Theme.caption)
                }
            }.buttonStyle(.plain).accessibilityLabel("Choose \(standardKind == .nft ? "NFT" : "token")")
        }
    }
    private func setMaximum() {
        if standardKind == .noid {sendMax=true;amount=""}
        else if let item=selectedNative {sendMax=false;amount=transferableTokenUnits(item).flatMap {Amounts.format(String($0))} ?? ""}
    }
    private var quickBalance:String {
        if assetSelection == "NOID" {
            if unresolved {return noidAvailable.map {wallet.amount($0+" NOID verified · pending locally reserved · 0 available for new transfers")} ?? "Pending transfer locally reserved · balance awaiting verification"}
            return noidAvailable.map {wallet.amount($0+" NOID available")} ?? "Balance awaiting verification"
        }
        guard let item=selectedNative else{return "Refresh holdings to choose this asset"}
        if live.savedSnapshotDate != nil {return "Last saved holding · refresh before sending"}
        if item.type == "nft" {return "NFT #"+item.text("serial")+(unresolved ? " · wallet has a pending reservation" : "")}
        if GatewayConfiguration.saved == nil {
            guard let spendable=spendableTokenUnits(item),let display=Amounts.format(String(spendable)) else {
                return "Sync verified State and refresh holdings before sending"
            }
            return wallet.amount(display+(unresolved ? " verified spendable · wallet reservation active · 0 available for new transfers" : " available to send"))
        }
        return wallet.amount((Amounts.format(item.text("units")) ?? "—")+(unresolved ? " verified · wallet reservation active · 0 available for new transfers" : " available"))
    }
    private var quickReviewAction:some View {
        VStack(spacing:10) {
            if wallet.localWallet?.recoveryVerified != true {Text("Confirm your wallet backup before sending.").font(Theme.caption).foregroundStyle(.orange)}
            Button {
                inputFocused=false
                if assetSelection == "NOID" {prepare()}
                else if let item=selectedNative {reviewNative(item)}
            } label: {ThemedLabel("Review transfer", systemImage: "arrow.right")}
                .buttonStyle(MintButtonStyle())
                .disabled(!readyForReview || checkingContact != nil || !AddressValidator.valid(recipient) || recipient == wallet.address || wallet.localWallet?.recoveryVerified != true || (assetSelection == "NOID" ? !noidAmountValid : live.savedSnapshotDate != nil || selectedNative == nil || (selectedNative?.type == "token" && !tokenAmountValid)))
        }
    }
    private var quickReviewDetails:some View {
        Panel {
            Text("Review exact payment").font(Theme.headline).id("payment-review")
            Text(review?["to"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
            LabeledContent("Amount",value:(Amounts.format(review?["amount_micronoid"] as? String ?? "") ?? "—")+" NOID")
            LabeledContent("Network fee",value:(Amounts.format(review?["fee_micronoid"] as? String ?? "") ?? "—")+" NOID")
            LabeledContent("Total",value:(Amounts.format(review?["total_micronoid"] as? String ?? "") ?? "—")+" NOID")
            if let raw=review?["amount_micronoid"] as? String,let usd=usdForAmount(raw) {LabeledContent("Estimated value",value:wallet.amount(usd))}
            if let expiry=plan?["valid_through_height"] as? NSNumber {LabeledContent("Last eligible block",value:expiry.stringValue)}
            if plan?["send_max"] as? Bool == true {Text("Max uses discovered, unreserved inputs and deducts the fee. Discovery may miss other wallet outputs.").font(Theme.caption).foregroundStyle(Theme.secondary)}
            if plan?["using_saved_state"] as? Bool == true {Text("Offline review uses previously verified state. Funds may have changed and the epoch may have expired.").font(Theme.caption).foregroundStyle(.orange)}
            Button(wallet.offlineMode ? "Confirm saved authorization" : "Confirm payment") {confirmSend=true}
                .buttonStyle(MintButtonStyle()).disabled(busy)
            Button("Edit transfer") {plan=nil;review=nil}.disabled(busy)
        }
    }
    private var quickPendingPayment:some View {
        Panel {
            if !pendingLoaded {ProgressView("Checking previous payment…")}
            else if unresolved {
                Label("Previous payment pending",systemImage:"clock.arrow.circlepath").font(Theme.subheadline)
                Text("Confirmation is checked automatically. Review unlocks when it is safely resolved.").font(Theme.caption).foregroundStyle(Theme.secondary)
                pendingReservationDetails
                DisclosureGroup("Payment recovery") {
                    if let id=pending?["txid"] as? String {NavigationLink("View verification") {ReceiptVerificationView(transactionID:id)}}
                    Button("Check now") {reconcile()}.disabled(busy || checkingSettlement || wallet.offlineMode)
                    if pending?["state"] as? String == "authorized" {
                        Button("Retry identical signed payment") {retry()}.disabled(busy || checkingSettlement || wallet.offlineMode)
                        Button("Check verified expiry") {checkExpiry()}.disabled(busy || checkingSettlement)
                    } else {Button("Cancel unsigned preparation",role:.destructive) {cancelPreparation()}.disabled(busy)}
                }
            } else if pending?["state"] as? String == "expired" {
                Text("Previous authorization expired; earlier settlement remains unknown. Check its receipt before paying the same recipient again.")
                    .font(Theme.caption).foregroundStyle(.orange)
                if let id=pending?["txid"] as? String {NavigationLink("Previous receipt") {ReceiptVerificationView(transactionID:id)}}
            }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
            if wallet.localWallet?.recoveryVerified != true {
                Section("Sending unavailable") {
                    Text(wallet.localWallet == nil ? "This is a watch-only wallet. Import its master key to send." : "Confirm your wallet backup before approving a payment.")
                    NavigationLink("Wallet and backup") { WalletSetupView() }
                }.themedRow()
            }
    }

    @ViewBuilder
    private var assetSection: some View {
        Section {
            Picker("Asset type",selection:Binding(get:{standardKind},set:{chooseStandardKind($0)})) {
                ForEach(SendAssetKind.allCases,id:\.self) {kind in Text(kind.rawValue).tag(kind)}
            }.pickerStyle(.segmented)
        }.themedRow(standard: Theme.panel)
    }

    private func chooseStandardKind(_ kind:SendAssetKind) {
        standardKind=kind
        if kind == .noid {assetSelection="NOID";return}
        let type=kind == .token ? "token" : "nft"
        if let item=availableAssets.first(where:{$0.type == type}) {assetSelection=item.sendSelectionID}
        else {assetSelection=type+":unselected";amount="";sendMax=false}
    }

    @ViewBuilder
    private var recipientSection: some View {
        Section("Recipient") {
            HStack(spacing:8) {
                TextField("Paste or enter o1… address",text:$recipient,axis:.vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($inputFocused)
                    .font(.footnote.monospaced())
                Button {inputFocused=false;showAddressBook=true} label:{Image(systemName:"person.crop.circle")}
                    .frame(width:40,height:44)
                    .accessibilityLabel("Choose connected or saved contact")
                Button {inputFocused=false;scanAddress=true} label:{Image(systemName:"qrcode.viewfinder")}
                    .frame(width:40,height:44)
                    .accessibilityLabel("Scan receiving address")
                PasteButton(payloadType:String.self) {values in
                    inputFocused=false
                    if let pasted=values.first,let address=ScannedAddress.parse(pasted) {recipient=address;error=nil}
                    else {error="Clipboard does not contain a valid Parano1d address."}
                }.labelStyle(.iconOnly).frame(width:40,height:44).accessibilityLabel("Paste receiving address")
            }.buttonStyle(.borderless).font(.system(size:19)).frame(minHeight:44)
            if AddressValidator.valid(recipient) {HighlightedAddress(address:recipient)}
            if AddressValidator.valid(recipient) {
                HStack {
                    Text(quickName(recipient)).font(Theme.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Save address") {inputFocused=false;saveRecipient=true}.font(Theme.caption)
                }
            }
            if !recipient.isEmpty && !AddressValidator.valid(recipient) {
                Text("Enter or scan a valid o1… address.").font(Theme.footnote).foregroundStyle(.orange)
            }
        }.themedRow(standard: Theme.panel)
    }

    @ViewBuilder
    private var amountSection: some View {
        Section("Amount") {
            HStack(alignment:.center,spacing:12) {
                assetChoice(size:48)
                Spacer(minLength:4)
                if standardKind == .nft {
                    Text(selectedNative.map {"#"+$0.text("serial")} ?? "Select NFT").font(Theme.subheadline).lineLimit(1)
                } else {
                    VStack(alignment:.trailing,spacing:5) {
                        HStack(spacing:8) {
                            if sendMax {Text("Max").font(Theme.editorial(30))}
                            else {
                                TextField("0",text:$amount).font(Theme.editorial(32)).keyboardType(.decimalPad)
                                    .focused($inputFocused).multilineTextAlignment(.trailing).frame(maxWidth:135)
                                    .accessibilityLabel("Amount to send")
                            }
                            Button("Max") {setMaximum()}
                                .disabled(standardKind == .noid ? !node.enabled : selectedNative == nil)
                                .font(Theme.control).buttonStyle(ThemedButtonStyle())
                        }
                        Text(quickBalance).font(Theme.caption2).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                }
            }
            if standardKind != .nft {
                HStack(spacing:8) {
                    ForEach([25,50,75],id:\.self) {percent in
                        Button("\(percent)%") {
                            if standardKind == .noid {setPercentage(percent)}
                            else if let item=selectedNative {setTokenPercentage(percent,item)}
                        }.disabled(standardKind == .noid ? noidAvailable == nil : selectedNative == nil)
                    }
                    if sendMax {Button("Edit amount") {sendMax=false;amount=""}}
                }.font(Theme.control).buttonStyle(ThemedButtonStyle())
            }
            if let item=selectedNative,item.type == "nft" {CollectionNameLabel(id:item.collection).font(Theme.caption)}
            if assetSelection != "NOID" && !nativeHoldingsAtVerifiedParent {
                // Shown while the phone brings its token and NFT data up to the verified block.
                HStack(alignment:.top,spacing:10) {
                    if node.running || live.refreshing {ProgressView().tint(Theme.mint)}
                    else {Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange)}
                    VStack(alignment:.leading,spacing:4) {
                        Text(node.running || live.refreshing ? "Getting tokens and NFTs ready…" : "Tokens and NFTs aren't ready to send yet").font(Theme.subheadline.weight(.medium))
                        Text(nativeBlockReason.replacingOccurrences(of:" No transaction was signed.",with:"")).font(Theme.caption).foregroundStyle(Theme.secondary)
                        NavigationLink("Network check") {NetworkStatusView()}.font(Theme.caption).foregroundStyle(Theme.mint)
                    }
                }
            }
        }.themedRow(standard: Theme.panel)
    }

    private var standardSummary:some View {
        Section("Transaction summary") {
            LabeledContent("Amount",value:standardAmountDescription)
            LabeledContent("Network fee",value:"Exact fee shown before you approve")
            if standardKind == .noid {LabeledContent("Total",value:"Calculated at review")}
        }.font(Theme.subheadline).themedRow(standard: Theme.panel)
    }
    private var standardAmountDescription:String {
        if standardKind == .nft {return selectedNative.map {"NFT #"+$0.text("serial")} ?? "Choose NFT"}
        if sendMax {return "Max NOID · fee deducted at review"}
        return amount.isEmpty ? "Enter amount" : amount+(standardKind == .noid ? " NOID" : " tokens")
    }
    private var standardReviewAction:some View {
        Button {
            inputFocused=false
            if standardKind == .noid {prepare()}
            else if let item=selectedNative {reviewNative(item)}
        } label:{ThemedLabel("Review transfer", systemImage: "arrow.right")}
            .buttonStyle(MintButtonStyle())
            .disabled(!(standardKind == .noid ? readyForReview : readyForNative) || !AddressValidator.valid(recipient) || recipient == wallet.address || wallet.localWallet?.recoveryVerified != true || (standardKind == .noid ? !noidAmountValid : live.savedSnapshotDate != nil || selectedNative == nil || (standardKind == .token && !tokenAmountValid)))
    }

    @ViewBuilder
    private var reviewSection: some View {
                if let review {
                    Section("Confirm exact terms") {
                        Text(review["to"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        LabeledContent("Amount",value:(Amounts.format(review["amount_micronoid"] as? String ?? "") ?? "—")+" NOID")
                        if let raw=review["amount_micronoid"] as? String,let usd=usdForAmount(raw){LabeledContent("Estimated value",value:wallet.amount(usd))}
                        LabeledContent("Network fee",value:(Amounts.format(review["fee_micronoid"] as? String ?? "") ?? "—")+" NOID")
                        if let raw=review["fee_micronoid"] as? String,let usd=usdForAmount(raw){LabeledContent("Fee value",value:wallet.amount(usd))}
                        if plan?["busy_fee"] as? Bool == true {
                            Label("The network is busy, so this fee is above the usual minimum. Peers would reject a lower one.",systemImage:"gauge.with.dots.needle.67percent").font(Theme.caption).foregroundStyle(.orange)
                        }
                        LabeledContent("Total",value:(Amounts.format(review["total_micronoid"] as? String ?? "") ?? "—")+" NOID")
                        Text("This fee is read from the exact transaction you sign. It goes to the network, not to Parano1d or KoAjent.").font(Theme.caption).foregroundStyle(Theme.secondary)
                        if plan?["send_max"] as? Bool == true {Text("Send Max uses every discovered, unreserved verified input and deducts the fee above. No change is returned. Discovery may miss other wallet outputs.").font(Theme.footnote)}
                        if let expiry=plan?["valid_through_height"] as? NSNumber {
                            LabeledContent("Last eligible block",value:expiry.stringValue)
                        }
                        if plan?["using_saved_state"] as? Bool == true {
                            Text("Offline review uses previously verified state. Funds or output slots may have changed since then, and the epoch may have expired. This is an authorization, not guaranteed payment.").font(Theme.footnote)
                        }
                        Button(wallet.offlineMode ? "Confirm saved authorization" : "Confirm payment") {inputFocused=false;confirmSend=true}.buttonStyle(MintButtonStyle())
                    }.themedRow().id("payment-review")
                }
    }

    @ViewBuilder private var pendingSummary: some View {
        if !pendingLoaded {Text("Checking saved payment…").font(Theme.caption)}
        if unresolved {
            Section {
                Label(checkingSettlement ? "Checking previous payment" : "Previous payment pending",systemImage:"clock.arrow.circlepath").font(Theme.subheadline)
                Text("Confirmation is checked automatically. This wallet keeps the signed payment reserved until verified settlement or expiry; another payment can be reviewed afterward.").font(Theme.caption).foregroundStyle(Theme.secondary)
                pendingReservationDetails
                DisclosureGroup("Recovery options") {
                    if let id=pending?["txid"] as? String {NavigationLink("View verification") {ReceiptVerificationView(transactionID:id)}}
                    Button("Check now") {reconcile()}.disabled(busy || checkingSettlement || wallet.offlineMode || pending?["state"] as? String != "authorized")
                    if pending?["state"] as? String == "authorized" {
                        Button("Retry identical signed payment") {retry()}.disabled(wallet.offlineMode || busy || checkingSettlement)
                        Button("Check verified expiry") {checkExpiry()}.disabled(busy || checkingSettlement)
                        Text("A timeout cannot cancel a signed payment. The app checks for a verified receipt and, after the signed epoch ends, a verified expiry. Retry reuses the same bytes.").font(Theme.caption)
                    } else {Button("Cancel unsigned preparation",role:.destructive){cancelPreparation()}.disabled(busy)}
                }
            }.themedRow()
        } else if pending?["state"] as? String == "expired" {
            Text("Previous authorization expired; earlier settlement remains unknown. Check its receipt before paying the same recipient again.").font(Theme.caption).foregroundStyle(.orange)
            if let id=pending?["txid"] as? String {NavigationLink("Previous receipt"){ReceiptVerificationView(transactionID:id)}}
        }
    }

    private func handleDisappearance() {
        // A modal may trigger disappearance; retain its recipient/form state.
        guard !scanAddress, !nativeReview, !showAddressBook, !saveRecipient else { return }
        visible = false
        generation = UUID()
        busy = false
        node.transactionFlowActive = false
        plan = nil
        review = nil
    }

    @MainActor private func loadTokenNames() async {
        let saved=(try? JSONDecoder().decode([String:String].self,from:savedTokenNames)) ?? [:]
        for item in availableAssets where item.type == "token" {
            if let name=saved[item.text("metadata_hash")] {tokenNames[item.asset]=name}
        }
        guard !wallet.offlineMode,(UserDefaults.standard.object(forKey:"externalMedia") as? Bool ?? true) else{return}
        for item in availableAssets where item.type == "token" && tokenNames[item.asset] == nil {
            guard !Task.isCancelled else{return}
            if let name=try? await AssetMedia.shared.loadName(hash:item.text("metadata_hash")),!Task.isCancelled {
                tokenNames[item.asset]=name
                var cache=(try? JSONDecoder().decode([String:String].self,from:savedTokenNames)) ?? [:]
                cache[item.text("metadata_hash")]=name
                if cache.count<=512,let bytes=try? JSONEncoder().encode(cache){savedTokenNames=bytes}
            }
        }
    }
    private func loadAddresses() async {
        guard let root,!wallet.locked else{return}
        do {
            let values=try await WalletAddressBook.shared.load(root:root)
            guard !wallet.locked,self.root==root else{return}
            addressEntries=values
            contactCategories=(try? await WalletAddressBook.shared.categories(root:root)) ?? []
            let contacts=try await ContactBook.shared.load()
            guard !wallet.locked,self.root==root else{return}
            connectedContacts=contacts
            let rows=(try? await LocalPaymentHistory.shared.load(root:root,owner:wallet.address)) ?? []
            guard !wallet.locked,self.root==root else{return}
            var seen=Set<String>()
            recentAddresses=rows.compactMap { $0["recipient"] as? String }
                .filter {AddressValidator.valid($0) && $0 != wallet.address && seen.insert($0).inserted}
        }catch{self.error=error.localizedDescription}
    }
    private func checkPendingSettlement() async {
        guard visible,tabActive,phase == .active,!busy,!checkingSettlement,!wallet.locked,!wallet.offlineMode,!node.running,
              pending?["state"] as? String == "authorized",let id=pending?["txid"] as? String,let root,
              Date().timeIntervalSince(lastSettlementCheck)>=20 else{return}
        let token=generation
        checkingSettlement=true;lastSettlementCheck=Date()
        defer{checkingSettlement=false}
        guard let directory=try? PaymentStorage.directory(root:root).path else {
            status="Protected payment storage is unavailable; the reservation was retained."
            return
        }
        if node.verifiedHeight != nil,
           await PaymentReconciliation.releaseAfterVerifiedExpiry(id:id,directory:directory,node:node,force:true) {
            guard valid(token) else{return}
            await loadPending()
            status="The signed epoch is past verified finality. Reservation released; the earlier payment outcome remains unknown without a receipt."
            return
        }
        do {
            let (_,receipt,hex)=try await node.fetchSettlement(transactionID:id)
            guard valid(token),pending?["txid"] as? String==id else{return}
            guard let receipt else {
                if await PaymentReconciliation.releaseAfterVerifiedExpiry(id:id,directory:directory,node:node) {
                    await loadPending();status="Signed payment epoch expired at verified finality. Prior settlement remains unknown; check its receipt before sending the same payment again."
                }
                return
            }
            guard receipt.finalized,let hex else{return}
            if try await PaymentReconciliation.apply(receipt:receipt,hex:hex,root:root,node:node) {
                guard valid(token) else{return}
                await loadPending();status="Previous payment finalized. Ready for a new payment."
            }
        }catch{
            guard valid(token) else{return}
            if await PaymentReconciliation.releaseAfterVerifiedExpiry(id:id,directory:directory,node:node) {
                await loadPending();status="Signed payment epoch expired at verified finality. Prior settlement remains unknown; check its receipt before sending the same payment again."
            } else {status="Previous payment could not yet be reconciled. Use Receipt and verification for details."}
        }
    }
    private func clear(){generation=UUID();plan=nil;review=nil;recipient="";amount="";assetSelection="NOID";standardKind = .noid;sendMax=false;pending=nil;pendingLoaded=false;addressEntries=[];connectedContacts=[];recentAddresses=[];checkingContact=nil;busy=false;error=nil;status=nil;scanAddress=false;nativeReview=false;nativeRequest=[:];showAddressBook=false;saveRecipient=false;showVerification=false;inputFocused=false}
    private func reviewNative(_ item:NativeItem) {
        inputFocused=false
        guard live.savedSnapshotDate == nil else {error="Refresh token and NFT holdings before sending. The saved inventory is for display only.";return}
        guard readyForNative else{error=exclusivePending ? "A transaction that reserves your whole wallet is still settling. Try again once it confirms." : ledgerEntries.count >= 20 ? "Twenty transactions are pending. Wait for some to confirm." : "Wait for the current step to finish.";return}
        guard wallet.localWallet?.recoveryVerified == true else {error="Import a signing wallet and confirm its backup before sending.";return}
        guard !wallet.offlineMode else {error="Reconnect before preparing a native asset transfer.";return}
        if GatewayConfiguration.saved == nil {
            guard node.enabled,nativeHoldingsAtVerifiedParent else {
                error=nativeBlockReason
                return
            }
        }
        guard AddressValidator.valid(recipient),recipient != wallet.address else{error="Choose a valid recipient other than this wallet.";return}
        if item.type == "nft" {
            guard item.text("owner")==wallet.address else{error="This NFT is not owned by the selected address.";return}
            if GatewayConfiguration.saved == nil {
                guard let height=node.verifiedHeight,height<UInt64.max,
                      let unlock=UInt64(item.text("unlock_height")),unlock<=height+1,
                      item.fields["reserved"] as? Bool == false else {
                    error="This NFT is locked or reserved at the verified block. It cannot be sent yet."
                    return
                }
            }
            nativeRequest=["action":"transfer_nft","collection_id":item.collection,"serial":item.text("serial"),"recipient":recipient]
        } else {
            guard item.type == "token",let units=Amounts.parse(amount).flatMap({UInt64($0)}),units>0,
                  let available=transferableTokenUnits(item),units<=available else{
                error="Enter an amount within the spendable token balance, using at most six decimal places. Refresh holdings if the verified block changed."
                return
            }
            nativeRequest=["action":"transfer_token","asset_id":item.asset,"units":String(units),"recipient":recipient]
        }
        // Same lookalike-address check as NOID payments, before the review opens.
        let to=recipient
        Task { @MainActor in
            do { try await AddressSafety.check(to,wallet:wallet,retry:{nativeReview=true}); nativeReview=true }
            catch let alert as AddressSafety.Lookalike { lookalikeAlert=alert }
            catch { self.error=error.localizedDescription; nativeRequest=[:] }
        }
    }
    private func setPercentage(_ percent:Int) {
        guard let available=noidAvailable.flatMap(Amounts.parse).flatMap({UInt64($0)}) else{return}
        let raw=(available/100)*UInt64(percent)+(available%100)*UInt64(percent)/100
        amount=Amounts.format(String(raw)) ?? "";sendMax=false
    }
    private func setTokenPercentage(_ percent:Int,_ item:NativeItem) {
        guard let available=transferableTokenUnits(item) else{amount="";return}
        let raw=(available/100)*UInt64(percent)+(available%100)*UInt64(percent)/100
        amount=Amounts.format(String(raw)) ?? ""
    }
    private func valid(_ token:UUID)->Bool{token==generation && visible && tabActive && !wallet.locked && !Task.isCancelled}
    private func perform(_ action:@escaping(UUID) async throws -> Void) {
        guard !busy,!wallet.locked else{return}
        let token=generation;busy=true;error=nil
        Task { @MainActor in
            defer{if token==generation{busy=false}}
            do{try await action(token)}catch{if valid(token){self.error=error.localizedDescription;await loadPending()}}
        }
    }
    private func loadPending() async {
        guard let root,!wallet.locked else{return};let token=generation
        do {
            let result=try await NativeCore.shared.call(["op":"payment_pending","journal_directory":PaymentStorage.directory(root:root).path])
            guard token==generation,!wallet.locked else{return};pending=result["pending"] as? [String:Any];ledgerEntries=PendingLedger.unresolved(result);pendingLoaded=true
            if pending?["state"] as? String == "finalized" {status="Previous payment finalized. Ready for a new payment."}
        }catch{if token==generation{self.error=error.localizedDescription}}
    }
    private func prepare() {
        guard readyForReview else{error=exclusivePending ? "A transaction that reserves your whole wallet is still settling. Try again once it confirms." : ledgerEntries.count >= 20 ? "Twenty transactions are pending. Wait for some to confirm." : "Wait for the current step to finish.";return}
        guard wallet.localWallet?.recoveryVerified == true else {error="Import a signing wallet and confirm its backup before sending.";return}
        guard AddressValidator.valid(recipient),recipient != wallet.address else{error="Choose a valid recipient other than this wallet.";return}
        let requested=sendMax ? nil : Amounts.parse(amount)
        guard sendMax || (requested.flatMap({UInt64($0)}) ?? 0)>0 else{error="Enter a positive NOID amount or choose Max.";return}
        let to=recipient;let owner=wallet.address
        let max=sendMax
        perform {token in
            do { try await AddressSafety.check(to,wallet:wallet,retry:{prepare()}) }
            catch let alert as AddressSafety.Lookalike { lookalikeAlert=alert; return }
            var input:[String:Any]=["op":"payment_plan","owner":owner,"address":to,"use_cached":wallet.offlineMode]
            // The node reads pending reservations from this wallet's ledger and plans around them.
            if let root {input["journal_directory"]=try PaymentStorage.directory(root:root).path}
            if max {input["send_max"]=true}
            else if let requested,let formatted=Amounts.format(requested){input["amount"]=formatted}
            let result=try await node.paymentOperation(input)
            guard valid(token),wallet.address==owner,result["owner"] as? String==owner,result["to"] as? String==to,
                  result["send_max"] as? Bool == max,
                  let plannedAmount=result["amount"] as? String,let raw=Amounts.parse(plannedAmount),
                  (max || raw==requested),let fee=result["fee"] as? String,let feeRaw=Amounts.parse(fee),
                  let unsigned=result["unsigned_intent"] as? String,let digest=result["review_id"] as? String,
                  let chain=result["chain_id"] as? String else{throw AppFailure("Payment plan differs from your request.")}
            let request:[String:Any]=["op":"payment_review","unsigned_intent":unsigned,"review_id":digest,"owner":owner,"to":to,"amount_micronoid":raw,"fee_micronoid":feeRaw,"maximum_fee_micronoid":"100000","chain_id":chain,"send_max":max,"using_saved_state":result["using_saved_state"] as? Bool ?? false]
            let checked=try await NativeCore.shared.call(request)
            guard valid(token) else{return}
            var displayed=request
            displayed["valid_through_height"]=result["valid_through_height"]
            displayed["busy_fee"]=result["busy_fee"] as? Bool ?? false
            plan=displayed;review=checked
        }
    }
    private func authorize() {
        guard let plan,let expected=review?["txid"] as? String else{return}
        perform {token in
            let context=try await wallet.requireAuthentication("Approve the reviewed NOID payment",fresh:true)
            guard valid(token),plan["owner"] as? String==wallet.address else{return}
            // Optional second confirmation on the paired Apple Watch (Settings → Wallet → Apple Watch).
            try await WatchBridge.shared.confirmOnWatchIfRequired(title:"Approve this iPhone payment",recipient:plan["to"] as? String ?? "",
                                                                  amount:Amounts.format(plan["amount_micronoid"] as? String ?? ""),fee:Amounts.format(plan["fee_micronoid"] as? String ?? ""))
            guard valid(token) else{return}
            if !wallet.offlineMode {
                let epoch=try await node.paymentOperation(["op":"payment_epoch_check","owner":wallet.address,"unsigned_intent":plan["unsigned_intent"] ?? "","review_id":plan["review_id"] ?? ""])
                guard valid(token),epoch["review_id"] as? String==plan["review_id"] as? String else{throw AppFailure("The payment review expired. Review again before signing.")}
            }
            var authorization=plan
            authorization["offline_delivery"]=wallet.offlineMode
            let authorized=try await WalletVault.shared.authorizePayment(authorization,source:.phone,context:context)
            guard valid(token),authorized["txid"] as? String==expected else{return}
            if let root {try? await LocalPaymentHistory.shared.record(root:root,owner:wallet.address,id:expected,kind:"NOID transfer",amount:plan["amount_micronoid"] as? String,recipient:plan["to"] as? String,status:"Authorized locally · settlement not verified")}
            await loadPending()
            if wallet.offlineMode {
                status="Authorization saved. When the app is active and this phone reconnects, it retries the identical payment. You can also carry it in an encrypted nearby message. Settlement remains unverified.";self.plan=nil;review=nil;return
            }
            guard valid(token),let intent=authorized["intent_hex"] as? String else{return}
            let sent=try await node.paymentOperation(["op":"broadcast_send","intent_hex":intent,"txid":expected])
            guard valid(token),sent["txid"] as? String==expected else{return}
            status="Submitted. Confirmation is not yet verified. Check confirmation to reconcile.";self.plan=nil;review=nil
        }
    }
    private func retry() {
        guard !wallet.offlineMode else{return}
        guard let id=pending?["txid"] as? String,let intent=pending?["intent_hex"] as? String else{return}
        perform {token in
            _=try await wallet.requireAuthentication("Resubmit this identical saved payment",fresh:true)
            guard valid(token) else{return}
            let sent:[String:Any]
            if pending?["operation_kind"] as? String=="native" {
                guard let root else{throw AppFailure("The signing wallet is unavailable; saved authorization retained.")}
                sent=try await node.paymentOperation(["op":"native_submit","expected_txid":id,"journal_directory":PaymentStorage.directory(root:root).path])
            }else{
                sent=try await node.paymentOperation(["op":"broadcast_send","intent_hex":intent,"txid":id])
            }
            guard valid(token),sent["txid"] as? String==id else{return};status="Identical payment resubmitted; no new authorization created."
        }
    }
    private func cancelPreparation() {
        guard let id=pending?["txid"] as? String,let root else{return}
        perform {token in
            _=try await wallet.requireAuthentication("Cancel only an unsigned payment preparation",fresh:true)
            guard valid(token) else{return}
            _=try await NativeCore.shared.call(["op":"payment_cancel_preparing","txid":id,"journal_directory":PaymentStorage.directory(root:root).path])
            guard valid(token) else{return};await loadPending();status="Unsigned preparation cancelled. No signed payment was cancelled."
        }
    }
    private func reconcile() {
        guard !wallet.offlineMode else{return}
        guard let id=pending?["txid"] as? String,let root else{return}
        perform {token in
            let (stage,receipt,hex)=try await node.fetchSettlement(transactionID:id)
            guard valid(token) else{return}
            guard receipt?.finalized==true else {
                let directory=try PaymentStorage.directory(root:root).path
                if receipt == nil,
                   await PaymentReconciliation.releaseAfterVerifiedExpiry(id:id,directory:directory,node:node,force:true) {
                    await loadPending()
                    status="Signed payment epoch expired at verified finality. Earlier settlement remains unknown; check its receipt before repeating it."
                } else {status="Status: \(stage). Reservation retained."}
                return
            }
            guard valid(token),let hex else{throw AppFailure("Receipt is unavailable; reservation retained.")}
            guard let receipt else{return}
            _=try await PaymentReconciliation.apply(receipt:receipt,hex:hex,root:root,node:node)
            guard valid(token) else{return};await loadPending();status="Final settlement verified. You can prepare another payment."
        }
    }
    private func checkExpiry() {
        guard let id=pending?["txid"] as? String,let root else{return}
        perform {token in
            _=try await node.paymentOperation(["op":"expire_payment","expected_txid":id,"journal_directory":PaymentStorage.directory(root:root).path])
            guard valid(token) else{return};await loadPending()
            status="Verified epoch expiry released the reservation. Prior settlement remains unknown; check before paying again."
        }
    }
}

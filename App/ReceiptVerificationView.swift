import SwiftUI

struct ReceiptInput {
    let hex:String
    let transactionID:String
    init(hex:String,transactionID:String) throws {
        // Bound input before normalization, including pasted whitespace.
        guard hex.utf8.count<=300_000 else { throw AppFailure("Receipt is too large.") }
        let normalized=hex.filter { !$0.isWhitespace }
        let id=transactionID.lowercased()
        guard id.utf8.count==64,id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !normalized.isEmpty,normalized.utf8.count<=262144,normalized.utf8.count%2==0,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw AppFailure("Enter a valid transaction ID and its hexadecimal payment receipt.")
        }
        self.hex=normalized;self.transactionID=id
    }
}
struct VerifiedReceipt {
    let transactionID:String
    let height:UInt64
    let confirmations:UInt64
    let finalized:Bool
    let checkedAt:Date
    /// Restores a finalized result this phone verified earlier (see VerifiedReceiptCache).
    init(transactionID:String,height:UInt64,confirmations:UInt64,finalized:Bool,checkedAt:Date) {
        self.transactionID=transactionID;self.height=height;self.confirmations=confirmations;self.finalized=finalized;self.checkedAt=checkedAt
    }
    init(result:[String:Any],expectedID:String) throws {
        guard result["verified"] as? Bool == true,result["txid"] as? String == expectedID,
              let height=result["height"] as? NSNumber,let h=UInt64(height.stringValue),
              let confirmations=result["confirmations"] as? NSNumber,let c=UInt64(confirmations.stringValue),c>0,
              let finalized=result["finalized"] as? Bool else { throw AppFailure("Node returned an invalid receipt verification result.") }
        transactionID=expectedID;self.height=h;self.confirmations=c;self.finalized=finalized;checkedAt=Date()
    }
}
struct ReceiptVerificationView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let transactionID:String
    private let initialReceipt:String
    @EnvironmentObject private var node:DeviceNode
    @EnvironmentObject private var wallet:WalletState
    @Environment(\.scenePhase) private var scenePhase
    @State private var receipt=""
    @State private var result:VerifiedReceipt?
    @State private var error:String?
    @State private var working=false
    @State private var lookupStatus:String?
    @State private var task:Task<Void,Never>?
    @State private var generation=UUID()
    @State private var automaticAttempted=false
    @State private var lastAutomaticHeight:UInt64?
    init(transactionID:String, suppliedReceipt:String = "") {
        self.transactionID=transactionID.lowercased()
        initialReceipt=(try? ReceiptInput(hex:suppliedReceipt,transactionID:transactionID).hex) ?? ""
        _receipt=State(initialValue:initialReceipt)
    }
    private var stateTitle:String {
        if working { return "Checking payment…" }
        if let result { return result.finalized ? "Payment confirmed" : "Included · awaiting finality" }
        return error == nil ? "Ready to verify" : "Could not verify yet"
    }
    private var canCheck:Bool {
        !working && !wallet.locked && node.enabled && DeviceNodeBridge.available && !node.running && (!receipt.isEmpty || !wallet.offlineMode)
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                UnavailableNotice(needs:[.deviceNode])
                statusPanel
                if !node.enabled || !DeviceNodeBridge.available {
                    NavigationLink("Set up local verification") { DeviceNodeView() }.buttonStyle(MintButtonStyle())
                } else {
                    Button(working ? "Checking…" : result == nil ? "Check payment" : "Check again") {
                        if receipt.isEmpty { fetch() } else { verify() }
                    }.buttonStyle(MintButtonStyle()).disabled(!canCheck)
                    if result?.finalized != true {
                        Text("Checks automatically when the device node is ready and as verified blocks advance.")
                            .font(Theme.caption).foregroundStyle(Theme.secondary)
                    }
                    if node.running && !working { Text("The verifier is finishing another check. Please wait.").font(Theme.caption).foregroundStyle(Theme.secondary) }
                    if receipt.isEmpty { Text(wallet.offlineMode ? "Go online to fetch a receipt, or paste one under Details." : "Fetches the receipt using this public transaction ID, then verifies it on your phone.").font(Theme.caption).foregroundStyle(Theme.secondary) }
                }
                if let lookupStatus { Text(lookupStatus).font(Theme.subheadline).foregroundStyle(Theme.secondary) }
                if let error { Text(error).font(Theme.subheadline).foregroundStyle(.orange) }
                if !receipt.isEmpty, (error != nil || result?.finalized == false), !wallet.offlineMode {
                    Button("Refresh chain and check again") { fetch() }.buttonStyle(ThemedButtonStyle()).disabled(working || node.running || !node.enabled)
                }
                receiptDetails
            }.padding(20)
        }.background(AmbientBackground()).navigationTitle("Verify payment").keyboardDismissControl().navigationBarTitleDisplayMode(.inline)
        .task(id:"\(transactionID)-\(wallet.locked)-\(scenePhase)") {
            guard !wallet.locked,scenePhase == .active else { return }
            if receipt.isEmpty {
                if !initialReceipt.isEmpty { receipt=initialReceipt }
                else if let saved=try? ReceiptStore.device().load(transactionID) { receipt=saved.hex }
            }
            automaticCheck()
        }
        .onChange(of:node.running) { _,running in if !running { automaticCheck() } }
        .onChange(of:node.verifiedHeight) { _,_ in automaticCheck() }
        .onChange(of:receipt) { _,_ in result=nil }
        .onChange(of:wallet.offlineMode) { _,_ in stopCheck() }
        .onChange(of:wallet.address) { _,_ in clear() }
        .onChange(of:wallet.locked) { _,locked in if locked { clear() } }
        .onChange(of:scenePhase) { _,phase in if phase == .background { clear() } }
        .onDisappear { clear() }
    }
    private var statusPanel: some View {
        Panel {
                    Label(stateTitle,systemImage:result?.finalized == true ? "checkmark.shield.fill" : "checkmark.shield")
                        .font(Theme.headline).foregroundStyle(result?.finalized == true ? Theme.mint : Theme.text)
                    if working { ProgressView().tint(Theme.mint) }
                    if let result {
                        Text(result.finalized ? "This phone verified that the transaction is finalized in its accepted chain." : "This phone verified inclusion. Finality is still pending.").font(Theme.body)
                        Text("Block \(result.height) · \(result.confirmations) confirmations").font(Theme.caption).foregroundStyle(Theme.secondary)
                        Text("Checked \(result.checkedAt.formatted(date:.omitted,time:.shortened))").font(Theme.caption2).foregroundStyle(Theme.secondary)
                    } else {
                        Text(receipt.isEmpty ? "Check this transaction against the phone’s verified chain." : error == nil ? "Receipt data is available for an on-device check." : "This receipt has not passed the on-device check.").font(Theme.body)
                    }
                    Text(String(transactionID.prefix(12)) + "…" + String(transactionID.suffix(8))).font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                }
    }
    private var receiptDetails: some View {
        DisclosureGroup("Details and supplied receipt") {
                    VStack(alignment:.leading,spacing:14) {
                        Text("Transaction ID").font(Theme.caption)
                        Text(transactionID).font(.caption.monospaced()).textSelection(.enabled)
                        TransactionExplorerLink(transactionID:transactionID)
                        Text("Optional: paste a receipt supplied by the sender. It is checked locally and is not uploaded.").font(Theme.caption).foregroundStyle(Theme.secondary)
                        PasteButton(payloadType:String.self) { values in
                            guard let value=values.first else { return }
                            do { receipt=try ReceiptInput(hex:value,transactionID:transactionID).hex;error=nil }
                            catch { self.error=error.localizedDescription }
                        }.accessibilityLabel("Paste payment receipt").disabled(working)
                        TextEditor(text:$receipt).font(.caption.monospaced()).frame(height:110)
                            .scrollContentBackground(.hidden).padding(10).themedCard(12)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("Payment receipt data").disabled(working)
                            .onChange(of:receipt) { _,value in if value.utf8.count>300000 {receipt="";error="Receipt exceeds the size limit."} }
                        NavigationLink("Verification status") { DeviceNodeView() }
                        Text("Verification proves inclusion and finality against the phone’s accepted chain. It does not approve a recipient or establish the safety of every action in the transaction.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    }.padding(.top,10)
                }.font(Theme.subheadline)
    }
    private func stopCheck() { generation=UUID();task?.cancel();task=nil;working=false }
    private func clear() { generation=UUID();task?.cancel();task=nil;receipt="";result=nil;error=nil;working=false;lookupStatus=nil;automaticAttempted=false;lastAutomaticHeight=nil }
    private func automaticCheck() {
        guard scenePhase == .active,canCheck,result?.finalized != true,
              !automaticAttempted || node.verifiedHeight != lastAutomaticHeight else { return }
        automaticAttempted=true;lastAutomaticHeight=node.verifiedHeight
        if receipt.isEmpty { fetch() } else { verify() }
    }
    private func fetch() {
        guard !wallet.locked,!wallet.offlineMode,!working else{return}
        working=true;result=nil;error=nil;lookupStatus=nil;let token=generation
        task=Task { @MainActor in
            defer{if token==generation{working=false;task=nil}}
            do {
                // A pruned public block cannot yield a receipt, but a saved
                // authorization may already be past the phone's verified
                // finality boundary. Check it before another network lookup.
                if node.verifiedHeight != nil,
                   let root=wallet.accounts.first(where:{$0.index==0})?.address,
                   let directory=try? PaymentStorage.directory(root:root).path,
                   await PaymentReconciliation.releaseAfterVerifiedExpiry(id:transactionID,directory:directory,node:node,force:true) {
                    guard token==generation,!Task.isCancelled,!wallet.locked else{return}
                    lookupStatus="Signed payment epoch expired at verified finality. Reservation released; earlier settlement remains unknown without a receipt."
                    return
                }
                let (stage,checked,receiptHex)=try await node.fetchSettlement(transactionID:transactionID)
                guard token==generation,!Task.isCancelled,!wallet.locked,!wallet.offlineMode else{return}
                result=checked
                if let checked,let root=wallet.accounts.first(where:{$0.index==0})?.address {
                    await rememberReceipt(root:root,hex:receiptHex)
                    if checked.finalized {await VerifiedReceiptCache.shared.remember(root:root,checked)}
                    try? await LocalPaymentHistory.shared.verifiedStatus(root:root,id:transactionID,status:checked.finalized ? "Finalized · verified on phone" : "Included · awaiting finality (verified on phone)")
                    await saveVerifiedBalance(root:root,receipt:checked)
                }
                if let checked,checked.finalized,let receiptHex,let root=wallet.accounts.first(where:{$0.index==0})?.address {
                    do { _ = try await PaymentReconciliation.apply(receipt:checked,hex:receiptHex,root:root,node:node) }
                    catch { if token == generation, !Task.isCancelled { self.error="Receipt verified, but updating the saved payment failed: " + error.localizedDescription } }
                }
                if checked == nil,let root=wallet.accounts.first(where:{$0.index==0})?.address,
                   let directory=try? PaymentStorage.directory(root:root).path,
                   await PaymentReconciliation.releaseAfterVerifiedExpiry(id:transactionID,directory:directory,node:node,force:true) {
                    guard token==generation,!Task.isCancelled,!wallet.locked else{return}
                    lookupStatus="Signed payment epoch expired at verified finality. Reservation released; earlier settlement remains unknown."
                    return
                }
                guard token == generation, !Task.isCancelled, !wallet.locked else { return }
                switch stage {
                case "unknown":lookupStatus="Not found by this service. This does not mean it failed or was cancelled."
                case "in_mempool":lookupStatus="Reported in the mempool. Not confirmed."
                case "body_pruned":lookupStatus="The service no longer has the block body. A receipt is still required."
                default:lookupStatus=stage
                }
            }catch{if token==generation,!Task.isCancelled{self.error=error.localizedDescription}}
        }
    }
    private func verify() {
        guard !wallet.locked,!working else{return}
        working=true;result=nil;error=nil;let token=generation;let input=receipt
        task=Task { @MainActor in
            defer { if token==generation { working=false;task=nil } }
            do {
                let verified=try await node.verifyReceipt(input,transactionID:transactionID)
                guard token==generation,!Task.isCancelled,!wallet.locked else{return}
                result=verified
                if verified.finalized,let root=wallet.accounts.first(where:{$0.index==0})?.address {await VerifiedReceiptCache.shared.remember(root:root,verified)}
                if let root=wallet.accounts.first(where:{$0.index==0})?.address {
                    await rememberReceipt(root:root,hex:input)
                    try? await LocalPaymentHistory.shared.verifiedStatus(root:root,id:transactionID,status:verified.finalized ? "Finalized · verified on phone" : "Included · awaiting finality (verified on phone)")
                    await saveVerifiedBalance(root:root,receipt:verified)
                }
                do { try ReceiptStore.device().save(ReceiptInput(hex:input,transactionID:transactionID)) }
                catch { self.error="Verified, but the receipt could not be saved: " + error.localizedDescription }
                if verified.finalized,let root=wallet.accounts.first(where:{$0.index==0})?.address {
                    do { _ = try await PaymentReconciliation.apply(receipt:verified,hex:input,root:root,node:node) }
                    catch { if token == generation, !Task.isCancelled { self.error="Receipt verified, but updating the saved payment failed: " + error.localizedDescription } }
                }
            } catch {
                if token==generation,!Task.isCancelled { self.error=error.localizedDescription }
            }
        }
    }
    private func saveVerifiedBalance(root:String,receipt:VerifiedReceipt) async {
        guard node.balance(for:wallet.address) != nil,
              let amount=node.balanceMicronoid,let height=node.balanceHeight else {return}
        try? await LocalPaymentHistory.shared.recordBalanceAtVerification(root:root,owner:wallet.address,id:transactionID,transactionHeight:receipt.height,balanceHeight:height,micronoid:amount)
    }
    private func rememberReceipt(root:String,hex:String?) async {
        try? await ChatReceiptIndex.shared.rememberVerified(root:root,transactionID:transactionID,hex:hex,date:Date())
    }
}

enum ReceiptScope {case chat,all}
struct ReceiptLookupView:View {
    var scope:ReceiptScope = .chat
    @State private var transactionID=""
    @EnvironmentObject private var wallet:WalletState
    @EnvironmentObject private var node:DeviceNode
    @Environment(\.scenePhase) private var phase
    @State private var entries:[ChatReceiptIndex.Entry]=[]
    @State private var verified:[String:VerifiedReceipt]=[:]
    @State private var checking=false
    @State private var checkedHeight:UInt64?
    @State private var message:String?
    @State private var visible=false
    private var normalized:String {transactionID.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
    private var valid:Bool {normalized.count==64 && Data(hex:normalized)?.count==32}
    private var walletRoot:String? {wallet.accounts.first(where:{$0.index==0})?.address}
    private var verifiedEntries:[ChatReceiptIndex.Entry] {entries.filter{verified[$0.id] != nil}}
    private var pendingEntries:[ChatReceiptIndex.Entry] {entries.filter{verified[$0.id] == nil}}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Panel {
                    Label("Check a new receipt",systemImage:"checkmark.shield").font(Theme.headline)
                    TextField("Transaction ID",text:$transactionID,axis:.vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                        .padding(12).background(Theme.background,in:RoundedRectangle(cornerRadius:12))
                    NavigationLink {ReceiptVerificationView(transactionID:normalized)} label:{ThemedLabel("Verify on this phone", systemImage: "arrow.right")}
                        .buttonStyle(MintButtonStyle()).disabled(!valid)
                }
                HStack {
                    Text("VERIFIED RECEIPTS").font(Theme.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Theme.secondary)
                    Spacer()
                    if checking {ProgressView().tint(Theme.mint)}
                }
                if verifiedEntries.isEmpty {
                    Text(checking ? "Checking saved payments…" : scope == .chat ? "No chat payment receipts verified yet." : "No saved receipts verified yet.")
                        .font(Theme.subheadline).foregroundStyle(Theme.secondary)
                }
                ForEach(verifiedEntries) {entry in
                    if let result=verified[entry.id] {
                        NavigationLink {ReceiptVerificationView(transactionID:entry.id,suppliedReceipt:entry.suppliedReceipt ?? "")} label: {
                            Panel {
                                Label(result.finalized ? "Finalized · verified" : "Included · awaiting finality",systemImage:"checkmark.shield.fill")
                                    .font(Theme.headline).foregroundStyle(Theme.mint)
                                Text(String(entry.id.prefix(12))+"…"+String(entry.id.suffix(8))).font(.caption.monospaced())
                                Text("Block \(result.height) · Added \(entry.seenAt.formatted(date:.abbreviated,time:.shortened))")
                                    .font(Theme.caption).foregroundStyle(Theme.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if !pendingEntries.isEmpty {
                    DisclosureGroup("Awaiting verification · \(pendingEntries.count)") {
                        VStack(alignment:.leading,spacing:12) {
                            ForEach(pendingEntries) {entry in
                                NavigationLink {ReceiptVerificationView(transactionID:entry.id,suppliedReceipt:entry.suppliedReceipt ?? "")} label: {
                                    Text(String(entry.id.prefix(12))+"…"+String(entry.id.suffix(8))).font(.caption.monospaced())
                                }
                            }
                        }.padding(.top,10)
                    }.foregroundStyle(Theme.secondary)
                }
                if let message {Text(message).font(Theme.caption).foregroundStyle(.orange)}
                if !entries.isEmpty {Button("Check saved payments again") {checkedHeight=nil;Task {await refresh()}}.disabled(checking || node.running || wallet.locked)}
            }.padding(20)
        }.background(AmbientBackground()).navigationTitle("Receipts").keyboardDismissControl()
            .onAppear {visible=true}
            .onDisappear {visible=false}
            .task(id:"\(wallet.address)-\(wallet.locked)-\(phase)") {
                guard !wallet.locked,phase == .active else{entries=[];verified=[:];return}
                visible=true;await load()
            }
            .onChange(of:node.verifiedHeight) {_,_ in Task {await refresh()}}
            .onChange(of:node.running) {_,running in if !running {Task {await refresh()}}}
    }
    private func load() async {
        #if DEBUG
        if StoreShots.on {
            entries=StoreShots.receipts.map{.init(id:$0.id,seenAt:Date().addingTimeInterval(-$0.hours*3600),suppliedReceipt:nil,source:"wallet")}
            verified=Dictionary(uniqueKeysWithValues:StoreShots.receipts.map{($0.id,VerifiedReceipt(transactionID:$0.id,height:$0.height,confirmations:24,finalized:true,checkedAt:Date()))})
            checkedHeight=0;message=nil;return
        }
        #endif
        guard let root=walletRoot else{return}
        do {entries=try await scopedEntries(root:root);verified=await VerifiedReceiptCache.shared.load(root:root,verifiedHeight:node.verifiedHeight);checkedHeight=nil;message=nil;await refresh()}
        catch {message=error.localizedDescription}
    }
    private func scopedEntries(root:String) async throws -> [ChatReceiptIndex.Entry] {
        var list=try await ChatReceiptIndex.shared.entries(root:root)
        if scope == .chat {return list.filter{$0.source == "chat"}}
        let history=try await LocalPaymentHistory.shared.load(root:root,owner:wallet.address)
        let known=Set(list.map(\.id))
        for row in history {
            guard let id=row["txid"] as? String,!known.contains(id),id.count==64,Data(hex:id)?.count==32 else{continue}
            let timestamp=row["timestamp"] as? TimeInterval ?? 0
            list.append(.init(id:id,seenAt:Date(timeIntervalSince1970:timestamp),suppliedReceipt:nil,source:"wallet"))
        }
        return list.sorted{$0.seenAt>$1.seenAt}
    }
    private func refresh() async {
        #if DEBUG
        if StoreShots.on {return}
        #endif
        guard let root=walletRoot,visible,!wallet.locked,phase == .active,node.enabled,!node.running,!checking,
              checkedHeight == nil || checkedHeight != node.verifiedHeight else{return} // unverified ones retry when a new block is verified or on request
        checkedHeight=node.verifiedHeight;checking=true;defer{checking=false}
        do {entries=try await scopedEntries(root:root)}
        catch {message=error.localizedDescription;return}
        guard !wallet.offlineMode || entries.contains(where:{$0.suppliedReceipt != nil}) else{return}
        for entry in entries {
            guard !Task.isCancelled,visible,!wallet.locked,walletRoot==root,phase == .active else{return}
            if verified[entry.id]?.finalized == true {continue}
            do {
                let result:VerifiedReceipt?
                if let supplied=entry.suppliedReceipt {
                    result=try await node.verifyReceipt(supplied,transactionID:entry.id)
                    if let result {try ReceiptStore.device().save(ReceiptInput(hex:supplied,transactionID:result.transactionID))}
                } else if !wallet.offlineMode {
                    let (_,checked,_)=try await node.fetchSettlement(transactionID:entry.id)
                    result=checked
                } else {continue}
                guard !Task.isCancelled,!wallet.locked,walletRoot==root else{return}
                if let result {
                    verified[entry.id]=result
                    // Finality does not change, so keep it; the next visit shows it at once.
                    if result.finalized {await VerifiedReceiptCache.shared.remember(root:root,result)}
                }
            } catch {continue} // A peer claim remains unverified; a later block or manual check may succeed.
        }
    }
}

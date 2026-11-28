import SwiftUI
#if canImport(ParanoidNode)
import ParanoidNode
#endif

/// Foreground verifier; control calls may cancel a worker without waiting for it.
enum DeviceNodeBridge {
    // MDBX does not permit independent environments for the same NativeState
    // directory to be opened concurrently. Node sync installs a snapshot while
    // gallery/catalog requests read it, so serialize those complete FFI calls.
    // Control calls remain outside the lock so a running verifier can be paused.
    private static let nativeStateLock = NSLock()
    private static let nativeStateOperations: Set<String> = [
        "sync_once", "verify_parent", "wallet_balance", "payment_plan",
        "native_holdings", "native_planning_probe", "native_prepare", "native_listings", "native_collections", "native_markets"
    ]
    static var available: Bool {
        #if canImport(ParanoidNode)
        return true
        #else
        return false
        #endif
    }
    static func call(_ request:[String:Any]) throws -> [String:Any] {
        #if canImport(ParanoidNode)
        let needsState = (request["op"] as? String).map { nativeStateOperations.contains($0) } ?? false
        if needsState { nativeStateLock.lock() }
        defer { if needsState { nativeStateLock.unlock() } }
        var request=request
        request["rpc_endpoints_extra"]=NodeEndpoints.extra
        if request["op"] as? String == "broadcast_send" {request["direct_peers"]=NodeEndpoints.directPeers}
        if NodeEndpoints.paranoid,let op=request["op"] as? String,NodeEndpoints.paranoidOperations.contains(op) {request["paranoid_mode"]=true}
        let bytes=try JSONSerialization.data(withJSONObject:request)
        let pointer=bytes.withUnsafeBytes { raw in paranoid_node_call(raw.bindMemory(to:UInt8.self).baseAddress,bytes.count) }
        guard let pointer else { throw AppFailure("No node response.") };defer{paranoid_node_free(pointer)}
        let data=Data(bytes:pointer,count:strlen(pointer))
        guard let envelope=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw AppFailure("Invalid device node response.")}
        guard envelope["ok"] as? Bool == true,let result=envelope["result"] as? [String:Any] else {
            let detail=(envelope["error"] as? String).flatMap{$0.count<=360 && !$0.contains("\n") ? $0 : nil}
            throw AppFailure(detail ?? "Node verification failed or was paused. No verified state was advanced.")
        }
        return result
        #else
        throw AppFailure("On-device node framework is not linked.")
        #endif
    }
}
@MainActor final class DeviceNode:ObservableObject {
    @Published var phase="Stopped"
    @Published var verifiedHeight:UInt64?
    @Published var verifiedHash:String?
    @Published private(set) var nativeStateHeight:UInt64?
    @Published private(set) var nativeStateHash:String?
    @Published private(set) var nativeStateIssue:String?
    @Published var error:String?
    @Published private(set) var balanceOwner:String?
    @Published private(set) var balanceMicronoid:String?
    @Published private(set) var balanceHeight:UInt64?
    @Published private(set) var balanceCheckedAt:Date?
    @Published private(set) var balanceProofsVerified=false
    @Published private(set) var lastBalance:LastBalanceSnapshot?
    func restoreLastBalance(_ snapshot:LastBalanceSnapshot?,owner:String) {
        guard let snapshot,snapshot.valid(for:owner) else{return}
        if lastBalance?.owner != owner || snapshot.verifiedAt >= (lastBalance?.verifiedAt ?? .distantPast) {lastBalance=snapshot}
    }
    func balance(for owner:String)->String? {
        guard enabled,phase=="Verified boundary",balanceProofsVerified,
              balanceOwner==owner,let raw=balanceMicronoid,
              let balanceHeight,let verifiedHeight,balanceHeight==verifiedHeight,
              let checked=balanceCheckedAt,Date().timeIntervalSince(checked)>=0,
              Date().timeIntervalSince(checked)<120 else{return nil}
        return Amounts.format(raw)
    }
    func resetWallet() {
        pause();lastAttempt = .distantPast
        clearRetry()
        balanceOwner=nil;balanceMicronoid=nil;balanceHeight=nil;balanceCheckedAt=nil;balanceProofsVerified=false
        nativeStateHeight=nil;nativeStateHash=nil;nativeStateIssue=nil
        lastBalance=nil
    }
    @Published var enabled=(UserDefaults.standard.object(forKey: "deviceNodeEnabled") as? Bool) ?? DeviceNodeBridge.available {
        didSet { UserDefaults.standard.set(enabled,forKey:"deviceNodeEnabled");if !enabled {pause()} }
    }
    var transactionFlowActive=false
    /// Payment or review steps waiting for a running chain check; no new automatic check starts meanwhile.
    private var paymentWaiters=0
    /// What a payment or review step is doing right now, shown under its progress spinner.
    @Published private(set) var paymentStage:String?
    @Published private(set) var running=false
    @Published private(set) var syncStartedAt:Date?
    @Published private(set) var syncStage:String?
    private var lastAttempt=Date.distantPast
    @Published private(set) var retryAt:Date?
    @Published private(set) var consecutiveFailures=0
    private var lastProgressPoll=Date.distantPast
    @Published var verifiedAt:Date?
    private var session=UUID()
    private var activeSyncSession:UUID?
    private func scheduleRetry(_ failure:Error) {
        consecutiveFailures=min(consecutiveFailures+1,8)
        retryAt=Date().addingTimeInterval(min(30.0 * pow(2.0,Double(consecutiveFailures-1)),300.0))
        error=failure.localizedDescription
        phase="Error"
    }
    private func scheduleBalanceRetry(_ failure:Error) {
        scheduleRetry(failure)
        // The fallback produced a verified header boundary. Balance discovery
        // failed separately; retain the truthful chain status and retry both.
        phase="Verified boundary"
    }
    private func clearRetry() {
        consecutiveFailures=0
        retryAt=nil
    }
    func verifyReceipt(_ hex:String, transactionID:String) async throws -> VerifiedReceipt {
        guard enabled,DeviceNodeBridge.available,!running else { throw AppFailure("Enable the device node and wait for its current verification to finish.") }
        let receipt=try ReceiptInput(hex:hex,transactionID:transactionID)
        guard let artifacts=Bundle.main.url(forResource:"NodeParameters",withExtension:nil) else { throw AppFailure("Node verification parameters are missing.") }
        let directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:false).appendingPathComponent("VerifiedNode",isDirectory:true)
        let token=session;running=true
        defer { running=false }
        _=try DeviceNodeBridge.call(["op":"node_active","active":true])
        let result=await Task.detached(priority:.utility) {
            Result { try DeviceNodeBridge.call(["op":"receipt_check","receipt_hex":receipt.hex,"expected_txid":receipt.transactionID,"artifacts":artifacts.path,"data_dir":directory.path]) }
        }.value
        guard token==session,!Task.isCancelled else { throw CancellationError() }
        return try VerifiedReceipt(result:result.get(),expectedID:receipt.transactionID)
    }
    /// Explicit network action: collect a receipt, synchronize, then independently verify.
    func fetchSettlement(transactionID:String) async throws -> (String,VerifiedReceipt?,String?) {
        guard enabled,DeviceNodeBridge.available,!running else{throw AppFailure("Wait for node verification to finish, then retry.")}
        guard transactionID.count==64,Data(hex:transactionID)?.count==32 else{throw AppFailure("Invalid transaction ID.")}
        guard let artifacts=Bundle.main.url(forResource:"NodeParameters",withExtension:nil) else{throw AppFailure("Verification parameters are missing.")}
        let directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("VerifiedNode",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        let token=session;running=true;defer{running=false}
        _=try DeviceNodeBridge.call(["op":"node_active","active":true])
        let outcome=await Task.detached(priority:.utility) {
            Result { () throws -> [String:Any] in
                // The saved copy is only a cache: if it can't be opened, look the payment up instead.
                let store=try? ReceiptStore.device()
                var evidence=(try? store?.load(transactionID)) ?? nil
                if let cached=evidence,
                   let checked=try? DeviceNodeBridge.call(["op":"receipt_check","receipt_hex":cached.hex,"expected_txid":transactionID,"artifacts":artifacts.path,"data_dir":directory.path]),
                   let verified=try? VerifiedReceipt(result:checked,expectedID:transactionID),verified.finalized {
                    return ["stage":"included","receipt":checked,"receipt_hex":cached.hex]
                }
                if evidence==nil {
                    let location=try DeviceNodeBridge.call(["op":"transaction_status","txid":transactionID])
                    guard location["txid"] as? String==transactionID,let stage=location["stage"] as? String else{throw AppFailure("Transaction lookup identity mismatch.")}
                    if stage != "included" {
                        guard ["unknown","in_mempool","body_pruned"].contains(stage) else{throw AppFailure("Unknown transaction status.")}
                        return ["stage":stage]
                    }
                    guard let hex=location["receipt_hex"] as? String else{throw AppFailure("Transaction lookup returned no receipt.")}
                    evidence=try ReceiptInput(hex:hex,transactionID:transactionID)
                }
                guard let receipt=evidence else{throw AppFailure("Receipt is unavailable.")}
                let synchronized=try DeviceNodeBridge.call(["op":"sync_once","artifacts":artifacts.path,"data_dir":directory.path])
                let checked=try DeviceNodeBridge.call(["op":"receipt_check","receipt_hex":receipt.hex,"expected_txid":transactionID,"artifacts":artifacts.path,"data_dir":directory.path])
                _=try VerifiedReceipt(result:checked,expectedID:transactionID)
                // The receipt is already verified; saving a copy is only a cache, so a full
                // receipt store must never turn a confirmed payment back into "unknown".
                try? store?.save(receipt)
                return ["stage":"included","receipt":checked,"receipt_hex":receipt.hex,"verified":synchronized["verified"] ?? [:]]
            }
        }.value
        guard token==session,!Task.isCancelled else{throw CancellationError()}
        var result:[String:Any]
        do {result=try outcome.get()}
        catch {
            // A lookup failure must still allow the independent phone verifier
            // to advance and test the signed epoch's finalized boundary.
            result=["stage":"lookup_unavailable"]
        }
        if let stage=result["stage"] as? String,["unknown","body_pruned","in_mempool","lookup_unavailable"].contains(stage),
           let gateway=GatewayConfiguration.saved {
            // The configured full node may retain a body absent from the public RPC.
            // Its response is untrusted until the Rust verifier checks the block,
            // transaction commitment, receipt and accepted local chain.
            let evidence=try? await GatewayClient(gateway).query(["kind":"payment_evidence","txid":transactionID])
            guard token==session,!Task.isCancelled else{throw CancellationError()}
            if evidence?["stage"] as? String == "evidence",
               let location=evidence?["location"] as? [String:Any],
               let block=evidence?["block_hex"] as? String {
                let collected=await Task.detached(priority:.utility) {
                    Result { () throws -> [String:Any] in
                        let found=try DeviceNodeBridge.call(["op":"transaction_evidence","txid":transactionID,"location":location,"block_hex":block])
                        guard found["txid"] as? String==transactionID,found["stage"] as? String=="included",
                              let hex=found["receipt_hex"] as? String else{throw AppFailure("Full node evidence did not identify this payment.")}
                        let receipt=try ReceiptInput(hex:hex,transactionID:transactionID)
                        let synchronized=try DeviceNodeBridge.call(["op":"sync_once","artifacts":artifacts.path,"data_dir":directory.path])
                        let checked=try DeviceNodeBridge.call(["op":"receipt_check","receipt_hex":receipt.hex,"expected_txid":transactionID,"artifacts":artifacts.path,"data_dir":directory.path])
                        _=try VerifiedReceipt(result:checked,expectedID:transactionID)
                        try? ReceiptStore.device().save(receipt) // cache only; see above
                        return ["stage":"included","receipt":checked,"receipt_hex":receipt.hex,"verified":synchronized["verified"] ?? [:]]
                    }
                }.value
                guard token==session,!Task.isCancelled else{throw CancellationError()}
                if let verifiedEvidence=try? collected.get() {result=verifiedEvidence}
                else {result["stage"]="lookup_unavailable"}
            } else if let alternate=evidence?["stage"] as? String,["unknown","body_pruned"].contains(alternate) {
                result["stage"]=alternate
            }
        }
        if result["receipt"] == nil {
            // Receipt lookup can return unknown while the accepted phone boundary
            // remains old. Advance it before the caller checks verified expiry.
            // This does not assert that the payment failed or clear its journal.
            let refreshed=await Task.detached(priority:.utility) {
                Result { try DeviceNodeBridge.call(["op":"sync_once","artifacts":artifacts.path,"data_dir":directory.path]) }
            }.value
            guard token==session,!Task.isCancelled else{throw CancellationError()}
            if let updated=try? refreshed.get(),
               let state=updated["verified"] as? [String:Any],
               let height=state["height"] as? NSNumber,let hash=state["block_hash"] as? String {
                verifiedHeight=height.uint64Value;verifiedHash=hash;verifiedAt=Date();phase="Verified boundary";error=nil
            }
        }
        if let checked=result["receipt"] as? [String:Any] {
            let receipt=try VerifiedReceipt(result:checked,expectedID:transactionID)
            if let state=result["verified"] as? [String:Any],let height=state["height"] as? NSNumber,let hash=state["block_hash"] as? String {
                verifiedHeight=height.uint64Value;verifiedHash=hash;verifiedAt=Date();phase="Verified boundary";error=nil
            }
            return (receipt.finalized ? "Finalized" : "Included",receipt,result["receipt_hex"] as? String)
        }
        return (result["stage"] as? String ?? "unknown",nil,nil)
    }
    func paymentOperation(_ input:[String:Any]) async throws -> [String:Any] {
        guard enabled,DeviceNodeBridge.available else{throw AppFailure("Turn on Device node first.")}
        // A routine chain check may be running (a synced node checks about every 30 seconds).
        // Wait for it to finish instead of failing, and hold off new automatic checks meanwhile.
        defer{paymentStage=nil}
        if running {
            paymentStage="Waiting for the node's current chain check to finish…"
            paymentWaiters+=1;defer{paymentWaiters-=1}
            let deadline=Date().addingTimeInterval(180)
            while running && Date()<deadline {
                try await Task.sleep(nanoseconds:300_000_000)
            }
        }
        guard !running else{throw AppFailure("The device node is still checking the chain. Try again in a minute.")}
        guard let op=input["op"] as? String,["payment_plan","payment_epoch_check","broadcast_send","native_submit","native_prepare","native_planning_probe","transaction_status","settle_payment","verify_parent","expire_payment","market_history"].contains(op) else{throw AppFailure("Unsupported node action.")}
        guard let artifacts=Bundle.main.url(forResource:"NodeParameters",withExtension:nil) else{throw AppFailure("Verification parameters are missing.")}
        let directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("VerifiedNode",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        var request=input;request["artifacts"]=artifacts.path;request["data_dir"]=directory.path
        switch op {
        case "verify_parent": paymentStage=NodeEndpoints.paranoid ? "Checking the latest block with mainnet peers…" : "Checking the latest block…"
        case "native_prepare","payment_plan": paymentStage="Preparing the exact terms…"
        case "broadcast_send","native_submit": paymentStage="Sending…"
        case "transaction_status","settle_payment": paymentStage="Checking the transaction…"
        default: paymentStage="Working…"
        }
        let token=session;running=true;defer{running=false}
        _=try DeviceNodeBridge.call(["op":"node_active","active":true])
        let result=await Task.detached(priority:.userInitiated){Result{try DeviceNodeBridge.call(request)}}.value
        guard token==session,!Task.isCancelled else{throw CancellationError()}
        return try result.get()
    }
    func pause() {
        session=UUID();phase="Paused";syncStartedAt=nil;syncStage=nil;lastAttempt = .distantPast
        _ = try? DeviceNodeBridge.call(["op":"node_active","active":false])
    }
    func pollProgress() {
        guard running,phase == "Verifying",DeviceNodeBridge.available else{return}
        if let started=syncStartedAt,Date().timeIntervalSince(started)>600 {
            pause()
            scheduleRetry(AppFailure("Verification exceeded ten minutes. Check network access to NOID peers; the app will retry. No new chain state was accepted."))
            return
        }
        guard Date().timeIntervalSince(lastProgressPoll)>=5 else{return}
        lastProgressPoll=Date()
        if let status=try? DeviceNodeBridge.call(["op":"node_status"]),
           let stage=status["phase"] as? String,
           ["starting","following","verifying","paused"].contains(stage) {
            let detail:String
            if stage == "verifying",let transfer=status["header_transfer"] as? [String:Any],
               let received=transfer["received"] as? NSNumber,
               let total=transfer["total"] as? NSNumber,total.uint64Value > 0 {
                detail="Downloading verified chain or State data \(received.uint64Value.formatted()) / \(total.uint64Value.formatted())"
            } else {
                switch stage {
                case "starting":detail="Starting verifier"
                case "following":detail="Finding compatible peers"
                case "verifying":detail="Checking chain proof"
                default:detail="Verification paused"
                }
            }
            if syncStage != detail {syncStage=detail}
        }
    }
    func synchronize(unlocked:Bool,offline:Bool,force:Bool=false,owner:String?=nil) {
        // Foreground synchronization is the discovery path for newly acquired
        // native assets. Keep a bounded interval so a recent purchase does not
        // wait a full minute before its verified State can advance.
        guard enabled,unlocked,!offline,!running,paymentWaiters==0,(!transactionFlowActive || force),
              force || (Date().timeIntervalSince(lastAttempt)>=30 && Date() >= (retryAt ?? .distantPast)) else{return}
        lastAttempt=Date()
        guard DeviceNodeBridge.available else{error="Build and link the on-device node framework first.";return}
        guard let artifacts=Bundle.main.url(forResource:"NodeParameters",withExtension:nil) else{error="Pinned node verification parameters are missing.";return}
        do {
            let base=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("VerifiedNode",isDirectory:true)
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
            var url=base;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
            _ = try DeviceNodeBridge.call(["op":"node_active","active":true])
            running=true;phase="Verifying";error=nil;syncStartedAt=Date();syncStage="Starting verifier";let token=session;activeSyncSession=token
            let requestedOwner=owner.flatMap {AddressValidator.valid($0) ? $0 : nil}
            var request:[String:Any]=["op":requestedOwner == nil ? "sync_once" : "wallet_balance","artifacts":artifacts.path,"data_dir":base.path]
            if let requestedOwner {request["owner"]=requestedOwner}
            Task {
                let result=await Task.detached(priority:.utility) { Result { () throws -> [String:Any] in
                    // wallet_balance already synchronizes and verifies the chain.
                    // Only fall back to State-only sync if discovery fails.
                    return try NodeRefresh.execute(request, call: DeviceNodeBridge.call)
                } }.value
                guard activeSyncSession==token else{return}
                activeSyncSession=nil
                running=false;syncStartedAt=nil;syncStage=nil
                guard token==session else{return}
                switch result {
                case .success(let result):
                    guard let verified=result["verified"] as? [String:Any],let height=verified["height"] as? NSNumber,let hash=verified["block_hash"] as? String else{scheduleRetry(AppFailure("Node returned no verified boundary."));return}
                    clearRetry()
                    verifiedHeight=height.uint64Value;verifiedHash=hash;verifiedAt=Date();phase="Verified boundary";error=nil
                    nativeStateIssue=result["native_state_error"] as? String
                    if nativeStateIssue == nil, let installed=result["native_state"] as? [String:Any] { nativeStateIssue=installed["sync_issue"] as? String }
                    if let installed=result["native_state"] as? [String:Any],
                       let nativeHeight=installed["height"] as? NSNumber,
                       let nativeHash=installed["block_hash"] as? String {
                        nativeStateHeight=nativeHeight.uint64Value; nativeStateHash=nativeHash
                    }
                    if let requestedOwner {
                        if let balanceError=result["balance_error"] as? String {scheduleBalanceRetry(AppFailure("Chain verified; wallet balance refresh pending: \(balanceError)"));return}
                        guard result["owner"] as? String==requestedOwner,let amount=result["amount_micronoid"] as? String,Amounts.format(amount) != nil else{scheduleBalanceRetry(AppFailure("Chain verified; wallet balance result invalid. Retrying."));return}
                        balanceOwner=requestedOwner;balanceMicronoid=amount;balanceHeight=(result["balance_height"] as? NSNumber)?.uint64Value;balanceCheckedAt=Date();balanceProofsVerified=result["proofs_verified"] as? Bool == true
                        if balanceProofsVerified,let balanceHeight,let verifiedHash, balanceHeight==verifiedHeight {
                            let snapshot=LastBalanceSnapshot(owner:requestedOwner,micronoid:amount,height:balanceHeight,blockHash:verifiedHash,verifiedAt:Date())
                            if snapshot.valid(for:requestedOwner) {
                                restoreLastBalance(snapshot,owner:requestedOwner)
                                Task {try? await LastBalanceStore.shared.save(snapshot)}
                                if let shown=Amounts.format(amount) {PhoneWidgetData.saveBalance(amount:shown,verifiedAt:snapshot.verifiedAt,height:balanceHeight)}
                            }
                        }
                    }
                case .failure(let failure):scheduleRetry(failure)
                }
            }
        }catch{scheduleRetry(error)}
    }
}
struct DeviceNodeView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var node:DeviceNode
    @EnvironmentObject private var wallet:WalletState
    @State private var planningProbe:[String:Any]?
    @State private var planningProbeError:String?
    @State private var probing=false
    var body:some View {
        Form {
            Section("On-device verification") {
                Toggle("Enable device node",isOn:$node.enabled).disabled(!DeviceNodeBridge.available)
                LabeledContent("Node framework", value: DeviceNodeBridge.available ? "Included" : "Not linked")
                LabeledContent("Verification parameters", value: Bundle.main.url(forResource: "NodeParameters", withExtension: nil) == nil ? "Missing" : "Included")
                LabeledContent("Status",value:node.phase)
                if let height=node.verifiedHeight { LabeledContent("Verified height",value:String(height)) }
                if let hash=node.verifiedHash { Text(hash).font(.caption.monospaced()).textSelection(.enabled) }
                if let height=node.nativeStateHeight { LabeledContent("Installed NFT State",value:"Block \(height)") }
                else { LabeledContent("Installed NFT State",value:"Awaiting snapshot") }
                if let issue=node.nativeStateIssue {Text("State installation: \(issue)").font(Theme.footnote).foregroundStyle(.orange)}
                Button("Verify now") { node.synchronize(unlocked:!wallet.locked,offline:wallet.offlineMode,force:true,owner:wallet.address) }
                    .disabled(wallet.offlineMode || wallet.locked || !DeviceNodeBridge.available || node.running)
                if node.running && node.phase == "Verifying" {
                    if let stage=node.syncStage {LabeledContent("Current step",value:stage)}
                    if let started=node.syncStartedAt {Text("Verification running since ") + Text(started,style:.relative) + Text(" ago")}
                    Button("Cancel verification") {node.pause()}
                    Text("First synchronization may take time while peers supply a proof. If this stays on one step, check the phone's network, then cancel and retry.")
                        .font(Theme.footnote)
                }
                if node.running && node.phase == "Error" {Text("Waiting for the interrupted verifier to stop before retrying.").font(Theme.footnote)}
                if let time=node.verifiedAt { Text("Last verified: ") + Text(time,style:.relative) + Text(" ago") }
                if let error=node.error { Text(error).foregroundStyle(.orange) }
                if let retry=node.retryAt, node.enabled && !wallet.offlineMode {
                    Text("Automatic retry ") + Text(retry,style:.relative)
                }
            }.themedRow()
            Section { Text("The mobile node verifies headers, proof of work, recursive state proofs and receipts. It is not an archive or mining node. RPC can still provide discovery data; that data must be bound to this verified state before spending. Verification pauses in the background and in offline mode.") }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Device node")
            .onChange(of:wallet.address) {_,_ in planningProbe=nil;planningProbeError=nil}
            .onChange(of:node.verifiedHash) {_,_ in planningProbe=nil;planningProbeError=nil}
    }
}

/// A recent accepted boundary is a sync result, not a continuous network probe.
enum NodeHeaderStatus: String {
    case synced = "Synced"
    case synchronizing = "Synchronizing"
    case offline = "Offline"
    case needsAttention = "Needs attention"

    static func current(enabled: Bool, offline: Bool, framework: Bool,
                        phase: String, error: String?, verifiedAt: Date?, now: Date) -> Self {
        guard enabled, !offline else { return .offline }
        guard framework, error == nil, phase != "Error" else { return .needsAttention }
        if phase == "Verifying" { return .synchronizing }
        guard phase == "Verified boundary", let verifiedAt,
              now.timeIntervalSince(verifiedAt) >= 0,
              now.timeIntervalSince(verifiedAt) < 120 else { return .offline }
        return .synced
    }

    var symbol: String {
        switch self {
        case .synced: "circle.fill"
        case .synchronizing: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .needsAttention: "exclamationmark.circle.fill"
        }
    }
}

struct NodeStatusBadge: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var node: DeviceNode
    @EnvironmentObject private var wallet: WalletState
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let status = NodeHeaderStatus.current(enabled: node.enabled, offline: wallet.offlineMode,
                framework: DeviceNodeBridge.available, phase: node.phase, error: node.error,
                verifiedAt: node.verifiedAt, now: timeline.date)
            NavigationLink { DeviceNodeView() } label: {
                HStack(spacing: 6) {
                    // While the node verifies, the sync icon itself turns; there is no separate spinner.
                    NodeStatusSymbol(name: status.symbol, spinning: status == .synchronizing)
                    Text(status.rawValue)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status == .synced ? Theme.mint : status == .needsAttention ? Color.orange : Theme.secondary)
                .padding(.horizontal, Theme.world ? 16 : 10).padding(.vertical, Theme.world ? 10 : 7)
                .background { if Theme.world { WorldFrame(kind: .chip) } else { Capsule().fill(Theme.panel) } }
                .overlay { if !Theme.world { Capsule().stroke(Theme.line, lineWidth: 0.7) } }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("On-device node: \(status.rawValue). Open node details.")
        }
    }
}

/// The badge icon. Turns while the node synchronizes; holds still when Reduce Motion is on.
struct NodeStatusSymbol: View {
    let name: String
    let spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0
    var body: some View {
        Image(systemName: name)
            // Synced is a small solid green dot, not a full-size icon.
            .scaleEffect(name == "circle.fill" ? 0.6 : 1)
            .rotationEffect(.degrees(spinning && !reduceMotion ? angle : 0))
            .onAppear { update() }
            .onChange(of: spinning) { _, _ in update() }
            .onChange(of: reduceMotion) { _, _ in update() }
    }
    private func update() {
        if spinning && !reduceMotion {
            angle = 0
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.default) { angle = 0 }
        }
    }
}

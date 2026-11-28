import SwiftUI
import Charts
import UIKit

struct FreshnessView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var data: LiveData
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var node: DeviceNode
    @State private var details = false
    private func status(at date:Date)->String {
        if let saved=data.savedSnapshotDate {return "Saved snapshot · " + saved.formatted(date:.abbreviated,time:.shortened)}
        if wallet.offlineMode {return "Offline"}
        if data.refreshing {return "Refreshing…"}
        guard let updated=data.updated, (data.catalogHeight ?? 0) > 0 else {return "Native State not synchronized"}
        if let height=data.catalogHeight,let verified=node.verifiedHeight,verified>height,verified-height>10 {return "State snapshot behind phone"}
        if data.error != nil || date.timeIntervalSince(updated)>=30 {return "Data needs refreshing"}
        return "Verified State block \(data.catalogHeight.map { String($0) } ?? "—")"
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Button { details = true } label: {
                HStack(spacing: 6) {
                    Circle().fill((data.catalogHeight ?? 0) > 0 && (node.verifiedHeight ?? 0) <= (data.catalogHeight ?? 0) + 10 && data.updated != nil && data.error == nil && !wallet.offlineMode && context.date.timeIntervalSince(data.updated!) < 30 ? Theme.mint : Theme.secondary).frame(width: 4, height: 4)
                    Text(status(at:context.date))
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }.font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.vertical, 8)
            }.buttonStyle(.plain)
        }.sheet(isPresented: $details) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "Your data connection")
                    Text("Balances and NFTs shown from installed State are checked against this phone's accepted chain. Sending requires a fresh, exact transaction review.")
                        .foregroundStyle(Theme.secondary)
                    if let updated = data.updated { Text("Last updated: \(updated.formatted())").font(Theme.footnote) }
                    if let height=data.catalogHeight { Text("Native catalog block: \(height)").font(Theme.footnote) }
                    if let verified=node.verifiedHeight {
                        Text("Phone verified block: \(verified)").font(Theme.footnote)
                        if let catalog=data.catalogHeight, verified > catalog, verified - catalog > 10 {
                            Text("The holdings source is behind this phone's verified boundary. Recent tokens and NFTs may be missing until that source catches up.").font(Theme.footnote).foregroundStyle(.orange)
                        }
                    }
                    if let error = data.error { Text(error).font(Theme.footnote).foregroundStyle(.orange) }
                    NavigationLink("Network check") { NetworkStatusView() }
                    Spacer()
                }.padding(24).background(Theme.background).navigationTitle("Network").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { details = false } }
            }
        }
    }
}
struct NFTDetail: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let item:NativeItem
    @EnvironmentObject private var wallet:WalletState
    @AppStorage("externalMedia") private var externalMedia=true
    @State private var showReview=false
    @State private var fullScreen=false
    @State private var ask=""
    @State private var expiry=""
    @State private var recipient=""
    @State private var chooseContact=false
    @State private var scanRecipient=false
    @State private var recipientName:String?
    @State private var connectedAddress:String?
    @State private var selectedRequest:[String:Any]=[:]
    @State private var pendingWalletReservation=true
    @State private var thisNFTReserved=false
    /// Public edition: view and send only. No listing, purchase or offers.
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            UnavailableNotice(needs:[.backup,.online])
            AssetThumbnail(item:item,enabled:externalMedia && !wallet.offlineMode && !wallet.locked,allowsRetry:true)
                .onTapGesture { if externalMedia && !wallet.offlineMode && !wallet.locked { fullScreen=true } }
            if externalMedia && !wallet.offlineMode && !wallet.locked {Button {fullScreen=true} label:{Label(item.text("owner") == wallet.address || item.text("seller") == wallet.address ? "Full screen · save to Photos or wallpaper" : "View full screen",systemImage:"arrow.up.left.and.arrow.down.right")}.font(Theme.subheadline).foregroundStyle(Theme.mint)}
            if !externalMedia {
                Button {externalMedia=true} label:{ThemedLabel("Show artwork", systemImage: "photo")}.buttonStyle(ThemedButtonStyle()).tint(Theme.mint)
            }
            VStack(alignment:.leading,spacing:6) {
                CollectionNameLabel(id:item.collection).font(Theme.editorial(26))
                Text("NFT #"+item.text("serial")).font(Theme.subheadline).foregroundStyle(Theme.secondary)
            }
            if thisNFTReserved {
                Label("Transfer pending · locally reserved",systemImage:"clock.arrow.circlepath").font(Theme.headline).foregroundStyle(.orange)
            }
            if item.isListed(by:wallet.address) {
                HStack(spacing:8) {ListedBadge();Text("You listed this NFT. It can't be sent while it's listed.").font(Theme.caption).foregroundStyle(Theme.secondary)}
            }
            if item.text("owner")==wallet.address && item.text("seller").isEmpty {
                NavigationLink { SendView(initialAsset:item.id) } label: {ThemedLabel("Send this NFT", systemImage: "arrow.up.right").frame(maxWidth:.infinity)}
                    .buttonStyle(MintButtonStyle()).disabled(wallet.localWallet?.recoveryVerified != true || pendingWalletReservation)
                if pendingWalletReservation && !thisNFTReserved {
                    Text("Another transfer is pending. Sending opens again after it settles or expires.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment:.leading,spacing:14) {
                detailRow("Collection",item.collection)
                detailRow("Serial",item.text("serial"))
                if !item.text("owner").isEmpty {detailRow("Owner",item.text("owner"))}
                if !item.text("metadata_hash").isEmpty {detailRow("Metadata hash",item.text("metadata_hash"))}
            }.padding(16).themedCard(16)
        }.padding(22).frame(maxWidth:720).frame(maxWidth:.infinity) }
        .background(AmbientBackground()).navigationTitle("NFT").fullScreenCover(isPresented:$fullScreen) {NFTFullScreenView(item:item,canSave:item.text("owner") == wallet.address || item.text("seller") == wallet.address)}.navigationBarTitleDisplayMode(.inline)
        .task(id:"\(wallet.address)-\(wallet.locked)-\(item.collection)-\(item.text("serial"))") { await loadReservation() }
    }
    private func detailRow(_ title:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.secondary)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
    }
    private func loadReservation() async {
        guard !wallet.locked,let root=wallet.accounts.first(where:{$0.index==0})?.address else {
            pendingWalletReservation=true;thisNFTReserved=false;return
        }
        let owner=wallet.address
        do {
            let result=try await NativeCore.shared.call(["op":"payment_pending","journal_directory":PaymentStorage.directory(root:root).path])
            guard owner==wallet.address,!wallet.locked else{return}
            // Blocked only while a transaction reserves the whole wallet, or 20 are pending;
            // the planner itself skips anything another pending transaction uses.
            let open=PendingLedger.unresolved(result)
            pendingWalletReservation=open.count>=20 || open.contains { ($0["claims"] as? [String:Any])?["exclusive"] as? Bool == true }
            thisNFTReserved=PendingLedger.pendingNFTs(result).contains(item.collection+"#"+item.text("serial"))
        } catch {pendingWalletReservation=true;thisNFTReserved=false}
    }
}
struct OperationReview:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let request:[String:Any]
    var expectedSeller:String?=nil
    var offerExpiresAt:Date?=nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet:WalletState
    @EnvironmentObject private var data:LiveData
    @EnvironmentObject private var node:DeviceNode
    @Environment(\.scenePhase) private var phase
    @State private var checked:[String:Any]?
    @State private var operation:[String:Any]?
    @State private var reviewHash:String?
    @State private var configuration:GatewayConfiguration?
    @State private var reviewDeadline:ContinuousClock.Instant?
    @State private var generation=UUID()
    @State private var error:String?
    @State private var status:String?
    @State private var submittedID:String?
    @State private var working=false
    var body:some View {
        NavigationStack { ScrollView { VStack(alignment:.leading,spacing:20) {
            Text("Review exact terms").font(.title2.bold())
            if working { ProgressView { VStack(alignment: .leading, spacing: 3) { Text(node.paymentStage ?? "Verifying…"); Text("Keep the app open.").font(Theme.caption).foregroundStyle(Theme.secondary) } } }
            if let checked {
                if let approvedRequest=checked["request"] as? [String:Any] {
                    ForEach(approvedRequest.keys.sorted(),id:\.self) { key in
                        if let value=approvedRequest[key], !(value is NSNull) {
                            let action=approvedRequest["action"] as? String ?? ""
                            let label=key=="units" && action=="transfer_token" ? "Token amount" : key.replacingOccurrences(of:"_",with:" ")
                            LabeledContent(label,value:ReviewDisplay.requestValue(value,key:key,action:action))
                                .textSelection(.enabled)
                        }
                    }
                }
                ForEach(["seller","ask_micronoid","listing_expiry_height","asset_id","collection_id","serial","last_serial","noid_debit_micronoid","noid_credit_micronoid","fee_micronoid","fee_limit_micronoid","reserve_deposit_micronoid","initial_buy_cost_micronoid","redemption_micronoid","quoted_output","minimum_output","valid_until"],id:\.self) { key in
                    if let value=checked[key], !(value is NSNull) { VStack(alignment:.leading) { Text(ReviewDisplay.title(key)).font(Theme.caption).foregroundStyle(Theme.secondary);Text(ReviewDisplay.value(value,key:key)).font(.body.monospaced()).textSelection(.enabled) } }
                }
                Text("1 NOID = 1,000,000 micronoid. The native SDK checks the exact terms; the device node verifies the reviewed parent.").font(Theme.caption)
                TimelineView(.periodic(from:.now,by:1)) {_ in
                    if operation != nil && !reviewFresh {
                        Text("This review expired. Refresh the terms and review them again before approving.").font(.callout).foregroundStyle(Theme.secondary)
                        Button("Refresh terms"){Task{await prepare()}}.buttonStyle(MintButtonStyle()).disabled(working || wallet.locked || wallet.offlineMode)
                    } else {
                        Button("Authenticate and submit"){submit()}.buttonStyle(MintButtonStyle()).disabled(working || wallet.locked || wallet.offlineMode || operation==nil || !reviewFresh)
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.orange)
                if checked==nil {Button("Retry preparation"){Task{await prepare()}}.buttonStyle(MintButtonStyle()).disabled(working || wallet.locked || wallet.offlineMode)}
            }
            if let status {Text(status)}
            if let submittedID { TransactionExplorerLink(transactionID:submittedID) }
            Text("Submission is not confirmation. Pending authorization is retained across restarts. Open Send to retry identical bytes or verify final settlement.").font(Theme.footnote)
        }.padding(24) }.background(Theme.background).navigationTitle("Transaction review").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } } }
        .task {node.transactionFlowActive=true;await prepare()}
        .onChange(of:wallet.locked){_,locked in if locked{invalidate()}}
        .onChange(of:wallet.offlineMode){_,offline in if offline{invalidate()}}
        .onChange(of:wallet.address){_,_ in invalidate()}
        .onChange(of:phase){_,value in if value == .background{invalidate();error="Review was cleared while the app was in the background. Retry preparation to verify current terms."}}
        .onDisappear{node.transactionFlowActive=false;invalidate()}
    }
    private var reviewFresh:Bool {guard let deadline=reviewDeadline else{return false};return ContinuousClock().now<deadline && (offerExpiresAt.map{Date()<$0} ?? true)}
    private func invalidate(){generation=UUID();checked=nil;operation=nil;reviewHash=nil;configuration=nil;reviewDeadline=nil;working=false}
    private func active(_ token:UUID)->Bool{token==generation && !wallet.locked && !wallet.offlineMode && !Task.isCancelled}
    private func prepare() async {
        guard !working else{return}
        guard wallet.localWallet?.recoveryVerified == true else{error="Import a signing wallet and verify its backup before authorizing a transaction.";return}
        guard !wallet.offlineMode,!wallet.locked,!wallet.address.isEmpty else{error="Unlock and synchronize the wallet before reviewing an asset transaction.";return}
        let config=GatewayConfiguration.saved
        let token=generation;let owner=wallet.address;working=true;error=nil;status=nil;submittedID=nil;checked=nil;operation=nil;reviewHash=nil;configuration=nil;reviewDeadline=nil
        defer{if token==generation{working=false}}
        do {
            let identity=try DeviceNodeBridge.call(["op":"chain_identity"])
            guard let chain=identity["chain_id"] as? String,!chain.isEmpty else{throw AppFailure("Pinned chain identity unavailable.")}
            guard config == nil || config?.chainID == chain else{throw AppFailure("Gateway chain does not match the phone node.")}
            if let config {
                let protocolInfo=try await GatewayClient(config).query(["kind":"protocol"])
                guard protocolInfo["submission_enabled"] as? Bool == true else{throw AppFailure("This gateway has transaction submission disabled.")}
            }
            guard active(token) else{return}
            let verified=try await node.paymentOperation(["op":"verify_parent","expected_chain":chain])
            guard verified["chain_id"] as? String==chain,let parent=verified["verified_parent_hash"] as? String else{throw AppFailure("Device node returned no verified market parent.")}
            guard active(token) else{return}
            let plan:[String:Any]
            if let config {
                plan=try await GatewayClient(config).query(["kind":"plan","owner":owner,"parent":parent,"request":request])
            } else {
                guard let root=wallet.accounts.first(where:{$0.index==0})?.address else{throw AppFailure("Signing wallet unavailable.")}
                plan=try await node.paymentOperation(["op":"native_prepare","owner":owner,"account_index":wallet.selectedIndex,"expected_parent_hash":parent,"request":request,"journal_directory":PaymentStorage.directory(root:root).path])
            }
            guard plan["owner"] as? String==owner else{throw AppFailure("Plan belongs to another wallet.")}
            let input:[String:Any]=["native_plan":plan,"expected_request":request,"expected_chain":chain,"expected_parent_hash":parent,"maximum_fee_micronoid":"100000"]
            let response=try await NativeCore.shared.call(["op":"review","operation":input])
            guard active(token) else{return}
            guard wallet.address==owner,GatewayConfiguration.saved==config else{throw AppFailure("Wallet or gateway settings changed. Retry preparation with the current settings.")}
            guard let review=response["review"] as? [String:Any],let hash=response["review_hash"] as? String,!hash.isEmpty else{throw AppFailure("The native verifier returned an incomplete review. No authorization was started. Retry preparation.")}
            if let expectedSeller,review["seller"] as? String != expectedSeller {throw AppFailure("The verified seller differs from the NFT you selected. Refresh and review again.")}
            guard offerExpiresAt.map({Date()<$0}) ?? true else{throw AppFailure("The private offer expired. Agree on new terms before buying.")}
            checked=review;operation=input;reviewHash=hash;configuration=config;reviewDeadline=ContinuousClock().now.advanced(by:.seconds(60))
        }catch{if active(token){self.error=error.localizedDescription}}
    }
    private func submit() {
        guard !working,reviewFresh,let operation,let hash=reviewHash,let plan=operation["native_plan"] as? [String:Any],let id=plan["intent_id"] as? String else{return}
        let config=configuration
        let token=generation;working=true;error=nil
        Task { @MainActor in
            defer{if token==generation{working=false}}
            do {
                let context=try await wallet.requireAuthentication("Authorize the reviewed market transaction",fresh:true)
                guard active(token) else{return}
                guard GatewayConfiguration.saved==config else{throw AppFailure("Gateway settings changed. Close this review and prepare it again.")}
                guard reviewFresh else{throw AppFailure("Review expired. Refresh the terms before approving.")}
                guard let parent=operation["expected_parent_hash"] as? String else{throw AppFailure("Missing verified parent. Review again.")}
                guard let chain=operation["expected_chain"] as? String else{throw AppFailure("Missing pinned chain. Review again.")}
                _=try await node.paymentOperation(["op":"verify_parent","expected_chain":chain,"expected_parent_hash":parent])
                guard active(token),GatewayConfiguration.saved==config,reviewFresh else{throw AppFailure("The review changed or expired during the final chain check. Refresh terms.")}
                // Once authorization starts, do not offer a new authorization
                // from this screen: the durable journal owns retries thereafter.
                // Optional second confirmation on the paired Apple Watch (before anything is signed).
                try await WatchBridge.shared.confirmOnWatchIfRequired(title:"Approve this token or NFT transaction",recipient:operation["to"] as? String ?? "",amount:nil,fee:Amounts.format(checked?["fee_micronoid"] as? String ?? ""))
                guard active(token) else{return}
                self.operation=nil
                let signed=try await WalletVault.shared.authorizeNative(["operation":operation,"approved_review_hash":hash],context:context)
                guard active(token) else{return}
                guard signed["txid"] as? String==id,let intent=signed["intent_hex"] as? String,!intent.isEmpty else{throw AppFailure("The signing result did not match the reviewed transaction. Nothing was submitted from this screen. Check saved authorization in Send before retrying.")}
                self.operation=nil
                guard let root=wallet.accounts.first(where:{$0.index==0})?.address else{throw AppFailure("Signing wallet unavailable. Saved authorization retained in Send.")}
                let submitted=try await node.paymentOperation(["op":"native_submit","expected_txid":id,"journal_directory":PaymentStorage.directory(root:root).path])
                guard active(token) else{return}
                guard submitted["txid"] as? String==id else{throw AppFailure("Submission identity mismatch. Saved authorization retained; check settlement before retrying.")}
                if let root=wallet.accounts.first(where:{$0.index==0})?.address {
                    let action=request["action"] as? String ?? ""
                    let kind=action == "transfer_nft" ? "NFT sent" : action == "transfer_token" ? "Token sent" : "Native asset transaction"
                    try? await LocalPaymentHistory.shared.record(root:root,owner:wallet.address,id:id,kind:kind,
                        recipient:request["recipient"] as? String,assetID:request["asset_id"] as? String,
                        collectionID:request["collection_id"] as? String,serial:request["serial"] as? String,
                        status:"Submitted · settlement not verified")
                }
                submittedID=id
                status="Submitted. Final settlement has not yet been verified."
            }catch{if active(token){self.error=error.localizedDescription+(self.operation==nil ? " Any saved authorization remains available in Send." : " No authorization was started.")}}
        }
    }
}

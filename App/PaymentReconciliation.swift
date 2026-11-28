import Foundation

/// Releases only the matching journal authorization after native settlement verification.
@MainActor enum PaymentReconciliation {
    static let changed = Notification.Name("PaymentJournalReconciled")
    private static var checking=false
    private static var lastCheck=Date.distantPast
    private static var lastExpiryCheck=Date.distantPast
    private static var lastCheckedRoot=""
    private static var lastCheckedHeight:UInt64?
    private static var lastExpiryID=""
    private static var lastExpiryHeight:UInt64?
    private static var lastDeliveryID=""
    private static var lastDeliveryAttempt=Date.distantPast
    static func refreshPending(root:String,node:DeviceNode) async {
        let height=node.verifiedHeight
        guard !checking,!node.running,node.enabled,
              root != lastCheckedRoot || height != lastCheckedHeight || Date().timeIntervalSince(lastCheck)>=20 else{return}
        checking=true;lastCheck=Date();lastCheckedRoot=root;lastCheckedHeight=height;defer{checking=false}
        do {
            let directory=try PaymentStorage.directory(root:root).path
            let result=try await NativeCore.shared.call(["op":"payment_pending","journal_directory":directory])
            // Every unsettled payment is reconciled on its own; one outage never blocks the others.
            let authorized=PendingLedger.entries(result).filter { $0["state"] as? String == "authorized" }
            for pending in authorized {
                guard let id=pending["txid"] as? String else{continue}
                await reconcile(pending:pending,id:id,root:root,directory:directory,node:node,height:height)
            }
        }catch { /* Keep the reservation; a later sync or manual check can retry. */ }
    }
    private static func reconcile(pending:[String:Any],id:String,root:String,directory:String,node:DeviceNode,height:UInt64?) async {
        do {
            // A verified boundary may already be far beyond the saved intent's
            // epoch while the public RPC has pruned its block body. Let the
            // native verifier test the signed anchor and finality first. It
            // releases the reservation with settlement status unknown, never
            // with an unsupported claim of payment failure or confirmation.
            if height != nil,
               await releaseAfterVerifiedExpiry(id:id,directory:directory,node:node) {return}
            let receipt:VerifiedReceipt?
            let hex:String?
            do {
                let (_,checked,supplied)=try await node.fetchSettlement(transactionID:id)
                receipt=checked;hex=supplied
            }
            catch {
                // A receipt service outage cannot strand an expired authorization.
                // The independent phone verifier still decides whether expiry is safe.
                _ = await releaseAfterVerifiedExpiry(id:id,directory:directory,node:node)
                return
            }
            if let receipt,receipt.finalized,let hex {
                _ = try await apply(receipt:receipt,hex:hex,root:root,node:node)
            } else if receipt != nil {
                try? await LocalPaymentHistory.shared.verifiedStatus(root:root,id:id,status:"Included · awaiting finality (verified on phone)")
            } else if receipt == nil {
                let released = await releaseAfterVerifiedExpiry(id:id,directory:directory,node:node)
                guard !released else{return}
                // The journal alone authorizes this exact signed NOID intent.
                // A restored network connection can retry its bytes without
                // asking the signer to approve a different payment.
                if pending["offline_delivery"] as? Bool == true,
                   pending["operation_kind"] as? String == "ordinary",
                   let intent=pending["intent_hex"] as? String,
                   lastDeliveryID != id || Date().timeIntervalSince(lastDeliveryAttempt)>=60 {
                    lastDeliveryID=id;lastDeliveryAttempt=Date()
                    let submitted=try? await node.paymentOperation(["op":"broadcast_send","intent_hex":intent,"txid":id])
                    if submitted?["txid"] as? String == id {
                        NotificationCenter.default.post(name:changed,object:nil)
                    }
                }
            }
            if let receipt,let owner=pending["owner"] as? String,
               node.balance(for:owner) != nil,let amount=node.balanceMicronoid,
               let balanceHeight=node.balanceHeight {
                try? await LocalPaymentHistory.shared.recordBalanceAtVerification(root:root,owner:owner,id:id,transactionHeight:receipt.height,balanceHeight:balanceHeight,micronoid:amount)
            }
        }catch { /* Keep the reservation; a later sync or manual check can retry. */ }
    }
    @discardableResult static func releaseAfterVerifiedExpiry(id:String,directory:String,node:DeviceNode,force:Bool=false) async -> Bool {
        let height=node.verifiedHeight
        let newBoundary=height != nil && (id != lastExpiryID || height != lastExpiryHeight)
        guard !node.running,(force || (newBoundary && Date().timeIntervalSince(lastExpiryCheck)>=30) || id != lastExpiryID || Date().timeIntervalSince(lastExpiryCheck)>=60) else{return false}
        // An inaccessible receipt is not proof of failure. Only a verified
        // finalized boundary beyond the signed epoch may release the journal.
        lastExpiryCheck=Date();lastExpiryID=id;lastExpiryHeight=height
        let expired = try? await node.paymentOperation(["op":"expire_payment","expected_txid":id,"journal_directory":directory])
        if expired?["reservation_released"] as? Bool == true {
            NotificationCenter.default.post(name:changed,object:nil)
            return true
        }
        return false
    }
    static func apply(receipt: VerifiedReceipt, hex: String, root: String, node: DeviceNode) async throws -> Bool {
        guard receipt.finalized else { return false }
        let normalized=try ReceiptInput(hex:hex,transactionID:receipt.transactionID)
        let directory = try PaymentStorage.directory(root:root).path
        let result = try await NativeCore.shared.call(["op":"payment_pending","journal_directory":directory])
        guard PendingLedger.entries(result).contains(where: { $0["txid"] as? String == receipt.transactionID && $0["state"] as? String == "authorized" }) else {return false}
        _ = try await node.paymentOperation(["op":"settle_payment","receipt_hex":normalized.hex,"expected_txid":receipt.transactionID,"journal_directory":directory])
        try? await LocalPaymentHistory.shared.verifiedStatus(root:root,id:receipt.transactionID,status:"Finalized · verified on phone")
        WalletActivityNotifications.finalizedSend(txid:receipt.transactionID)
        NotificationCenter.default.post(name:changed,object:nil)
        NotificationCenter.default.post(name:LocalPaymentHistory.changed,object:nil)
        return true
    }
}

/// Reads the wallet's payment ledger (build 165): every unsettled transaction plus
/// recent settled ones. Falls back to the single "pending" record from older cores.
enum PendingLedger {
    static func entries(_ result:[String:Any]) -> [[String:Any]] {
        if let list=result["entries"] as? [[String:Any]] { return list }
        if let one=result["pending"] as? [String:Any] { return [one] }
        return []
    }
    static func unresolved(_ result:[String:Any]) -> [[String:Any]] {
        entries(result).filter { ["preparing","authorized"].contains($0["state"] as? String ?? "") }
    }
    /// Micronoid held by unsettled NOID payments (amount plus fee), for the balance display.
    static func reservedMicronoid(_ result:[String:Any]) -> UInt64 {
        unresolved(result).reduce(UInt64(0)) { sum, entry in
            let value=UInt64(entry["local_reserved_total"] as? String ?? "") ?? UInt64(entry["local_fee"] as? String ?? "") ?? 0
            let (total,overflow)=sum.addingReportingOverflow(value); return overflow ? sum : total
        }
    }
    /// Collection and serial of NFTs a pending token/NFT operation is using (shown greyed out).
    static func pendingNFTs(_ result:[String:Any]) -> Set<String> {
        Set(unresolved(result).compactMap { entry -> String? in
            guard let request=entry["local_native_request"] as? [String:Any],
                  let collection=request["collection_id"] as? String,
                  let serial=(request["serial"] as? String) ?? (request["serial"] as? NSNumber)?.stringValue else { return nil }
            return collection+"#"+serial
        })
    }
}

/// Plain-language lines for a pending ledger entry.
enum PendingText {
    static func title(_ entry:[String:Any]) -> String {
        if entry["operation_kind"] as? String == "native" || entry["local_native_request"] != nil {
            let request=entry["local_native_request"] as? [String:Any]
            let action=(request?["action"] as? String ?? "asset operation").replacingOccurrences(of:"_",with:" ")
            if let serial=(request?["serial"] as? String) ?? (request?["serial"] as? NSNumber)?.stringValue { return action.capitalized+" · NFT #"+serial }
            return action.capitalized
        }
        if let raw=entry["local_amount"] as? String,let amount=Amounts.format(raw) { return amount+" NOID" }
        return "NOID payment"
    }
    static func detail(_ entry:[String:Any]) -> String {
        var parts:[String]=[]
        if let to=entry["recipient"] as? String { parts.append("To "+String(to.prefix(10))+"…"+String(to.suffix(6))) }
        if let raw=entry["local_fee"] as? String,let fee=Amounts.format(raw) { parts.append("fee "+fee) }
        if entry["offline_delivery"] as? Bool == true { parts.append("waiting to send") }
        return parts.isEmpty ? "Reserved until it settles" : parts.joined(separator:" · ")
    }
}

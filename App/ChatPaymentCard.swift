import SwiftUI

/// Display state is created only from a native-verified/decrypted message.
/// A signed claim is not treated as blockchain settlement.
struct ChatPaymentPreview {
    enum Kind: Equatable { case request, authorization, receipt }
    let kind: Kind
    let amount: String?
    let address: String?
    let transactionID: String?
    let invoiceID: String?
    let receipt: String?
    let note: String
    init?(_ result: [String:Any]) {
        if let invoice = result["invoice"] as? [String:Any], let destination = invoice["address"] as? String,
           AddressValidator.valid(destination), let amount = invoice["amount"] as? String,
           let raw = Amounts.parse(amount), let units = UInt64(raw), units > 0 {
            kind = .request; self.amount = Amounts.format(raw); address = destination
            transactionID = nil; invoiceID = invoice["invoice_id"] as? String
            receipt = nil; note = String((invoice["memo"] as? String ?? "").prefix(256))
        } else if let update = result["relay_update"] as? [String:Any], let id = update["txid"] as? String, SharedAvatar.hex(id) {
            kind = .receipt; amount = nil; address = nil; transactionID = id; invoiceID = nil
            receipt = (update["receipt_hex"] as? String).flatMap { try? ReceiptInput(hex:$0,transactionID:id).hex }
            note = "Peer-reported status. Verify the receipt on this phone."
        } else if let payment = result["payment"] as? [String:Any], payment["authorized"] as? Bool == true,
                  let id = payment["txid"] as? String, SharedAvatar.hex(id) {
            kind = .authorization; amount = nil; address = nil; transactionID = id; invoiceID = nil; receipt = nil
            note = "Signed authorization received. Network acceptance and settlement are not yet confirmed."
        } else { return nil }
    }
    var title: String {
        switch kind { case .request: return "Payment request"; case .authorization: return "Payment authorization"; case .receipt: return "Payment receipt" }
    }
}

struct ChatPaymentCard: View {
    let payment: ChatPaymentPreview
    var outgoing = false
    var canceled = false
    @EnvironmentObject private var wallet: WalletState
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(canceled ? "Payment request canceled" : payment.title,systemImage:payment.kind == .request ? "arrow.down.left.circle" : "doc.text.magnifyingglass")
                .font(Theme.headline).foregroundStyle(Theme.mint)
            if let amount = payment.amount { Text(amount + " NOID").font(Theme.editorial(28)).privacySensitive() }
            if let address = payment.address {
                SaveableAddress(address:address,prefix:"To ")
                if !outgoing && !canceled, let amount = payment.amount {
                    NavigationLink { SendView(initialRecipient:address,initialAmount:amount) } label: { ThemedLabel("Review payment", systemImage: "arrow.up.right") }
                        .buttonStyle(ThemedButtonStyle(prominent: true)).disabled(wallet.localWallet?.recoveryVerified != true)
                }
            }
            if let id = payment.transactionID {
                Text(String(id.prefix(12)) + "…" + String(id.suffix(8))).font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                NavigationLink { ReceiptVerificationView(transactionID:id,suppliedReceipt:payment.receipt ?? "") } label: { ThemedLabel("Verify receipt", systemImage: "checkmark.shield") }
                    .buttonStyle(ThemedButtonStyle())
            }
            if !payment.note.isEmpty { Text(payment.note).font(Theme.caption).foregroundStyle(Theme.secondary) }
            if payment.kind == .request { Text(canceled ? "The sender withdrew this request in chat. A payment already authorized separately cannot be recalled." : "Opening review never sends funds.").font(Theme.caption2).foregroundStyle(Theme.secondary) }
        }.padding(16).frame(maxWidth:330,alignment:.leading)
            .themedCard(18)
            .themedOutline(18, Theme.mint.opacity(0.45), 1)
    }
}

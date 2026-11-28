import SwiftUI

/// A public-room policy, not a claim of traffic anonymity or VPN protection.
enum ChatPrivacy {
    static let storageKey="chat.paranoidMode.v1"
    static var enabled:Bool {UserDefaults.standard.bool(forKey:storageKey)}
}
struct ChatConnectionBar:View {
    @AppStorage(ChatPrivacy.storageKey) private var paranoid=false
    @EnvironmentObject private var wallet:WalletState
    @EnvironmentObject private var nearby:NearbyTransport
    var body:some View {
        HStack(spacing:12) {
            NavigationLink { NetworkStatusView() } label: {
                Label(wallet.offlineMode ? "Offline" : "Connections",systemImage:"network")
            }.accessibilityLabel("Connection status")
            Spacer(minLength:4)
            Text(Edition.isPublic ? (nearby.enabled ? "\(nearby.links) nearby" : "Nearby relay off") : paranoid ? "Private only" : "\(nearby.links) nearby")
                .foregroundStyle(Theme.secondary).lineLimit(1)
            NavigationLink { ChatDeliverySettingsView() } label: {
                Image(systemName:"slider.horizontal.3").frame(minWidth:32,minHeight:32)
            }.accessibilityLabel("Chat privacy and delivery settings")
        }.font(Theme.caption).foregroundStyle(Theme.mint)
            .padding(.horizontal,16).padding(.vertical,6)
    }
}
struct EmojiPicker:View {
    @Binding var text:String
    var body:some View {
        Menu {
            ForEach(["😀","😂","❤️","👍","🙏","🔥","🎉","🚀","👀","🤝","💚","💸"],id:\.self) {emoji in
                Button(emoji) {if (text+emoji).utf8.count <= 4096 {text += emoji}}
            }
        } label: {ThemedLabel("Emoji", systemImage: "face.smiling").frame(minHeight:44)}
        .buttonStyle(ThemedButtonStyle()).accessibilityLabel("Add emoji to message")
    }
}
struct PublicPaymentUpdate {
    let transactionID:String
    let claimedStage:String
    let receipt:String
    init?(_ object:[String:Any]?) {
        guard let object,let id=object["txid"] as? String,id.count==64,Data(hex:id)?.count==32,
              let stage=object["claimed_stage"] as? String else{return nil}
        transactionID=id.lowercased();claimedStage=stage
        // Validate before accepting a supplied receipt into the editor.
        if let raw=object["receipt_hex"] as? String,let input=try? ReceiptInput(hex:raw,transactionID:id) {receipt=input.hex}
        else {receipt=""}
    }
}
struct PublicPaymentCard:View {
    let update:PublicPaymentUpdate
    var body:some View {
        Panel {
            Label("Payment update · unverified",systemImage:"doc.text.magnifyingglass").font(Theme.headline)
            Text("Sender reports: \(update.claimedStage)").font(Theme.caption)
            Text(update.transactionID).font(.caption.monospaced()).textSelection(.enabled)
            Text("A signed message identifies its sender; it does not prove settlement. Check this transaction against the phone’s verified chain.").font(Theme.caption).foregroundStyle(Theme.secondary)
            NavigationLink {
                ReceiptVerificationView(transactionID:update.transactionID,suppliedReceipt:update.receipt)
            } label: {ThemedLabel("Verify payment receipt", systemImage: "checkmark.shield")}
            .buttonStyle(MintButtonStyle())
        }
    }
}

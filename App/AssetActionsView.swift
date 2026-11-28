import SwiftUI

struct AssetActionsView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    var item:NativeItem?=nil
    @EnvironmentObject private var data:LiveData
    var body:some View {
        List {
            if let item, item.type == "nft" {
                NavigationLink {NFTDetail(item:item)} label: {ThemedLabel("View NFT", systemImage: "square.stack")}
            } else if let item {
                Section {
                    LabeledContent("Balance",value:Amounts.format(item.text("units")) ?? "—")
                    VStack(alignment:.leading,spacing:4) {
                        Text("Asset ID").font(Theme.caption).foregroundStyle(Theme.secondary)
                        Text(item.asset).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.themedRow()
                Section {
                    NavigationLink {SendView(initialAsset:item.id)} label: {ThemedLabel("Send token", systemImage: "arrow.up.right")}
                }.themedRow()
            } else {
                Section {
                    NavigationLink {SendView()} label: {ThemedLabel("Send NOID", systemImage: "arrow.up.right")}
                    NavigationLink {ReceiptLookupView(scope:.all)} label: {ThemedLabel("Receipts", systemImage: "checkmark.shield")}
                } footer: {Text("To receive NOID, tap Receive on Home and share your address or QR code.")}.themedRow()
            }
        }.modifier(WalletSettingsSurface()).navigationTitle(item == nil ? "NOID" : "Token")
    }
}

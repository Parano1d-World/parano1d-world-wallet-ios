import SwiftUI

extension NativeItem {
    var sendSelectionID:String {type == "nft" ? "nft:"+nftDisplayID : "token:"+asset}
}
struct SendAssetPicker:View {
    let items:[NativeItem]
    let names:[String:String]
    let noidBalance:String?
    @Binding var selection:String
    var kind:SendAssetKind = .token
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet:WalletState
    @AppStorage("externalMedia") private var artwork=true
    @State private var query=""
    @EnvironmentObject private var data:LiveData
    @AppStorage("nft.collectionNames.v1") private var collectionNameData=Data()
    private var collectionNames:[String:String] {(try? JSONDecoder().decode([String:String].self,from:collectionNameData)) ?? [:]}
    private func collectionName(_ item:NativeItem)->String {CollectionPresentation.name(id:item.collection,collections:data.collections,names:collectionNames)}
    private var matching:[NativeItem] {
        items.filter {query.isEmpty || $0.asset.localizedCaseInsensitiveContains(query) || $0.collection.localizedCaseInsensitiveContains(query) || $0.text("serial").contains(query) || collectionName($0).localizedCaseInsensitiveContains(query) || (names[$0.asset]?.localizedCaseInsensitiveContains(query) ?? false)}
    }
    var body:some View {
        List {
            if kind == .noid { Section("NOID") {
                Button {choose("NOID")} label: {
                    HStack {
                        Image("NOIDCoin").resizable().scaledToFit().frame(width:40,height:40)
                        VStack(alignment:.leading,spacing:5) {
                            Text("NOID").font(Theme.headline)
                            Text(noidBalance.map {wallet.amount($0+" NOID")} ?? "Balance awaiting verification").font(Theme.subheadline)
                        }
                        Spacer();if selection == "NOID" {Image(systemName:"checkmark.circle.fill").foregroundStyle(Theme.mint)}
                    }.padding(.vertical,8)
                }.buttonStyle(.plain)
            }.themedRow() }
            if kind == .token { Section("Native tokens") {
                ForEach(matching.filter{$0.type == "token"},id:\.sendSelectionID) {item in
                    Button {choose(item.sendSelectionID)} label: {
                        HStack(spacing:12) {
                            AssetSelectionIcon(item:item)
                            VStack(alignment:.leading,spacing:6) {
                                Text(names[item.asset] ?? "Native token").font(Theme.headline)
                                Text(wallet.amount(Amounts.format(item.text("units")) ?? "—")).font(Theme.subheadline)
                                Text(item.asset).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer();if selection == item.sendSelectionID {Image(systemName:"checkmark.circle.fill")}
                        }.padding(.vertical,8)
                    }.buttonStyle(.plain)
                }
                if matching.filter({$0.type == "token"}).isEmpty {Text(data.refreshing ? "Loading token holdings…" : "No matching tokens in your loaded holdings. Pull down to refresh.").font(Theme.caption).foregroundStyle(Theme.secondary)}
            }.themedRow() }
            if kind == .nft { Section("Your NFTs") {
                ForEach(matching.filter{$0.type == "nft"},id:\.sendSelectionID) {item in
                    Button {choose(item.sendSelectionID)} label: {
                        HStack(spacing:14) {
                            AssetThumbnail(item:item,enabled:artwork && !wallet.offlineMode && !wallet.locked,showsTitle:false).frame(width:64)
                            VStack(alignment:.leading,spacing:6) {
                                CollectionNameLabel(id:item.collection).font(Theme.headline)
                                Text("NFT #"+item.text("serial")).font(Theme.caption)
                                Text(item.collection).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                            }
                            Spacer();if selection == item.sendSelectionID {Image(systemName:"checkmark.circle.fill")}
                        }.padding(.vertical,6)
                    }.buttonStyle(.plain)
                }
                if matching.filter({$0.type == "nft"}).isEmpty {Text(data.refreshing ? "Loading NFT holdings…" : "No matching NFTs in your loaded holdings. Pull down to refresh. Listed NFTs must be released from their listing before transfer.").font(Theme.caption).foregroundStyle(Theme.secondary)}
            }.themedRow() }
            if let issue=data.error {Section("Holdings connection") {Text(issue).font(Theme.caption).foregroundStyle(.orange)}.themedRow()}
        }.searchable(text:$query,prompt:"Token name, collection ID or NFT number")
            .refreshable {await data.refreshAndWait(owner:wallet.address,offline:wallet.offlineMode)}
            .scrollContentBackground(.hidden).background(AmbientBackground()).foregroundStyle(Theme.text)
            .navigationTitle("Choose asset").keyboardDismissControl().navigationBarTitleDisplayMode(.inline)
    }
    private func choose(_ id:String) {selection=id;dismiss()}
}

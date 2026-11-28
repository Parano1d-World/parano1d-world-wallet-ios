import SwiftUI

/// Explicit address lookup against local verified State. It does not publish
/// the contact book, infer consent to offers, or query a third-party explorer.
struct ContactNFTGallery:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet:WalletState
    @EnvironmentObject private var data:LiveData
    @EnvironmentObject private var node:DeviceNode
    @AppStorage("externalMedia") private var artwork=true
    @State private var contact:ConnectedContact?
    @State private var choose=false
    @State private var items:[NativeItem]=[]
    @State private var height:UInt64?
    @State private var error:String?
    @State private var loading=false
    @State private var generation=UUID()
    var body:some View {
        List {
            Section {
                Button(contact.map{"Change contact · "+$0.name} ?? "Choose connected contact") {choose=true}
                if let contact {Text(contact.address).font(.caption.monospaced()).textSelection(.enabled)}
                Text("Reads the saved address's NFT holdings from this phone's verified State. This is not proof that the contact controls the address.").font(Theme.caption)
                if let height {Text("Holdings snapshot · block \(height)").font(Theme.caption)}
                if let height,let tip=node.verifiedHeight,tip>height,tip-height>10 {
                    Text("This snapshot is behind the current chain; ownership may have changed.").font(Theme.caption).foregroundStyle(.orange)
                }
            }.themedRow()
            if loading {ProgressView("Loading collection…")}
            if let error {Text(error).foregroundStyle(.orange);Button("Retry"){Task{await refresh()}}}
            ForEach(items) {item in
                NavigationLink {NFTDetail(item:item)} label:{
                    HStack {
                        AssetThumbnail(item:item,enabled:artwork && !wallet.offlineMode && !wallet.locked).frame(width:90)
                        VStack(alignment:.leading) {
                            Text("NFT #"+item.text("serial"))
                            CollectionNameLabel(id:item.collection).font(Theme.caption).lineLimit(1)
                            Text("Holding").font(Theme.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            if contact != nil,!loading,error==nil,height != nil,items.isEmpty {
                Text("No unlisted NFTs were found for this address at the installed snapshot.")
            }
        }.navigationTitle("Contact collection")
            .sheet(isPresented:$choose){NavigationStack{ConnectedContactsView(select:{selected in contact=selected;choose=false})}}
            .task(id:contact?.id){await refresh()}
            .onChange(of:wallet.locked){_,locked in if locked{generation=UUID();contact=nil;items=[];height=nil;error=nil;loading=false;choose=false}}
            .onChange(of:wallet.address){_,_ in generation=UUID();contact=nil;items=[];height=nil;error=nil;loading=false}
            .refreshable{await refresh()}
    }
    private func refresh() async {
        let token=UUID();generation=token;items=[];height=nil;error=nil
        guard let selected=contact,!wallet.locked else{loading=false;return}
        loading=true
        defer{if token==generation{loading=false}}
        do {
            let snapshot=try await data.localHoldings(owner:selected.address)
            guard token==generation,!Task.isCancelled,!wallet.locked,contact?.id==selected.id else{return}
            items=snapshot.items.filter{$0.type=="nft" && $0.text("owner")==selected.address}
            height=snapshot.height
        }catch {if token==generation,!wallet.locked,!Task.isCancelled{self.error=error.localizedDescription}}
    }
}

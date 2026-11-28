import SwiftUI

/// Gallery presentation only. Marketplace routes live under More.
struct NFTGalleryDetail:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let item:NativeItem
    @EnvironmentObject private var wallet:WalletState
    @AppStorage("externalMedia") private var externalMedia=true
    @State private var fullScreen=false
    private var owned:Bool {item.text("owner") == wallet.address || item.text("seller") == wallet.address}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                AssetThumbnail(item:item,enabled:externalMedia && !wallet.offlineMode && !wallet.locked,allowsRetry:true)
                    .onTapGesture { if externalMedia && !wallet.offlineMode && !wallet.locked { fullScreen=true } }
                    .accessibilityHint("Opens the artwork full screen")
                if externalMedia && !wallet.offlineMode && !wallet.locked {
                    Button { fullScreen=true } label: {
                        Label(owned ? "Full screen · save to Photos or wallpaper" : "View full screen",systemImage:"arrow.up.left.and.arrow.down.right")
                    }.font(Theme.subheadline).foregroundStyle(Theme.mint)
                }
                if !externalMedia {
                    Button("Show NFT artwork") { externalMedia=true }
                    Text("Loads hash-checked artwork from the media service.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                // Collection and serial under the title (the title above already names the NFT).
                HStack(spacing: 6) {
                    CollectionNameLabel(id:item.collection)
                    if !item.text("serial").isEmpty { Text("· Serial #" + item.text("serial")) }
                }.font(Theme.subheadline).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if item.text("owner") == wallet.address && item.text("seller").isEmpty {
                    NavigationLink { SendView(initialAsset:item.id) } label: {
                        ThemedLabel("Send this NFT", systemImage: "arrow.up.right").frame(maxWidth:.infinity)
                    }.buttonStyle(MintButtonStyle())
                }
                VStack(alignment:.leading,spacing:14) {
                    detailRow("Collection ID", item.collection)
                    detailRow(item.text("seller").isEmpty ? "Owner" : "Seller · listed snapshot", item.text("seller").isEmpty ? item.text("owner") : item.text("seller"))
                    if !item.text("metadata_hash").isEmpty { detailRow("Metadata hash", item.text("metadata_hash")) }
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).themedCard(16)
            }.padding(22).frame(maxWidth:720).frame(maxWidth:.infinity)
        }.background(AmbientBackground()).navigationTitle("NFT").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented:$fullScreen) {NFTFullScreenView(item:item,canSave:owned)}
    }
    /// A labelled ID: one line each end, shortened in the middle, selectable to copy.
    private func detailRow(_ title:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.secondary)
            Text(value).font(.footnote.monospaced()).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

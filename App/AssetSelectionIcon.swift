import SwiftUI

struct AssetSelectionIcon: View {
    var item: NativeItem? = nil // nil is the native NOID coin, never another token
    var size: CGFloat = 48
    @AppStorage("externalMedia") private var artwork=true
    @EnvironmentObject private var wallet:WalletState
    var body:some View {
        Group {
            if let item {
                AssetThumbnail(item:item,enabled:artwork && !wallet.offlineMode && !wallet.locked,showsTitle:false)
            } else {
                Image("NOIDCoin").resizable().scaledToFit().padding(5)
            }
        }.frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:12))
    }
}

/// Validated on-chain metadata image, with a neutral fallback when unavailable.
struct AssetRowIcon: View {
    let item: NativeItem
    var size: CGFloat = 48
    let enabled: Bool
    var allowNetwork = true
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFill() }
            else { Image(systemName:item.type == "nft" ? "square.stack.3d.up" : "circle.hexagongrid")
                    .font(.system(size:size * 0.42)).foregroundStyle(Theme.mint)
                    .frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.soft) }
        }.frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:12))
            .task(id:"\(enabled)-\(allowNetwork)-\(item.text("metadata_hash"))") {
                image=nil
                guard enabled else{return}
                let hash=item.text("metadata_hash")
                let loaded:AssetDisplay?
                if allowNetwork {loaded=try? await AssetMedia.shared.load(hash:hash)}
                else {loaded=try? await AssetMedia.shared.loadCached(hash:hash)}
                if !Task.isCancelled {image=loaded?.image}
            }
    }
}

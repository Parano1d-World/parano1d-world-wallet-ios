import SwiftUI

struct CollectionsView: View {
    @AppStorage(DisplayStyle.storageKey) private var appearance = "system"
    @EnvironmentObject private var data: LiveData
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var node: DeviceNode
    @Environment(\.dynamicTypeSize) private var textSize
    @AppStorage("externalMedia") private var artwork = true
    @AppStorage("nft.gallery.grid") private var grid = true
    @AppStorage("nft.gallery.columns") private var gridColumns = 2
    @AppStorage("nft.collectionNames.v1") private var rawNames = Data()
    @State private var selected = ""
    init(initialCollection:String = "") { _selected = State(initialValue:initialCollection) }
    @State private var search = ""
    @State private var pendingNativeRequest:[String:Any]?
    @State private var reservationChecked=false
    /// Every NFT used by a pending transfer (several can be pending at once).
    @State private var pendingNFTKeys:Set<String>=[]
    private enum Destination: String, Identifiable { case more, sync; var id:String {rawValue} }
    @State private var destination: Destination?
    private var names: [String:String] { (try? JSONDecoder().decode([String:String].self, from: rawNames)) ?? [:] }
    private func name(_ id: String) -> String { CollectionPresentation.name(id: id, collections: data.collections, names: names) }
    private var owned: [NativeItem] {
        var result: [String:NativeItem] = [:]
        for item in data.holdings where item.type == "nft" && item.text("owner") == wallet.address && !item.collection.isEmpty { result[item.nftDisplayID] = item }
        for item in data.listings where item.text("seller") == wallet.address && !item.collection.isEmpty { result[item.nftDisplayID] = item }
        // Listed NFTs always sit beneath the ones still in your wallet.
        return result.values.sorted {
            let a = $0.isListed(by: wallet.address), b = $1.isListed(by: wallet.address)
            return a != b ? !a : $0.nftDisplayID.localizedStandardCompare($1.nftDisplayID) == .orderedAscending
        }
    }
    private var ids: [String] {
        Set(owned.map(\.collection)).filter { CollectionSearch.matches(query: search, name: name($0), id: $0) }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
    private var items: [NativeItem] {
        owned.filter { $0.collection == selected && (search.isEmpty || $0.text("serial").localizedCaseInsensitiveContains(search) || CollectionSearch.matches(query: search, name: name(selected), id: selected)) }
    }
    private var columns: [GridItem] {
        let count=grid && !textSize.isAccessibilitySize ? (selected.isEmpty ? 2 : min(4,max(2,gridColumns))) : 1
        return Array(repeating:GridItem(.flexible(),spacing:12),count:count)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField(selected.isEmpty ? "Collection name or ID" : "NFT number", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                }.padding(12).themedCard(14)
                if let issue = data.error { Text(issue).font(Theme.caption).foregroundStyle(.orange) }
                if let height = data.holdingsHeight, let verified = node.verifiedHeight, verified > height, verified - height > 10 {
                    Text("Inventory is updating; recent items may be missing.").font(Theme.caption).foregroundStyle(.orange)
                }
                if selected.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) { ForEach(ids, id: \.self) { id in collectionCard(id) } }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) { ForEach(items, id: \.nftDisplayID) { item in nftCard(item) } }
                }
                if (selected.isEmpty ? ids.isEmpty : items.isEmpty) { emptyState }
            }.padding(.horizontal,16).padding(.vertical,10)
        }.background(AmbientBackground()).foregroundStyle(Theme.text)
            .navigationTitle(selected.isEmpty ? "NFT gallery" : name(selected)).navigationBarTitleDisplayMode(.inline)
            .keyboardDismissControl()
            .sheet(item:$destination) { selected in
                NavigationStack {
                    Group {
                        switch selected { case .more: MoreView(); case .sync: DeviceNodeView() }
                    }.toolbar { ToolbarItem(placement:.cancellationAction) { Button("Done") { destination=nil } } }
                }
            }
            .onChange(of:wallet.locked) { _,locked in if locked { destination=nil } }
            .onChange(of: wallet.address) { _, _ in selected = ""; search = "" }
            .task(id: "\(artwork)-\(wallet.offlineMode)-\(wallet.locked)-\(data.collections.map { $0.text("metadata_hash") }.joined())") { await loadNames() }
            .task(id: "\(wallet.address)-\(wallet.locked)-\(data.updated?.timeIntervalSince1970 ?? 0)") { await loadPendingAsset() }
            .onReceive(Timer.publish(every:20,on:.main,in:.common).autoconnect()) { _ in
                Task { await loadPendingAsset() }
            }
            .refreshable {
                await data.refreshAndWait(owner: wallet.address, offline: wallet.offlineMode)
                await loadPendingAsset()
            }
    }
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if selected.isEmpty { Text("Your collections").font(Theme.headline) }
                else { Button { selected = ""; search = "" } label: { ThemedLabel("Collections", systemImage: "chevron.left") } }
                if let saved=data.savedSnapshotDate {
                    Text("Last saved inventory · block \(data.savedHoldingsHeight.map { String($0) } ?? "—") · \(saved.formatted(date:.abbreviated,time:.shortened))")
                        .font(Theme.caption2).foregroundStyle(Theme.secondary)
                } else if let height = data.holdingsHeight { Text("Verified inventory · block \(height)").font(Theme.caption2).foregroundStyle(Theme.secondary) }
                else { Text(data.refreshing ? "Loading inventory…" : "Inventory not synchronized").font(Theme.caption2).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 0)
            NFTGridChoice(grid:$grid,columns:$gridColumns)
            Menu {
                Button("More NFT options") { destination = .more }
                if !selected.isEmpty { Text("Collection ID: " + selected) }
                if let saved = data.savedSnapshotDate { Text("Saved " + saved.formatted()) }
                Button("Synchronization status") { destination = .sync }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44,height: 44) }.accessibilityLabel("Gallery options")
        }
    }
    private func collectionCard(_ id: String) -> some View {
        let collectionItems = owned.filter { $0.collection == id }
        return Button { selected = id; search = "" } label: {
            let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                if let sample = collectionItems.first { AssetThumbnail(item: sample, enabled: artwork && !wallet.offlineMode && !wallet.locked, showsTitle: false).frame(width: grid ? nil : 72) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(name(id)).font(Theme.headline).lineLimit(2)
                    Text(CollectionPresentation.ownership(count: collectionItems.count, collection: data.collections.first { $0.collection == id })).font(Theme.caption).foregroundStyle(Theme.secondary)
                    Text(id).font(Theme.caption2).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).themedCard(16)
                .themedOutline(16, Theme.line, 1)
        }.buttonStyle(.plain)
    }
    private func nftCard(_ item: NativeItem) -> some View {
        let pending = pendingNFTKeys.contains(item.collection + "#" + item.text("serial"))
        return NavigationLink { NFTGalleryDetail(item: item) } label: {
            let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                AssetThumbnail(item: item, enabled: artwork && !wallet.offlineMode && !wallet.locked, showsTitle: grid)
                    .frame(width: grid ? nil : 72).modifier(PendingNFTStyle(pending: pending))
                VStack(alignment: .leading, spacing: 5) {
                    if !grid { Text("NFT #" + item.text("serial")).font(Theme.headline) }
                    if pending { Label("Locked · pending transfer, was in your wallet",systemImage:"lock.fill").font(Theme.caption).foregroundStyle(.orange) }
                    else if !reservationChecked { Text("Checking reservation…").font(Theme.caption).foregroundStyle(Theme.secondary) }
                    if item.isListed(by: wallet.address) { ListedBadge() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).themedCard(16)
                .themedOutline(16, Theme.line, 1)
        }.buttonStyle(.plain).disabled(pending || !reservationChecked)
            .accessibilityHint(pending ? "This NFT is locally reserved until its pending authorization is resolved" : "Open NFT details")
    }
    private func loadPendingAsset() async {
        reservationChecked=false
        guard !wallet.locked,let root=wallet.accounts.first(where:{$0.index==0})?.address else {pendingNativeRequest=nil;return}
        let owner=wallet.address
        do {
            let result=try await NativeCore.shared.call(["op":"payment_pending","journal_directory":PaymentStorage.directory(root:root).path])
            guard !wallet.locked,wallet.address==owner else{return}
            let record=PendingLedger.unresolved(result).first { $0["operation_kind"] as? String == "native" }
            pendingNativeRequest=record?["local_native_request"] as? [String:Any]
            pendingNFTKeys=PendingLedger.pendingNFTs(result)
            reservationChecked=true
        }catch{pendingNativeRequest=nil}
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(data.refreshing ? "Loading NFT inventory…" : "No matching NFTs in this snapshot.").font(Theme.headline)
            if let issue = node.nativeStateIssue { Text(issue).font(Theme.caption).foregroundStyle(.orange) }
            Button("Refresh inventory") { node.synchronize(unlocked: !wallet.locked, offline: wallet.offlineMode, force: true, owner: wallet.address); data.refresh(owner: wallet.address, offline: wallet.offlineMode, force: true) }.disabled(wallet.offlineMode || node.running)
            if !selected.isEmpty || !search.isEmpty { Button("Show all collections") { selected = ""; search = "" } }
        }.padding(.vertical,20)
    }
    private func loadNames() async {
        guard artwork, !wallet.offlineMode, !wallet.locked else { return }
        for collection in data.collections where names[collection.text("metadata_hash")] == nil {
            let hash = collection.text("metadata_hash")
            guard !Task.isCancelled else { return }
            if let value = try? await AssetMedia.shared.loadName(hash: hash), !Task.isCancelled, !wallet.locked {
                var saved = names; saved[hash] = value
                if saved.count > 512 { saved = Dictionary(uniqueKeysWithValues: saved.sorted { $0.key < $1.key }.prefix(512).map { ($0.key,$0.value) }) }
                if let bytes = try? JSONEncoder().encode(saved) { rawNames = bytes }
            }
        }
    }
}

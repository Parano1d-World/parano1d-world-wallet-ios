import SwiftUI

enum AvatarNFTInventory {
    static func key(_ item:NativeItem, owner:String)->String {item.collection + ":" + item.text("serial") + ":" + owner}
    static func candidates(holdings:[NativeItem],listings:[NativeItem],owner:String)->[NativeItem] {
        guard !owner.isEmpty else{return []}
        var found:[String:NativeItem]=[:]
        for item in listings where item.text("seller") == owner && !item.collection.isEmpty {
            found[key(item,owner:owner)]=item
        }
        for item in holdings where item.type == "nft" && item.text("owner") == owner && !item.collection.isEmpty {
            found[key(item,owner:owner)]=item
        }
        return found.values.sorted {key($0,owner:owner) < key($1,owner:owner)}
    }
}

/// Device-local appearance keyed by the public root address; never a secret.
struct PersonalAvatar: View {
    let root: String
    var size: CGFloat = 44
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var data: LiveData
    @AppStorage("externalMedia") private var artworkEnabled = true
    @State private var displayName = ""
    @AppStorage private var monogram: String
    @AppStorage private var mode: String
    @AppStorage private var character: String
    @AppStorage private var nft: String
    @AppStorage private var symbol: String
    @AppStorage private var color: String
    init(root: String, size: CGFloat = 44) {
        self.root = root; self.size = size
        _monogram = AppStorage(wrappedValue:"", "profile.avatar.monogram." + root)
        _mode = AppStorage(wrappedValue:"initials", "profile.avatar.mode." + root)
        _character = AppStorage(wrappedValue:"", "profile.avatar.character." + root)
        _nft = AppStorage(wrappedValue: "", "profile.avatar.nft." + root)
        _symbol = AppStorage(wrappedValue: "person.fill", "profile.avatar.symbol." + root)
        _color = AppStorage(wrappedValue: "Green", "profile.avatar.color." + root)
    }
    static func tint(_ name: String) -> Color {
        switch name {
        case "Cyan": return .cyan
        case "Purple": return .purple
        case "Orange": return .orange
        case "Pink": return .pink
        case "Gold": return Color(hex:0xE4B94C)
        case "Red": return Color(hex:0xF06C73)
        case "Blue": return Color(hex:0x76A7F4)
        case "Silver": return Color(hex:0xC7D2DD)
        case "Mint": return Color(hex:0x5CF2C4)
        case "Lime": return Color(hex:0xB6F24A)
        case "Magenta": return Color(hex:0xE25CF2)
        default: return Theme.mint
        }
    }
    private var selectedNFT: NativeItem? {
        guard !wallet.locked else { return nil }
        return AvatarNFTInventory.candidates(holdings:data.holdings,listings:data.listings,owner:wallet.address)
            .first {AvatarNFTInventory.key($0,owner:wallet.address) == nft}
    }
    var body: some View {
        ZStack {
            if mode == "symbol" || (mode == "legacy" && symbol != "person.fill") {
                Image(systemName: AvatarSettingsView.symbols.contains(symbol) ? symbol : "person.fill")
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(Self.tint(color)).frame(width: size, height: size)
                    .background(Self.tint(color).opacity(0.14), in: Circle())
            } else if mode != "monogram" {
                // Nothing picked yet (or no name to show): a wallet icon, not a "?".
                if UserDefaults.standard.object(forKey: "profile.avatar.mode." + root) == nil || AvatarInitials.text(displayName) == "?" {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: size * 0.42, weight: .regular))
                        .foregroundStyle(Theme.mint).frame(width: size, height: size)
                        .background(Theme.mint.opacity(0.12), in: Circle())
                        .overlay(Circle().strokeBorder(Theme.mint.opacity(0.35), lineWidth: 1))
                } else {
                    ChatAvatar(name: displayName, size: size, fallbackIcon: "wallet.pass")
                }
            }
            if mode == "monogram", monogram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, AvatarInitials.text(displayName) == "?" {
                // A monogram with no letters and no name to fall back on: the wallet icon, never "?".
                Image(systemName: "wallet.pass")
                    .font(.system(size: size * 0.42, weight: .regular))
                    .foregroundStyle(Theme.mint).frame(width: size, height: size)
                    .background(Theme.mint.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.mint.opacity(0.35), lineWidth: 1))
            } else if mode == "monogram" {
                Text(monogram.isEmpty ? AvatarInitials.text(displayName) : String(monogram.trimmingCharacters(in:.whitespacesAndNewlines).uppercased().prefix(3)))
                    .font(.system(size:size * 0.32,weight:.bold,design:.rounded)).minimumScaleFactor(0.6)
                    .frame(width:size,height:size).background(Self.tint(color).opacity(0.22)).foregroundStyle(Self.tint(color))
            }
            if mode == "character" || (mode == "legacy" && !character.isEmpty && nft.isEmpty) {
                CharacterAvatarArt(configuration:CharacterAvatarConfiguration.decode(character)).frame(width:size,height:size)
            }
            if !Edition.isPublic, (mode == "nft" || mode == "legacy"), artworkEnabled, !wallet.offlineMode, let item = selectedNFT {
                NFTAvatarArtwork(item: item, size: size)
            }
        }.frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:CharacterAvatarConfiguration.decode(character).style == "Pixel" && mode == "character" ? size*0.22 : size/2))
            .accessibilityLabel(mode == "monogram" ? "Your monogram avatar" : mode == "character" ? "Your customized character avatar" : (mode == "nft" || mode == "legacy") && selectedNFT != nil ? "Your NFT avatar" : "Your avatar")
            .task(id: root + String(wallet.locked)) {
                displayName = ""
                guard !root.isEmpty, !wallet.locked else { return }
                if let invitation = try? await MessagingProfileStore.shared.invitation(for: root),
                   let contact = try? await ConnectedContact.inspect(invitation), contact.address == root, !wallet.locked {
                    displayName = contact.name
                }
            }
    }
}

struct AvatarSettingsView: View {
    static let symbols = SharedAvatar.allowedSymbols
    let root: String
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var data: LiveData
    @AppStorage("externalMedia") private var artworkEnabled = true
    @AppStorage private var monogram: String
    @AppStorage private var mode: String
    @AppStorage private var character: String
    @AppStorage private var nft: String
    @AppStorage private var symbol: String
    @AppStorage private var color: String
    init(root: String) {
        self.root = root
        _monogram = AppStorage(wrappedValue:"", "profile.avatar.monogram." + root)
        _mode = AppStorage(wrappedValue:"initials", "profile.avatar.mode." + root)
        _character = AppStorage(wrappedValue:"", "profile.avatar.character." + root)
        _nft = AppStorage(wrappedValue: "", "profile.avatar.nft." + root)
        _symbol = AppStorage(wrappedValue: "person.fill", "profile.avatar.symbol." + root)
        _color = AppStorage(wrappedValue: "Green", "profile.avatar.color." + root)
    }
    private func nftLabel(_ item:NativeItem)->String {
        let names=(try? JSONDecoder().decode([String:String].self,from:UserDefaults.standard.data(forKey:"nft.collectionNames.v1") ?? Data())) ?? [:]
        return CollectionPresentation.name(id:item.collection,collections:data.collections,names:names) + " · #" + item.text("serial")
    }
    private var ownedNFTs: [NativeItem] {
        guard !wallet.locked else { return [] }
        return AvatarNFTInventory.candidates(holdings:data.holdings,listings:data.listings,owner:wallet.address)
    }
    var body: some View {
        Form {
            Section {
                HStack { Spacer(); PersonalAvatar(root: root, size: 110); Spacer() }
                Picker("Avatar source",selection:$mode) {
                    Text("Name initials (default)").tag("initials")
                    Text("Symbol").tag("symbol")
                    Text("Character / Pixel").tag("character")
                    Text("Monogram").tag("monogram")
                    if mode == "legacy" {Text("Current avatar").tag("legacy")}
                }.pickerStyle(.menu)
                if mode == "character" {NavigationLink("Edit character and pixel style"){CharacterAvatarEditor(root:root)}}
                if mode == "monogram" {
                    TextField("Initials · up to 3 letters or numbers",text:$monogram).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of:monogram){_,value in let clean=String(value.filter{$0.isLetter || $0.isNumber}.uppercased().prefix(3));if clean != value {monogram=clean}}
                }
                if mode == "symbol" || mode == "legacy" {
                    Picker("Symbol",selection:$symbol){ForEach(Self.symbols,id:\.self){value in Label(value,systemImage:value).tag(value)}}
                    NavigationLink("Create a character avatar"){CharacterAvatarEditor(root:root)}
                }
                if mode != "nft" && mode != "character" {
                    Picker("Color",selection:$color){ForEach(["Green","Cyan","Purple","Orange","Pink"],id:\.self){Text($0).tag($0)}}
                }
            }.themedRow()
            if mode == "nft" {
            Section("Use an NFT you own") {
                if !nft.isEmpty { Button("Use selected NFT avatar") { mode = "nft" } }
                Toggle("Load verified artwork",isOn:$artworkEnabled)
                Text("Choose an NFT in your holdings or one you listed for sale. A saved gallery snapshot can appear immediately; sharing requires a current verified holdings or listing snapshot. If it is no longer available, your name initials are shown instead.").font(Theme.footnote)
                if ownedNFTs.isEmpty {
                    Text(data.refreshing ? "Loading your NFT inventory…" : "No NFTs in the current snapshot. Refresh inventory or check the NFT gallery.").foregroundStyle(Theme.secondary)
                }
                Button(data.refreshing ? "Refreshing inventory…" : "Refresh NFT inventory") {
                    data.refresh(owner:wallet.address,offline:wallet.offlineMode,force:true)
                }.disabled(data.refreshing || wallet.offlineMode)
                if let issue=data.error {Text(issue).font(Theme.footnote).foregroundStyle(.orange)}
                Picker("Owned NFT", selection:$nft) {
                    Text("Select an NFT").tag("")
                    if !nft.isEmpty && !ownedNFTs.contains(where:{AvatarNFTInventory.key($0,owner:wallet.address)==nft}) {
                        Text("Previous selection · ownership unavailable").tag(nft)
                    }
                    ForEach(ownedNFTs,id:\.nftDisplayID) {item in
                        Text(nftLabel(item) + (item.text("seller") == wallet.address && item.text("owner") != wallet.address ? " · Listed" : "")).tag(AvatarNFTInventory.key(item,owner:wallet.address))
                    }
                }.pickerStyle(.menu)
            }.themedRow()
            }
            Section {
                Text("Saved for this wallet on this device and shown in your wallet and chat. It remains saved after locking or restarting. Use Share my selected avatar in a private conversation, or Share my selected avatar publicly in the community. Contacts using a compatible version receive the selection after verifying the message. Local edits are not automatically published.").font(Theme.footnote)
            }.themedRow()
        }.scrollContentBackground(.hidden).background(AmbientBackground()).keyboardDismissControl().navigationTitle("Your avatar").disabled(root.isEmpty)
            .task(id:wallet.address) {
                guard !wallet.locked,!wallet.offlineMode,!wallet.address.isEmpty,ownedNFTs.isEmpty else{return}
                await data.restoreDisplay(owner:wallet.address)
                if ownedNFTs.isEmpty {data.refresh(owner:wallet.address,offline:false)}
            }
    }
}

private struct NFTAvatarArtwork: View {
    let item: NativeItem
    let size: CGFloat
    @EnvironmentObject private var wallet: WalletState
    @State private var image: UIImage?
    private var identity: String { item.collection + ":" + item.text("serial") + ":" + item.text("metadata_hash") }
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFill().frame(width:size,height:size).clipped() }
        }
        .task(id:identity) {
            image = nil
            guard !wallet.locked,!wallet.offlineMode else{return}
            let address = wallet.address
            do {
                let metadata = try await AssetMedia.shared.load(hash:item.text("metadata_hash"))
                guard !Task.isCancelled,!wallet.locked,!wallet.offlineMode,wallet.address == address else{return}
                image = metadata.image
            } catch { image = nil }
        }
        .onChange(of:wallet.locked) { _, locked in if locked {image = nil} }
        .onDisappear { image = nil }
    }
}

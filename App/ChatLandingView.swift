import SwiftUI
import CryptoKit

enum AvatarInitials {
    static func text(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first?.first else { return "?" }
        let last = parts.count > 1 ? parts.last?.first : nil
        return (String(first) + (last.map { String($0) } ?? "")).uppercased()
    }
}

struct ChatAvatar: View {
    let name: String
    var size: CGFloat = 48
    /// Shown instead of initials when there's no name: never a "?".
    var fallbackIcon = "person.fill"
    var body: some View {
        let initials = AvatarInitials.text(name)
        Group {
            if initials == "?" {
                Image(systemName: fallbackIcon).font(.system(size: size * 0.4, weight: .regular))
            } else {
                Text(initials).font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(Theme.mint).frame(width: size, height: size)
        .background(Theme.mint.opacity(0.12), in: Circle())
        .accessibilityLabel(initials == "?" ? "No name" : "Initials for " + name)
    }
}

struct ChatLandingView: View {
    @AppStorage(ChatPrivacy.storageKey) private var paranoidMode=false
    @State private var privateMessages = false
    var body: some View {
        VStack(spacing: 0) {
            ChatConnectionBar()
            Picker("Chat channel", selection: Binding(get:{privateMessages || paranoidMode},set:{privateMessages=$0})) {
                if !paranoidMode {Text("#parano1d").tag(false)}
                Text("Private").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal,16).padding(.vertical,10)
            if privateMessages || paranoidMode { PrivateChatListView() }
            else { CommunityChatView() }
        }.background(AmbientBackground()).chatRulesGate()
    }
}

struct PrivateChatListView: View {
    @AppStorage(ContactFavorites.storageKey) private var favoriteJSON="[]"
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet:WalletState
    @EnvironmentObject private var nearby:NearbyTransport
    @Environment(\.scenePhase) private var phase
    @Environment(\.walletTabActive) private var tabActive
    @State private var contacts:[ConnectedContact]=[]
    @State private var packets:[MessageArchive.Packet]=[]
    @State private var unreadCounts:[String:Int]=[:]
    @State private var conversationOrder:[String]=[]
    @State private var archivedContactIDs:Set<String>=[]
    @State private var showArchived=false
    @State private var pendingConversationDeletion:ConnectedContact?
    @State private var showReorder=false
    @State private var query=""
    @State private var hasProfile=false
    @State private var ownIdentity=""
    @State private var requestCount=0
    @State private var screenVisible=false
    @AppStorage(ChatPrivacy.storageKey) private var paranoidMode=false
    @AppStorage("chatOnlineDeliveryEnabled") private var relayEnabled=false
    private let refreshClock=Timer.publish(every:10,on:.main,in:.common).autoconnect()
    @State private var loading=false
    @State private var error:String?
    private var avatarRoot: String { wallet.accounts.first(where: { $0.index == 0 })?.address ?? "" }
    private var ready:Bool {
        #if DEBUG
        if StoreShots.on {return true}
        #endif
        return wallet.localWallet?.recoveryVerified == true
    }
    private func latest(_ id:String)->MessageArchive.Packet? {packets.filter{$0.contactID==id}.max{$0.date<$1.date}}
    private var unreadTotal:Int {unreadCounts.values.reduce(0,+)}
    private var orderedContacts:[ConnectedContact] {
        contacts.sorted {
            let a=conversationOrder.firstIndex(of:$0.id),b=conversationOrder.firstIndex(of:$1.id)
            if let a,let b,a != b {return a<b}
            if a != nil {return true}
            if b != nil {return false}
            let favorites=ContactFavorites.read(favoriteJSON)
            if favorites.contains($0.id) != favorites.contains($1.id) {return favorites.contains($0.id)}
            let first=latest($0.id)?.date ?? .distantPast,second=latest($1.id)?.date ?? .distantPast
            return first == second ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : first>second
        }
    }
    private var rows:[ConnectedContact] {orderedContacts.filter { (showArchived || !archivedContactIDs.contains($0.id)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)) }}
    private var identity:String? {wallet.accounts.first(where:{$0.index==0})?.address}
    private func updateConversation(_ operation:@escaping (String) async throws -> Void) {
        guard let root=identity else{return}
        Task {
            do {
                guard let invitation=try await MessagingProfileStore.shared.invitation(for:root) else{return}
                let own=try await ConnectedContact.inspect(invitation)
                try await operation(own.id)
                await load()
            } catch {self.error=error.localizedDescription}
        }
    }
    private func saveOrder(_ newOrder:[String]) {
        guard newOrder != orderedContacts.map(\.id) else{return}
        conversationOrder=newOrder
        updateConversation {identity in try await MessageArchive.shared.setConversationOrder(identity:identity,order:newOrder)}
    }
    /// Drag and drop: the dragged conversation takes the target's place (after it when
    /// dragged down, before it when dragged up).
    private func drop(_ draggedID:String,onto target:ConnectedContact) -> Bool {
        var order=orderedContacts.map(\.id)
        guard draggedID != target.id,let from=order.firstIndex(of:draggedID),let to=order.firstIndex(of:target.id) else{return false}
        order.remove(at:from);order.insert(draggedID,at:to)
        withAnimation(.snappy) {saveOrder(order)}
        return true
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack {
                    PersonalAvatar(root:avatarRoot,size:48)
                    VStack(alignment:.leading,spacing:5) {
                        Text("Messages").font(Theme.cyber ? Theme.editorial(34) : .system(size:34,weight:.bold,design:.rounded))
                        HStack(spacing:6) {
                            Circle().fill(nearby.links>0 ? Theme.mint : Theme.secondary).frame(width:6,height:6)
                            Text(nearby.enabled ? "Mesh relay · \(nearby.links) nearby links" : "Mesh relay paused")
                                .font(Theme.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer()
                    NavigationLink {MessagingView()} label:{Image(systemName:"square.and.pencil").font(.title3).frame(width:46,height:46).background(Theme.panel,in:Circle())}
                        .accessibilityLabel("New conversation").disabled(!ready)
                }
                if !ready {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Set up your wallet for chat").font(Theme.headline)
                        Text("Create or import a wallet and confirm its backup to send messages and review payments.")
                        NavigationLink("Open wallet setup") { WalletSetupView() }
                    }.padding().themedCard(14)
                } else if !hasProfile {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Set up chat").font(Theme.headline)
                        Text("Choose a display name and enable your messaging identity. Then choose online delivery and connect a contact for private messages and payment requests.")
                        NavigationLink("Set up chat now") { MessagingView() }
                            .buttonStyle(MintButtonStyle())
                    }.padding().themedCard(14)
                } else {
                    NavigationLink { MessagingView() } label: {
                        HStack(spacing:12) {
                            Image(systemName:"person.crop.circle.badge.checkmark").font(.system(size:18)).foregroundStyle(Theme.mint)
                                .frame(width:36,height:36).background(Theme.soft,in:RoundedRectangle(cornerRadius:10))
                            VStack(alignment:.leading,spacing:2) {
                                Text("Chat identity and delivery").font(Theme.subheadline.weight(.medium))
                                Text("Your invitation, display name and delivery options").font(Theme.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer(minLength:4)
                            Image(systemName:"chevron.right").font(Theme.caption).foregroundStyle(Theme.secondary)
                        }.padding(12).themedCard(14)
                    }.buttonStyle(.plain)
                }
                HStack(spacing:10) {Image(systemName:"magnifyingglass");TextField("Search conversations",text:$query).autocorrectionDisabled()}
                    .foregroundStyle(Theme.secondary).padding(13).themedCard(14)
                HStack {Text(unreadTotal == 0 ? "CONVERSATIONS" : "CONVERSATIONS · \(unreadTotal) UNREAD").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Theme.secondary);Spacer();NavigationLink {ConnectedContactsView()} label:{ThemedLabel("Add contact", systemImage: "person.badge.plus")}.font(.caption.weight(.medium)).buttonStyle(ThemedButtonStyle())}
                if !archivedContactIDs.isEmpty {Button(showArchived ? "Hide archived" : "Show archived (\(archivedContactIDs.count))") {showArchived.toggle()}.font(Theme.caption).foregroundStyle(Theme.mint)}
                if requestCount>0,!ownIdentity.isEmpty {
                    NavigationLink {MessageRequestsView(identity:ownIdentity)} label: {
                        HStack(spacing:10) {
                            Image(systemName:"tray").foregroundStyle(Theme.secondary)
                            Text("Message requests (\(requestCount))").font(Theme.subheadline)
                            Spacer();Image(systemName:"chevron.right").font(Theme.caption).foregroundStyle(Theme.secondary)
                        }.padding(12).themedCard(14)
                    }.buttonStyle(.plain)
                }
                if loading && contacts.isEmpty {ProgressView("Loading conversations…").frame(maxWidth:.infinity)}
                ForEach(rows) {contact in
                    NavigationLink {MessagingView(initialInvitation:contact.invitation)} label: {
                        HStack(alignment:.center,spacing:13) {
                            PeerAvatar(identity:contact.id,name:contact.name)
                            VStack(alignment:.leading,spacing:5) {
                                HStack {
                                    Text(contact.name).font(Theme.headline).lineLimit(1)
                                    if ContactFavorites.read(favoriteJSON).contains(contact.id) {Image(systemName:"star.fill").font(Theme.caption).foregroundStyle(.yellow).accessibilityLabel("Favorite contact")}
                                    if !PrivateChatBlocks.contains(contact.id),let count=unreadCounts[contact.id],count>0 {Text("\(count)").font(Theme.caption.weight(.bold)).foregroundStyle(Theme.background).padding(.horizontal,8).padding(.vertical,3).background(Theme.mint,in:Capsule()).accessibilityLabel("\(count) unread messages")}
                                    Spacer()
                                    if let packet=latest(contact.id) {Text(packet.date,style:.date).font(Theme.caption2).foregroundStyle(Theme.secondary)}
                                }
                                if PrivateChatBlocks.contains(contact.id) {
                                    Label("Blocked",systemImage:"hand.raised.fill").font(Theme.subheadline).foregroundStyle(.orange).lineLimit(1)
                                } else {
                                    Label(latest(contact.id) == nil ? "Start an encrypted conversation" : "Private conversation",systemImage:"lock.fill")
                                        .font(Theme.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                        }.padding(.vertical,7).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!ready)
                        // Hold still for the menu; hold and move to drag the conversation.
                        .draggable(contact.id) {
                            HStack(spacing:10) {PeerAvatar(identity:contact.id,name:contact.name);Text(contact.name).font(Theme.headline)}
                                .padding(10).themedCard(14)
                        }
                        .dropDestination(for:String.self) {items,_ in
                            guard ready,let dragged=items.first else{return false}
                            return drop(dragged,onto:contact)
                        }
                        .contextMenu {
                            Button(archivedContactIDs.contains(contact.id) ? "Restore conversation" : "Archive conversation",systemImage:"archivebox") {
                                let archived = !archivedContactIDs.contains(contact.id)
                                if archived {archivedContactIDs.insert(contact.id)} else {archivedContactIDs.remove(contact.id)}
                                updateConversation {identity in try await MessageArchive.shared.setArchived(identity:identity,contactID:contact.id,archived:archived)}
                            }
                            if PrivateChatBlocks.contains(contact.id) {
                                Button("Unblock contact",systemImage:"hand.raised.slash") {PrivateChatBlocks.unblock(contact.id)}
                            } else {
                                Button("Block contact",systemImage:"hand.raised",role:.destructive) {PrivateChatBlocks.block(contact.id)}
                            }
                            Button("Delete local conversation",systemImage:"trash",role:.destructive) {pendingConversationDeletion=contact}
                        }
                }
                if rows.isEmpty && !loading {
                    VStack(spacing:12) {
                        Image(systemName:"bubble.left.and.bubble.right").font(.system(size:38,weight:.light)).foregroundStyle(Theme.mint)
                        Text(query.isEmpty && !archivedContactIDs.isEmpty && !showArchived ? "Conversations are archived" : query.isEmpty ? "Your conversations start here" : "No matching contacts").font(Theme.headline)
                        Text(query.isEmpty && !archivedContactIDs.isEmpty && !showArchived ? "Tap Show archived above to restore a conversation." : ready ? "Add a friend's signed invitation or share your own to start chatting." : "Create or restore your wallet and confirm its backup to enable encrypted messages.").font(Theme.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                        NavigationLink("Connect a contact"){ConnectedContactsView()}.buttonStyle(MintButtonStyle()).disabled(!ready)
                    }.frame(maxWidth:.infinity).padding(.vertical,32)
                }
                if let error {Text(error).font(Theme.caption).foregroundStyle(.orange)}
                if orderedContacts.count>1 {Button("Reorder conversations",systemImage:"arrow.up.arrow.down") {showReorder=true}.font(Theme.caption).foregroundStyle(Theme.mint).disabled(!ready)}
                Text("Hold and drag a conversation to reorder it. Hold without moving to archive, block or delete its local messages. Message contents stay hidden in this list.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.padding(20).frame(maxWidth:720).frame(maxWidth:.infinity)
        }.background(Theme.background).foregroundStyle(Theme.text).navigationBarTitleDisplayMode(.inline).keyboardDismissControl()
            .safeAreaInset(edge:.top) { UnavailableNotice(needs:[.backup]).padding(.horizontal,16).padding(.top,4) }
            .sheet(isPresented:$showReorder) {
                NavigationStack {
                    List {
                        ForEach(orderedContacts) {contact in
                            HStack(spacing:12) {PeerAvatar(identity:contact.id,name:contact.name);Text(contact.name).lineLimit(1)}
                        }.onMove {source,destination in
                            var order=orderedContacts.map(\.id)
                            order.move(fromOffsets:source,toOffset:destination)
                            saveOrder(order)
                        }
                    }.environment(\.editMode,.constant(.active))
                    .navigationTitle("Reorder").navigationBarTitleDisplayMode(.inline)
                    .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Done") {showReorder=false}}}
                }
            }
            .confirmationDialog("Delete this conversation from this device?",isPresented:Binding(get:{pendingConversationDeletion != nil},set:{if !$0 {pendingConversationDeletion=nil}}),titleVisibility:.visible,presenting:pendingConversationDeletion) {contact in
                Button("Delete saved messages",role:.destructive) {
                    updateConversation {identity in try await MessageArchive.shared.deleteConversation(identity:identity,contactID:contact.id)}
                    pendingConversationDeletion=nil
                }
                Button("Keep conversation",role:.cancel) {pendingConversationDeletion=nil}
            } message: {_ in Text("The contact remains connected. Messages already delivered to the other person cannot be recalled. Deleted packets will not be restored from nearby or the relay.")}
            .task(id:"\(phase)-\(tabActive)-\(wallet.address)-\(wallet.accounts.first(where:{$0.index==0})?.address ?? "")-\(wallet.locked)"){if phase == .active && tabActive {await load()}}
            .refreshable {await load()}
            .onAppear {screenVisible=true}
            .onDisappear {screenVisible=false}
            .onReceive(refreshClock) { _ in
                if screenVisible && tabActive && phase == .active && !wallet.locked && !loading {
                    Task {await load()}
                }
            }
            .onReceive(NotificationCenter.default.publisher(for:.privateMessageArrived)) {_ in Task {await load()}}
            .onReceive(NotificationCenter.default.publisher(for:PrivateChatBlocks.changed)) {_ in Task {await load()}}
            .onReceive(NotificationCenter.default.publisher(for:.privateMessageRead)) {_ in Task {await load()}}
            .onChange(of:wallet.locked){_,locked in if locked {contacts=[];packets=[];unreadCounts=[:];requestCount=0;ownIdentity="";conversationOrder=[];archivedContactIDs=[];query="";hasProfile=false}}
    }
    private func load() async {
        guard !wallet.locked,!loading else{return}
        #if DEBUG
        if StoreShots.on {contacts=StoreShots.contacts;packets=StoreShots.packets;unreadCounts=StoreShots.unread;hasProfile=true;ownIdentity=StoreShots.ownID;requestCount=0;error=nil;return}
        #endif
        let address=wallet.address
        loading=true;defer{loading=false}
        do {
            let saved=try await ContactBook.shared.load()
            guard !Task.isCancelled,!wallet.locked,wallet.address==address else{return}
            contacts=saved
            var messages:[MessageArchive.Packet]=[]
            var foundProfile=false
            if let root=wallet.accounts.first(where:{$0.index==0})?.address,
               let invitation=try await MessagingProfileStore.shared.invitation(for:root) {
                let own=try await ConnectedContact.inspect(invitation)
                foundProfile=true
                guard own.address==root else{throw AppFailure("Messaging identity does not match this wallet.")}
                // Applies blocks and contact changes to saved messages (and upgrades old history).
                try await MessageArchive.shared.refresh(identity:own.id)
                try await MessageArchive.shared.importNearby(nearby.packets,identity:own.id)
                if relayEnabled,!wallet.offlineMode,wallet.canRefreshMessages {
                    let context=try wallet.messagingRefreshContext()
                    let after=try await MessageArchive.shared.cursor(identity:own.id)
                    let page=try await InboxPaging.load { limit in
                        await InstantAlerts.registerIfNeeded(context:context)
                        let auth=try await WalletVault.shared.message(["op":"chat_inbox_auth","after":after,"limit":limit,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
                        return try await MessageRelay.shared.inbox(auth:auth)
                    }
                    guard !Task.isCancelled,!wallet.locked,wallet.address==address else{return}
                    let validated=try await MessageInbox.validate(page,identity:own.id,after:after)
                    guard !Task.isCancelled,!wallet.locked,wallet.address==address,screenVisible,tabActive,phase == .active else{return}
                    try await MessageArchive.shared.commit(validated.packets,identity:own.id,after:after,cursor:validated.cursor)
                }
                messages=try await MessageArchive.shared.packets(identity:own.id)
                unreadCounts=try await MessageArchive.shared.unreadCounts(identity:own.id)
                let requests=try await MessageArchive.shared.requestPackets(identity:own.id)
                requestCount=Set(requests.map(\.contactID)).count;ownIdentity=own.id
                let preferences=try await MessageArchive.shared.conversationPreferences(identity:own.id)
                conversationOrder=preferences.order
                archivedContactIDs=preferences.archived
            }
            guard !Task.isCancelled,!wallet.locked,wallet.address==address else{return}
            contacts=saved;packets=messages;hasProfile=foundProfile;error=nil
        }catch {if !Task.isCancelled,!wallet.locked,wallet.address==address {self.error=error.localizedDescription}}
    }
}

struct CommunityRoomHeader: View {
    var body: some View {
        HStack(spacing:12) {
            Image("Brand").resizable().scaledToFit().frame(width:38,height:38).padding(5)
            VStack(alignment:.leading,spacing:4) {
                Text("#parano1d").font(Theme.editorial(23))
                Text("Public community").font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Image(systemName:"globe").foregroundStyle(Theme.mint)
        }.chatBubble()
    }
}

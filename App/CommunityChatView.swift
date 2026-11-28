import SwiftUI
import Foundation
import UIKit
import UniformTypeIdentifiers

/// The upstream #parano1d room is signed and public. It is not encrypted.
/// No public-room packet can create a payment or mark a payment settled here.
struct CommunityChatView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @AppStorage(ChatPrivacy.storageKey) private var paranoidMode=false
    private struct Post: Identifiable {
        let id: String
        let senderID: String
        let name: String
        let text: String
        var update: PublicPaymentUpdate? = nil
        let created: Date
        let createdMS: UInt64
        var safetyReason: String? = nil
    }
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var liveData: LiveData
    @State private var confirmAvatarShare = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.walletTabActive) private var tabActive
    @StateObject private var moderation = PublicModerationStore.shared
    @State private var visible = false
    private let refreshClock = Timer.publish(every:5,on:.main,in:.common).autoconnect() // new posts appear within a few seconds
    @State private var posts: [Post] = []
    @State private var profile: [String: Any]?
    @State private var name = ""
    @State private var draft = ""
    @State private var replySnippet: String?
    @State private var showRoomSettings = false
    @State private var showFullReply = false
    @FocusState private var composing: Bool
    @State private var error: String?
    @State private var status: String?
    @State private var busy = false
    @State private var blocked = Set<String>()
    @AppStorage("communityBlockedIdentities.v1") private var blockedJSON = "[]"
    @State private var publicSendHistory: [(text: String, time: TimeInterval)] = []
    @State private var reportCandidate: PublicChatReport?
    @State private var blockCandidate:String?
    @State private var generation = UUID()
    private var root: String? { wallet.accounts.first(where: { $0.index == 0 })?.address }

    var body: some View {
        List {
            CommunityRoomHeader().listRowInsets(EdgeInsets(top:8,leading:16,bottom:8,trailing:16)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            if profile == nil {
                Section("Set up chat") {
                    if wallet.offlineMode { Text("Offline mode is on. Reconnect to post.").foregroundStyle(.orange) }
                    if busy { ProgressView("Working with the community relay…") }
                    TextField("Display name", text: $name).textInputAutocapitalization(.words)
                    Button("Enable signed profile") { enableProfile() }
                        .disabled(busy || wallet.localWallet?.recoveryVerified != true || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.themedRow()
            }
            if let error {Text(error).font(Theme.caption).foregroundStyle(.orange).listRowBackground(Color.clear)}
            if busy && posts.isEmpty {ProgressView("Loading public messages…").listRowBackground(Color.clear)}
            Section("Messages · newest first") {
                if posts.isEmpty { Text("No recent messages loaded. Tap Refresh room.").foregroundStyle(Theme.secondary) }
                ForEach(posts.filter { !blocked.contains($0.senderID) }) { post in
                    VStack(alignment: .leading, spacing: 5) {
                        if let decision = moderation.restriction(messageID: post.id, identity: post.senderID) {
                            Label("Hidden by community moderator", systemImage: "eye.slash")
                            Text(ModerationProtocol.reasonLabel(decision.reason)).font(Theme.caption)
                            Text("Decision " + decision.id).font(Theme.caption).textSelection(.enabled)
                            Text("Appeal: support@koajent.com. This affects this app only.").font(Theme.caption)
                        } else if let reason = post.safetyReason {
                            Label("Public post hidden", systemImage: "eye.slash")
                            Text(reason).font(Theme.caption).foregroundStyle(Theme.secondary)
                            Text("Long press to report or block this author.").font(Theme.caption)
                        } else {
                        HStack {
                            NavigationLink {CommunityMemberView(identity:post.senderID,name:post.name)} label: {
                                HStack(spacing:10) {
                                    if post.senderID == (profile?["id"] as? String) { PersonalAvatar(root:root ?? "",size:36) }
                                    else { PeerAvatar(identity:post.senderID,name:post.name,size:36,publicOnly:true) }
                                    Text(post.name).font(Theme.headline).foregroundStyle(Theme.mint)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Spacer()
                            Text(post.created, style: .time).font(Theme.caption).foregroundStyle(Theme.secondary)
                        }
                        if let update=post.update { PublicPaymentCard(update:update) }
                        else { Text(SharedAvatar.displayText(post.text)).font(Theme.body).lineSpacing(4).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                        HStack(spacing:18) {
                            Button { reply(to:post) } label: { ThemedLabel("Reply", systemImage: "arrowshape.turn.up.left") }
                            Button { copyMessage(post) } label: { ThemedLabel("Copy", systemImage: "doc.on.doc") }
                        }.font(Theme.caption).foregroundStyle(Theme.mint).buttonStyle(.plain)
                        }
                        Text(String(post.senderID.prefix(12)) + "…").font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                    }.chatBubble()
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .contextMenu {
                            if post.safetyReason == nil && moderation.restriction(messageID:post.id,identity:post.senderID) == nil {
                                Button("Reply",systemImage:"arrowshape.turn.up.left") { reply(to:post) }
                                Button("Copy message",systemImage:"doc.on.doc") { copyMessage(post) }
                            }
                            Button("Report message") { reportCandidate = report(for: post, target: "message") }
                            Button("Report user") { reportCandidate = report(for: post, target: "user") }
                            Button("Hide and block",role:.destructive) {blockCandidate=post.senderID}
                        }
                }
            }.themedRow()
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(AmbientBackground()).keyboardDismissControl()
        .safeAreaInset(edge:.bottom,spacing:0) {
            if profile != nil && !wallet.locked && !paranoidMode { composer }
        }
        .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement:.topBarTrailing) {
            Button { refresh() } label: { Image(systemName:"arrow.clockwise") }
                .accessibilityLabel("Refresh public messages").disabled(busy || wallet.offlineMode)
            Button { showRoomSettings = true } label: { Image(systemName:"ellipsis.circle") }
                .accessibilityLabel("Chat settings and safety")
        } }
        .sheet(isPresented:$showRoomSettings) { roomSettings }
        .sheet(isPresented:$showFullReply) {
            NavigationStack {
                ScrollView { Text(replySnippet ?? "").frame(maxWidth:.infinity,alignment:.leading).padding().textSelection(.enabled) }
                    .navigationTitle("Original message").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Done") { showFullReply = false } } }
            }
        }
        .disabled(wallet.locked || paranoidMode)
        .safeAreaInset(edge:.top) { PublicChatOffNotice() }
        .onChange(of:paranoidMode) { _,enabled in if enabled {reportCandidate=nil;clear()} }
        .confirmationDialog("Hide this member’s posts?",isPresented:Binding(get:{blockCandidate != nil},set:{if !$0 {blockCandidate=nil}}),titleVisibility:.visible,presenting:blockCandidate) {id in
            Button("Hide and block",role:.destructive) {block(id);blockCandidate=nil}
            Button("Cancel",role:.cancel) {blockCandidate=nil}
        } message: {_ in Text("You can unhide them in Chat settings under Blocked identities.")}
        .confirmationDialog("Publish your selected avatar?", isPresented:$confirmAvatarShare, titleVisibility:.visible) {
            Button("Share publicly") { shareAvatar() }
            Button("Cancel",role:.cancel) {}
        } message: { Text("Everyone can see and retain this avatar. NFT selections include their collection and number. Older clients may show the avatar recipe as text. Local edits are not automatically shared.") }
        .sheet(item: $reportCandidate) { report in
            PublicChatReportView(report: report, onBlock: {
                block(report.senderID)
                return blocked.contains(report.senderID)
            })
        }
        .onAppear { visible = true }
        .task(id:"\(root ?? "")-\(wallet.locked)-\(phase)") {
            guard !wallet.locked,phase == .active else{return}
            loadBlocked();await loadProfile();refresh()
        }
        .task(id: "moderation-\(wallet.offlineMode)-\(wallet.locked)-\(paranoidMode)-\(tabActive)-\(phase)") {
            if !wallet.locked && !paranoidMode && tabActive && phase == .active { await moderation.refresh(online: !wallet.offlineMode) }
        }
        .onReceive(refreshClock) { _ in
            if visible && tabActive && phase == .active && !wallet.locked && !wallet.offlineMode && !busy {
                refresh(automatic: true)
                Task { await moderation.refresh(online: !wallet.offlineMode && !wallet.locked && !paranoidMode) }
            }
        }
        .onChange(of: wallet.locked) { _, locked in if locked { reportCandidate=nil;clear() } }
        .onChange(of: phase) { _, value in if value == .background { clear() } }
        .onDisappear { visible=false;generation=UUID();busy=false }
    }
    private var roomSettings: some View {
        NavigationStack {
            Form {
            Section {
                NavigationLink {ConnectedContactsView()} label:{ThemedLabel("Connect by signed invitation", systemImage: "person.crop.circle.badge.plus")}
            }.themedRow()
            Section {
                DisclosureGroup("Room options and safety") {
                DisclosureGroup("Public room privacy") {
                    Text("Everyone can read this room. Signatures identify the messaging key, not a real name or ownership of a payment address. Never post recovery keys.").font(Theme.footnote)
                }
                DisclosureGroup("Community rules and reporting") {
                    Text(PublicChatSafety.rules).font(Theme.footnote)
                    Text("This app screens a limited set of public text phrases and repeated posts. Screening can miss abuse or flag quotations. Hidden posts remain reportable by long-pressing them. It does not remove messages from the network or screen private chats, images, or linked pages.").font(Theme.footnote)
                    Text("Support: support@koajent.com").textSelection(.enabled)
                    Text(moderation.status).font(Theme.caption)
                    Text("When configured, moderator updates contact " + (moderation.host.isEmpty ? "the Parano1d moderation server" : moderation.host) + ". That host can see your IP address; this request contains no wallet address or chat identity.").font(Theme.footnote)
                    Button("Refresh moderator updates") {
                        Task { await moderation.refresh(online: !wallet.offlineMode && !wallet.locked && !paranoidMode, force: true) }
                    }.disabled(moderation.loading || wallet.offlineMode)
                }
                Text("Auto-refresh · every 15 seconds while open").font(Theme.caption).foregroundStyle(Theme.secondary)
                Button(busy ? "Working…" : "Refresh room") { refresh() }.disabled(busy || wallet.offlineMode)
                if let status { Text(status).font(Theme.caption).foregroundStyle(Theme.secondary) }
                }
            }.themedRow()
            Section("Your community profile") {
                if wallet.offlineMode { Text("Offline mode is on. Reconnect to refresh or post.").foregroundStyle(.orange) }
                if busy && posts.isEmpty { ProgressView("Working with the community relay…") }
                if profile == nil {
                    Text("Set up chat here: choose a display name, then enable your signed profile. This also enables your private messaging identity.").font(Theme.footnote)
                    TextField("Display name", text: $name).textInputAutocapitalization(.words)
                    Button("Enable signed profile") { enableProfile() }
                        .disabled(busy || wallet.localWallet?.recoveryVerified != true || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                } else {
                    if let restriction = moderation.restriction(identity: profile?["id"] as? String ?? "") {
                        Text("Public posting is restricted: " + ModerationProtocol.reasonLabel(restriction.reason) + ". Appeal to support@koajent.com with decision " + restriction.id + ". Your wallet and private messages are unaffected.").font(Theme.footnote)
                    }
                    Button("Share my selected avatar publicly") { confirmAvatarShare = true }.disabled(busy || wallet.offlineMode)
                }
                Text("For encrypted messages, requests and reviewed payments, use a verified contact in Private messages. A public post is never a payment confirmation.")
                    .font(Theme.footnote).foregroundStyle(Theme.secondary)
                NavigationLink("Private messages and payments") { MessagingView() }
            }.themedRow()
            if !blocked.isEmpty {
                Section("Blocked identities · this device") {
                    ForEach(blocked.sorted(), id:\.self) { id in
                        HStack {
                            Text(String(id.prefix(16)) + "…").font(.caption.monospaced())
                            Spacer()
                            Button("Unblock") { unblock(id) }
                        }
                    }
                }.themedRow()
            }
            }
            .navigationTitle("Chat settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Done") { showRoomSettings = false } } }
        }
    }
    private func report(for post: Post, target: String) -> PublicChatReport {
        PublicChatReport(target: target, messageID: post.id, senderID: post.senderID,
                         displayName: post.name, message: post.text, created: post.created)
    }
    private func clear() {
        generation = UUID(); posts = []; profile = nil; draft = ""; replySnippet=nil; showFullReply=false; showRoomSettings=false; name = ""; error = nil; status = nil; busy = false
    }
    private var composedText:String {
        CommunityReply.compose(quote:replySnippet,draft:draft)
    }
    private var composer:some View {
        VStack(alignment:.leading,spacing:8) {
            if let replySnippet {
                HStack(spacing:8) {
                    Image(systemName:"arrowshape.turn.up.left")
                    Text(replySnippet).lineLimit(2)
                    Button("Full") { showFullReply = true }
                    Spacer()
                    Button {self.replySnippet=nil} label:{Image(systemName:"xmark")}.accessibilityLabel("Cancel reply")
                }.font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            if let error {Text(error).font(Theme.caption).foregroundStyle(.orange)}
            if composedText.utf8.count > CommunityReply.maximumBytes {
                Text("The full quote and reply exceed the 4,096-byte room limit. Shorten your message or cancel the quote; no text will be cut automatically.")
                    .font(Theme.caption).foregroundStyle(.orange)
            }
            HStack(alignment:.bottom,spacing:10) {
                TextField("Public message",text:$draft,axis:.vertical).lineLimit(1...4).focused($composing)
                    .padding(.horizontal,14).padding(.vertical,11)
                    .themedCard(22)
                    .contentShape(Rectangle()).simultaneousGesture(TapGesture().onEnded { composing = true })
                Button {send()} label:{Image(systemName:"arrow.up").font(Theme.headline).frame(width:44,height:44).background(Theme.mint,in:Circle()).foregroundStyle(Theme.background)}
                    .accessibilityLabel("Post public message")
                    .disabled(moderation.restriction(identity:profile?["id"] as? String ?? "") != nil || busy || wallet.offlineMode || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !CommunityReply.fits(composedText))
            }
        }.padding(.horizontal,14).padding(.vertical,10)
            .background(Theme.background)
            .overlay(alignment:.top) {Divider().overlay(Theme.line)}
    }
    private func reply(to post:Post) {
        guard profile != nil,post.safetyReason == nil,moderation.restriction(messageID:post.id,identity:post.senderID) == nil else{return}
        let content=SharedAvatar.displayText(post.text)
        replySnippet=CommunityReply.quote(name:post.name,message:content)
        composing=true
    }
    private func copyMessage(_ post:Post) {
        guard post.safetyReason == nil,moderation.restriction(messageID:post.id,identity:post.senderID) == nil else{return}
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier:SharedAvatar.displayText(post.text)]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(120)])
    }
    private func loadBlocked() {
        let ids = (try? JSONDecoder().decode([String].self, from:Data(blockedJSON.utf8))) ?? []
        blocked = Set(ids.filter { $0.count == 64 && Data(hex:$0)?.count == 32 }.prefix(250))
    }
    private func block(_ id:String) {
        guard id.count == 64, Data(hex:id)?.count == 32, blocked.count < 250 else { return }
        blocked.insert(id)
        saveBlocked()
    }
    private func unblock(_ id:String) {
        blocked.remove(id); saveBlocked()
    }
    private func saveBlocked() {
        if let data = try? JSONEncoder().encode(blocked.sorted()), let value = String(data:data,encoding:.utf8) { blockedJSON = value }
    }
    private func loadProfile() async {
        guard let root, wallet.localWallet?.recoveryVerified == true else { return }
        let token = generation
        do {
            guard let invitation = try await MessagingProfileStore.shared.invitation(for: root) else { return }
            let contact = try await ConnectedContact.inspect(invitation)
            guard token == generation, !wallet.locked, self.root == root else { return }
            profile = contact.card; name = contact.name
        } catch { if token == generation { status = nil; self.error = error.localizedDescription } }
    }
    private func enableProfile() {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !displayName.isEmpty, displayName.count <= 40, let root else { return }
        busy = true; error = nil; let token = generation
        Task { @MainActor in
            defer { if token == generation { busy = false } }
            do {
                let context = try await wallet.requireAuthentication("Enable a signed community profile", fresh: true)
                guard token == generation, !wallet.locked else { return }
                let result = try await WalletVault.shared.message(["op":"chat_profile", "name":displayName], context:context)
                guard let invitation = result["invite"] as? String else { throw AppFailure("Missing signed invitation.") }
                let contact = try await ConnectedContact.inspect(invitation)
                guard contact.address == root, token == generation, !wallet.locked else { return }
                try await MessagingProfileStore.shared.save(invitation, for:root)
                profile = contact.card; name = contact.name
                ChatDeliveryDefault.applyOnFirstSetup()
            } catch { if token == generation { status = nil; self.error = error.localizedDescription } }
        }
    }
    private func refresh(automatic: Bool = false) {
        #if DEBUG
        if StoreShots.on {
            let now = Date()
            posts = StoreShots.publicPosts.enumerated().map { index, post in
                let created = now.addingTimeInterval(-post.minutes * 60)
                return Post(id: StoreShots.postID(index), senderID: StoreShots.senderID(post.name), name: post.name, text: post.text,
                            created: created, createdMS: UInt64(created.timeIntervalSince1970 * 1000))
            }
            profile = ["id": StoreShots.ownID, "name": "You"]; name = "You"; status = nil; error = nil
            return
        }
        #endif
        guard !paranoidMode, !busy, !wallet.offlineMode, !wallet.locked else { return }
        busy = true; error = nil; if !automatic { status = "Refreshing room…" }; let token = generation
        Task { @MainActor in
            defer { if token == generation { busy = false } }
            do {
                let tip = try await MessageRelay.shared.communityTip()
                let after = tip > 200 ? tip - 200 : 0
                let page = try await CommunityPaging.load(after:after,through:tip) { cursor in
                    try await MessageRelay.shared.community(after:cursor)
                }
                guard let entries = page["messages"] as? [[String:Any]] else { throw AppFailure("Invalid community response.") }
                var items: [Post] = []
                var screening = PublicChatScreening()
                var previous = after
                for entry in entries {
                    guard let cursor = entry["cursor"] as? NSNumber, cursor.uint64Value > previous,
                          let envelope = entry["envelope"] as? [String:Any] else { throw AppFailure("Community page ordering is invalid.") }
                    previous = cursor.uint64Value
                    let verified = try await NativeCore.shared.call(["op":"chat_group_open", "envelope":envelope, "now_ms":UInt64(Date().timeIntervalSince1970 * 1000)])
                    guard let id = verified["id"] as? String, let sender = verified["sender"] as? [String:Any],
                          let senderID = sender["id"] as? String,
                          let created = verified["created_ms"] as? NSNumber else { throw AppFailure("Invalid signed community message.") }
                    let update=PublicPaymentUpdate(verified["relay_update"] as? [String:Any])
                    guard let text = verified["text"] as? String ?? (update == nil ? nil : "Payment update") else { continue }
                    let displayName = sender["name"] as? String ?? "Member"
                    let createdDate = Date(timeIntervalSince1970: created.doubleValue / 1000)
                    let safetyReason = screening.reason(sender: senderID, name: displayName, text: text, date: createdDate, screenSpam: update == nil)
                    items.append(.init(id:id, senderID:senderID, name:displayName, text:text, update:update, created:createdDate, createdMS:created.uint64Value, safetyReason:safetyReason))
                }
                guard token == generation, !wallet.locked else { return }
                for post in items where post.safetyReason == nil && !blocked.contains(post.senderID) && moderation.restriction(messageID:post.id,identity:post.senderID) == nil {
                    guard token == generation, !wallet.locked, !paranoidMode else { return }
                    if let avatar = SharedAvatar.parse(post.text) {
                        do { try await PeerAvatarStore.shared.accept(avatar,identity:post.senderID,createdMS:post.createdMS,messageID:post.id,scope:"public") }
                        catch { self.error = "Messages loaded, but an avatar could not be saved: " + error.localizedDescription }
                    }
                }
                guard token == generation, !wallet.locked, !paranoidMode else { return }
                posts = Array(items.suffix(30).reversed()); status = "Updated at \(Date().formatted(date:.omitted,time:.standard)). Showing \(posts.count) recent signed posts."
            } catch { if token == generation && !automatic { status = nil; self.error = error.localizedDescription } } // a missed background check stays quiet
        }
    }
    private func shareAvatar() {
        do {
            let avatar = try SharedAvatar.selected(root:root ?? "",holdings:liveData.holdings,listings:liveData.listings,owner:wallet.address,verified:(liveData.holdingsHeight ?? 0) > 0,listingsVerified:(liveData.listingsHeight ?? 0) > 0)
            send(override:try avatar.message())
        } catch { self.error = error.localizedDescription }
    }
    private func send(override: String? = nil) {
        guard !paranoidMode, !busy, let sender = profile, !wallet.offlineMode else { return }
        if moderation.restriction(identity: sender["id"] as? String ?? "") != nil {
            error = "Public posting is restricted. Contact support@koajent.com to appeal."
            return
        }
        let text = (override ?? composedText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard CommunityReply.fits(text) else { error = "The full quote and reply exceed the 4,096-byte room limit. Shorten your message or cancel the quote."; return }
        let displayName = sender["name"] as? String ?? ""
        if let reason = PublicChatSafety.outgoingReason(text: text, name: displayName, history: publicSendHistory, now: ProcessInfo.processInfo.systemUptime) {
            error = reason
            return
        }
        busy = true; error = nil; let token = generation
        Task { @MainActor in
            var refreshAfterPost = false
            defer {
                if token == generation {
                    busy = false
                    if refreshAfterPost { refresh() }
                }
            }
            do {
                let context = try await wallet.requireAuthentication("Publish this public community message")
                guard token == generation, !wallet.locked, !wallet.offlineMode else { return }
                guard moderation.restriction(identity: sender["id"] as? String ?? "") == nil else { throw AppFailure("Public posting was restricted while awaiting authentication.") }
                let result = try await WalletVault.shared.message(["op":"chat_group_seal", "sender":sender, "text":text, "now_ms":UInt64(Date().timeIntervalSince1970 * 1000)], context:context)
                guard let envelope = result["envelope"] as? [String:Any] else { throw AppFailure("Missing signed community packet.") }
                let bytes = try JSONSerialization.data(withJSONObject:envelope, options:.sortedKeys)
                guard token == generation, !wallet.locked, !wallet.offlineMode, !paranoidMode, phase == .active else { return }
                guard moderation.restriction(identity: sender["id"] as? String ?? "") == nil else { throw AppFailure("Public posting is restricted.") }
                try await MessageRelay.shared.send(bytes)
                let sentAt = ProcessInfo.processInfo.systemUptime
                publicSendHistory = publicSendHistory.filter { sentAt - $0.time < 60 }
                publicSendHistory.append((text: text, time: sentAt))
                guard token == generation, !wallet.locked else { return }
                if override == nil { draft = "";replySnippet=nil;composing=false }; status = "Relay accepted the public post. Refreshing room…"
                refreshAfterPost = true
            } catch { if token == generation { status = nil; self.error = error.localizedDescription } }
        }
    }
}

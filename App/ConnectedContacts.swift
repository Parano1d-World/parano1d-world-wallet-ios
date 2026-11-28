import SwiftUI
import UIKit

struct ConnectedContact:Codable,Identifiable {
    let id:String
    let name:String
    let address:String
    let boxKey:String
    let invitation:String
    let approvedAt:Date
    var card:[String:Any] {["id":id,"name":name,"address":address,"box_key":boxKey]}
    static func inspect(_ invitation:String) async throws -> ConnectedContact {
        let options=ScannedContactInvitation.candidates(invitation)
        guard !options.isEmpty else {throw AppFailure("Paste a signed Parano1d contact invitation.")}
        var verified:(uri:String,card:[String:Any])?
        for uri in options {
            if let response=try? await NativeCore.shared.call(["op":"chat_contact","uri":uri]),let card=response["contact"] as? [String:Any] {
                verified=(uri,card);break
            }
        }
        guard let verified else {throw AppFailure("The signed contact invitation is invalid. Ask the sender to share the exact link or QR again.")}
        let uri=verified.uri,card=verified.card
        guard let id=card["id"] as? String,let name=card["name"] as? String,
              let address=card["address"] as? String,AddressValidator.valid(address),let box=card["box_key"] as? String else{throw AppFailure("This invitation does not contain a valid receiving address.")}
        return .init(id:id,name:name,address:address,boxKey:box,invitation:uri,approvedAt:Date())
    }
}
actor ContactBook {
    static let shared=ContactBook()
    static let changed=Notification.Name("ConnectedContactBookChanged")
    private func file() throws -> URL {
        var directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ConnectedContacts",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var values=URLResourceValues();values.isExcludedFromBackup=true;try directory.setResourceValues(values)
        return directory.appendingPathComponent("contacts.json")
    }
    func load() throws -> [ConnectedContact] {
        let path=try file();guard FileManager.default.fileExists(atPath:path.path) else{return []}
        guard (try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=2*1024*1024 else{throw AppFailure("Contact file exceeded its limit.")}
        let contacts=try JSONDecoder().decode([ConnectedContact].self,from:Data(contentsOf:path))
        guard contacts.count<=250,Set(contacts.map(\.id)).count==contacts.count else{throw AppFailure("Invalid contact file.")}
        return contacts.sorted{$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending}
    }
    func approve(_ contact:ConnectedContact) throws {
        var contacts=try load()
        if let old=contacts.first(where:{$0.id==contact.id}),old.address != contact.address || old.boxKey != contact.boxKey {
            throw AppFailure("This contact's receiving address or encryption key changed. Remove the old contact and independently verify the new invitation before adding it.")
        }
        contacts.removeAll{$0.id==contact.id};guard contacts.count<250 else{throw AppFailure("Contact limit reached.")}
        contacts.append(contact);try save(contacts)
    }
    func remove(_ id:String) throws {try save(load().filter{$0.id != id})}
    private func save(_ contacts:[ConnectedContact]) throws {
        try JSONEncoder().encode(contacts).write(to:file(),options:[.atomic,.completeFileProtection])
        NotificationCenter.default.post(name:Self.changed,object:nil)
    }
}

struct ConnectedContactsView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    var select:((ConnectedContact)->Void)?=nil
    var expectedIdentity:String?=nil
    @EnvironmentObject private var wallet:WalletState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @AppStorage(ContactFavorites.storageKey) private var favoriteJSON="[]"
    @State private var favoritesOnly=false
    private var favorites:Set<String> {ContactFavorites.read(favoriteJSON)}
    private var visibleContacts:[ConnectedContact] {
        let search=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return contacts.filter {
            (expectedIdentity == nil || $0.id == expectedIdentity) && (!favoritesOnly || favorites.contains($0.id)) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.address.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }.sorted {
            if favorites.contains($0.id) != favorites.contains($1.id) {return favorites.contains($0.id)}
            return $0.name == $1.name ? $0.id<$1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    @State private var contacts:[ConnectedContact]=[]
    @State private var unreadCounts:[String:Int]=[:]
    @State private var query=""
    @State private var invitation=""
    @State private var myInvitation=""
    @State private var opening:ConnectedContact?
    @State private var openChat=false
    @State private var candidate:ConnectedContact?
    @State private var scanning=false
    /// "theirs" (add their invitation) or "mine" (show my invitation QR for them to scan).
    @State private var addMode="theirs"
    @State private var error:String?
    @State private var busy=false
    @State private var generation=UUID()
    var body:some View {
        List {
            Section {
                VStack(alignment:.leading,spacing:12) {
                    Label("Connect privately",systemImage:"lock.shield.fill")
                        .font(Theme.editorial(26)).foregroundStyle(Theme.mint)
                    Text("Exchange signed invitations with a friend. Each person adds the other's invitation on their own phone.")
                        .font(Theme.subheadline).foregroundStyle(Theme.secondary)
                    HStack(spacing:10) {
                        Label("Show mine",systemImage:"qrcode")
                        Image(systemName:"arrow.left.arrow.right")
                        Label("Scan theirs",systemImage:"qrcode.viewfinder")
                    }.font(Theme.caption).foregroundStyle(Theme.text)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,10)
            }.themedRow(standard: Theme.panel)
            if select == nil {
                Section {
                    Picker("Add contact",selection:$addMode) {
                        Label("Scan theirs",systemImage:"qrcode.viewfinder").tag("theirs")
                        Label("Show mine",systemImage:"qrcode").tag("mine")
                    }.pickerStyle(.segmented).accessibilityLabel("Scan their invitation or show yours")
                }.themedRow()
            }
            if select == nil && addMode == "mine" {
                Section("Your invitation") {
                    if !myInvitation.isEmpty {
                        if let image=ReceiveView.qr(myInvitation) {
                            Image(uiImage:image).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth:260).padding(12).background(.white,in:RoundedRectangle(cornerRadius:14))
                                .frame(maxWidth:.infinity).accessibilityLabel("Your signed contact invitation QR code")
                        }
                        Text("On their phone: Chat → Add contact → Scan theirs, then point it at this code.").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                        ShareLink(item:"Let's connect privately in Parano1d. Add this signed invitation in Chat → Add contact. Then share yours back so we can both connect:\n\(myInvitation)") {
                            Label("Or share it privately",systemImage:"square.and.arrow.up")
                        }
                        Button("Now scan theirs",systemImage:"qrcode.viewfinder") {addMode="theirs";scanning=true}
                    } else {
                        NavigationLink("Set up chat to invite",destination:MessagingView())
                    }
                    Text("This invitation is not posted to the public room.").font(Theme.footnote).foregroundStyle(Theme.secondary)
                }.themedRow()
            } else {
                Section(select == nil ? "Add their invitation" : "Their invitation") {
                    Text("Scan the QR on their phone (Add contact → Show mine), or paste the whole message they sent.").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                    Button("Scan their invitation QR",systemImage:"qrcode.viewfinder") {scanning=true}.buttonStyle(MintButtonStyle())
                    PasteButton(payloadType:String.self) {values in
                        if let pasted=values.first,ScannedContactInvitation.parse(pasted) != nil {invitation=pasted;inspect(pasted)}
                        else {error="Clipboard does not contain a Parano1d contact invitation."}
                    }.accessibilityLabel("Paste signed contact invitation")
                    DisclosureGroup("Enter invitation manually") {
                        TextField("Signed contact invitation",text:$invitation,axis:.vertical).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Check invitation") {inspect(invitation)}.disabled(invitation.isEmpty)
                    }
                }.themedRow()
            }
            if let candidate {
                Section("Confirm \(candidate.name)") {
                    HStack {PeerAvatar(identity:candidate.id,name:candidate.name);Text(candidate.name).font(Theme.headline)}
                    Text(candidate.address).font(.caption.monospaced()).textSelection(.enabled)
                    DisclosureGroup("Full signing identity") {Text(candidate.id).font(.caption.monospaced()).textSelection(.enabled)}
                    Text("Confirm their identity separately before paying.").font(Theme.footnote)
                }.themedRow()
            }
            Section {
                Picker("Contacts filter",selection:$favoritesOnly) {
                    Text("All contacts").tag(false)
                    Label("Favorites",systemImage:"star.fill").tag(true)
                }.pickerStyle(.segmented)
                TextField("Search name, address or identity",text:$query).autocorrectionDisabled().textInputAutocapitalization(.never)
                ForEach(visibleContacts) { contact in
                    let row = HStack(spacing:14) {
                        PeerAvatar(identity:contact.id,name:contact.name,size:44)
                        VStack(alignment:.leading,spacing:5) {Text(contact.name).font(Theme.headline);Text("Connected by invitation").font(Theme.caption).foregroundStyle(Theme.secondary)}
                        if let count=unreadCounts[contact.id],count>0 {Text("\(count)").font(Theme.caption.weight(.bold)).foregroundStyle(Theme.background).padding(.horizontal,8).padding(.vertical,3).background(Theme.mint,in:Capsule()).accessibilityLabel("\(count) unread messages")}
                        Spacer();Image(systemName:"chevron.right").font(Theme.caption)
                    }.foregroundStyle(Theme.text)
                    HStack(spacing:10) {
                        if let select {
                            Button {useSaved(contact,select:select)} label:{row}.buttonStyle(.plain)
                        } else {
                            NavigationLink {ConnectedContactDetail(contact:contact)} label:{row}
                        }
                        ContactFavoriteButton(identity:contact.id,name:contact.name)
                    }.swipeActions(allowsFullSwipe:false) {Button("Remove",role:.destructive){remove(contact.id)}}

                }
                if !contacts.isEmpty && visibleContacts.isEmpty {
                    Text(favoritesOnly ? "No matching favorites. Tap a contact’s star in All contacts to add one." : "No matching contacts.").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                    if favoritesOnly {Button("Show all contacts") {favoritesOnly=false}}
                }
                if contacts.isEmpty {Text("Connect a friend's signed wallet invitation to select them without typing an address.").foregroundStyle(Theme.secondary)}
            }.themedRow()
            Section {Text("Phone numbers only deliver an invitation. They do not verify a wallet or identify its owner.").font(Theme.footnote)}.themedRow()
            if busy {ProgressView()}
            if let error {Text(error).foregroundStyle(.orange)}
        }.scrollContentBackground(.hidden).background(AmbientBackground()).navigationTitle(select == nil ? "Connected contacts" : "Choose recipient")
        // Once their invitation checks out, Add stays in view at the bottom instead of below the list.
        .safeAreaInset(edge:.bottom) {
            if let candidate {
                HStack(spacing:12) {
                    PeerAvatar(identity:candidate.id,name:candidate.name,size:40)
                    VStack(alignment:.leading,spacing:2) {
                        Text(candidate.name).font(Theme.headline).lineLimit(1)
                        Text("Signed invitation checked").font(Theme.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength:8)
                    Button(select == nil ? "Add" : "Use") {approve(candidate)}.buttonStyle(MintButtonStyle()).frame(width:104)
                        .accessibilityLabel(select == nil ? "Add \(candidate.name) as a contact" : "Use \(candidate.name) as the recipient")
                    Button {self.candidate=nil;invitation=""} label:{Image(systemName:"xmark").frame(width:32,height:32)}.accessibilityLabel("Cancel")
                }.padding(14).background(Theme.panel,in:RoundedRectangle(cornerRadius:18))
                    .overlay(RoundedRectangle(cornerRadius:18).stroke(Theme.mint.opacity(0.45),lineWidth:1))
                    .shadow(color:.black.opacity(0.35),radius:14,y:4).padding(.horizontal,12).padding(.bottom,6)
            }
        }
        .disabled(busy || wallet.locked)
        .navigationDestination(isPresented:$openChat) {if let opening {ConnectedContactDetail(contact:opening)}}
        .sheet(isPresented:$scanning){ContactInvitationScanner{uri in invitation=uri;inspect(uri)}}
        .task(id:"\(phase)-\(wallet.accounts.first(where:{$0.index==0})?.address ?? "")-\(wallet.locked)") {
            guard phase == .active,!wallet.locked else{return}
            let token=generation
            do {
                let saved=try await ContactBook.shared.load()
                var own=""
                if let root=wallet.accounts.first(where:{$0.index==0})?.address,
                   let candidate=try await MessagingProfileStore.shared.invitation(for:root),
                   let checked=try? await ConnectedContact.inspect(candidate),checked.address==root {own=candidate}
                guard token==generation,!wallet.locked,!Task.isCancelled else{return}
                contacts=saved;myInvitation=own
                if let checked=try? await ConnectedContact.inspect(own) {
                    unreadCounts=(try? await MessageArchive.shared.unreadCounts(identity:checked.id)) ?? [:]
                }
            }
            catch{if token==generation,!Task.isCancelled{self.error=error.localizedDescription}}
        }
        .onChange(of:wallet.locked){_,locked in if locked{clear()}}
        .onReceive(NotificationCenter.default.publisher(for:.privateMessageArrived)) {_ in Task {await refreshUnread()}}
        .onReceive(NotificationCenter.default.publisher(for:.privateMessageRead)) {_ in Task {await refreshUnread()}}
        .onChange(of:phase){_,value in if value == .background{clear()}}
        .onAppear {
            guard myInvitation.isEmpty,!wallet.locked,phase == .active else{return}
            let token=generation
            Task { @MainActor in
                guard let root=wallet.accounts.first(where:{$0.index==0})?.address,
                      let own=try? await MessagingProfileStore.shared.invitation(for:root),
                      let checked=try? await ConnectedContact.inspect(own),checked.address==root,
                      token==generation,!wallet.locked else{return}
                myInvitation=own
            }
        }
        .onDisappear {if !scanning {clear()}}
        #if DEBUG
        // Simulator screenshots only (-storeShots): a sample invitation QR, and with -storeShotsAddContact
        // a checked sample contact so the pinned Add bar shows. Compiled out of release builds.
        .task {
            guard StoreShots.on else {return}
            try? await Task.sleep(for:.seconds(1))
            myInvitation="paramo1d://contact/sample-invitation-for-screenshots-only"
            if ProcessInfo.processInfo.arguments.contains("-storeShotsAddContact") {candidate=StoreShots.contacts.first}
        }
        #endif
    }
    private func refreshUnread() async {
        guard !wallet.locked,let root=wallet.accounts.first(where:{$0.index==0})?.address,
              let invitation=try? await MessagingProfileStore.shared.invitation(for:root),
              let own=try? await ConnectedContact.inspect(invitation),own.address==root else{return}
        unreadCounts=(try? await MessageArchive.shared.unreadCounts(identity:own.id)) ?? [:]
    }
    private func clear(){generation=UUID();candidate=nil;contacts=[];unreadCounts=[:];invitation="";myInvitation="";query="";scanning=false;busy=false}
    private func inspect(_ uri:String) {
        busy=true;error=nil;let token=generation
        Task { @MainActor in
            defer{if token==generation{busy=false}}
            do{let checked=try await ConnectedContact.inspect(uri);if let expectedIdentity,checked.id != expectedIdentity {throw AppFailure("This invitation does not match the selected public member.")};guard token==generation,!wallet.locked else{return};candidate=checked}
            catch{if token==generation{self.error=error.localizedDescription}}
        }
    }
    private func useSaved(_ saved:ConnectedContact,select:@escaping(ConnectedContact)->Void) {
        busy=true;error=nil;let token=generation
        Task { @MainActor in
            defer{if token==generation{busy=false}}
            do {
                let checked=try await ConnectedContact.inspect(saved.invitation)
                guard checked.id==saved.id,checked.address==saved.address,checked.boxKey==saved.boxKey else{throw AppFailure("Saved contact does not match its signed invitation. Remove and reconnect this contact.")}
                guard token==generation,!wallet.locked else{return}
                select(saved);dismiss()
            }catch{if token==generation{self.error=error.localizedDescription}}
        }
    }
    private func approve(_ contact:ConnectedContact) {
        guard expectedIdentity == nil || contact.id == expectedIdentity else {error="Contact identity mismatch.";return}
        busy=true;let token=generation
        Task { @MainActor in
            defer{if token==generation{busy=false}}
            do {
                _=try await wallet.requireAuthentication("Approve this wallet contact")
                guard token==generation,!wallet.locked else{return}
                try await ContactBook.shared.approve(contact)
                let saved=try await ContactBook.shared.load()
                guard token==generation,!wallet.locked else{return};contacts=saved;candidate=nil;invitation=""
                if let select {select(contact);dismiss()}
                else {opening=contact;openChat=true}
            }catch{if token==generation{self.error=error.localizedDescription}}
        }
    }
    private func remove(_ id:String) {
        busy=true;let token=generation
        Task { @MainActor in
            defer{if token==generation{busy=false}}
            do{try await ContactBook.shared.remove(id);let saved=try await ContactBook.shared.load();guard token==generation,!wallet.locked else{return};contacts=saved;candidate=nil}
            catch{if token==generation{self.error=error.localizedDescription}}
        }
    }
}

private struct ConnectedContactDetail:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let contact:ConnectedContact
    @EnvironmentObject private var wallet:WalletState
    @State private var showReceive=false
    @State private var verified=false
    @State private var error:String?
    @State private var extraAddress=""
    @State private var addressToEdit:SavedWalletAddress?
    @State private var linkedAddresses:[SavedWalletAddress]=[]
    @State private var removingAddress:SavedWalletAddress?
    @State private var myInvitation=""
    @State private var copiedInvitation=false
    private var root:String {wallet.accounts.first(where:{$0.index==0})?.address ?? wallet.address}
    var body:some View {
        Form {
            Section {
                VStack(alignment:.leading,spacing:8) {
                    Label("Added on this phone",systemImage:"checkmark.circle.fill")
                        .font(Theme.editorial(24)).foregroundStyle(Theme.mint)
                    Text("To connect on both phones, make sure \(contact.name) adds your signed invitation too.")
                        .font(Theme.subheadline).foregroundStyle(Theme.secondary)
                }.padding(.vertical,8)
            }.themedRow(standard: Theme.panel)
            Section("Finish connecting") {
                if !myInvitation.isEmpty {
                    ShareLink(item:"I've added your signed invitation in Parano1d. Add mine in Chat → Add contact so we can both open our private chat:\n\(myInvitation)") {
                        Label("Send my invitation back privately",systemImage:"square.and.arrow.up")
                    }.buttonStyle(MintButtonStyle())
                    Button(copiedInvitation ? "Copied invitation" : "Copy my invitation") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text":myInvitation]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(120)])
                        copiedInvitation=true
                    }
                } else {
                    Text("Set up your messaging identity in Chat to share your invitation back.").font(Theme.caption)
                    NavigationLink("Open chat setup") {MessagingView()}
                }
                Text("They open Chat → Add contact and paste the entire message. This does not post to the public room.").font(Theme.footnote).foregroundStyle(Theme.secondary)
            }.themedRow()
            Section("Verified contact card") {
                HStack {PeerAvatar(identity:contact.id,name:contact.name);Text(contact.name).font(Theme.editorial(28));Spacer();ContactFavoriteButton(identity:contact.id,name:contact.name)}
                Text(contact.address).font(.caption.monospaced()).textSelection(.enabled)
                Text("Identity: \(contact.id)").font(.caption.monospaced()).textSelection(.enabled)
                Text("Connected \(contact.approvedAt.formatted())").font(Theme.footnote).foregroundStyle(Theme.secondary)
                Text("A signed invitation authenticates this card. Confirm the identity with your friend through another trusted channel before paying.").font(Theme.footnote)
            }.themedRow()
            Section("Actions") {
                NavigationLink("Send NOID, tokens or NFTs",destination:SendView(initialRecipient:contact.address))
                    .disabled(!verified || wallet.localWallet?.recoveryVerified != true)
                NavigationLink("Request NOID in encrypted chat",destination:MessagingView(initialInvitation:contact.invitation))
                    .disabled(!verified || wallet.localWallet?.recoveryVerified != true)
                Button("Share my receiving address") {showReceive=true}
                NavigationLink("Encrypted chat and saved packets",destination:MessagingView(initialInvitation:contact.invitation)).disabled(!verified)
                ShareLink("Share their public address",item:contact.address).disabled(!verified)
            }.themedRow()
            Section("Additional receiving addresses") {
                Text("These labels are saved on this phone. The signed invitation verifies only the address above; confirm every additional address with this person before paying.").font(Theme.footnote)
                ForEach(linkedAddresses) {entry in
                    HStack {
                        ContactIconView(name:entry.name,icon:entry.icon)
                        VStack(alignment:.leading) {Text(entry.name);Text(SaveableAddress.shortened(entry.address)).font(Theme.caption).textSelection(.enabled)}
                        Spacer()
                        Button("Edit") {addressToEdit=entry}
                        Button("Remove",role:.destructive) {removingAddress=entry}
                    }
                }
                TextField("Additional Parano1d address",text:$extraAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Name address and choose icon") {addressToEdit = .init(address:extraAddress,name:contact.name,favorite:false,contactID:contact.id)}
                    .disabled(!verified || !AddressValidator.valid(extraAddress))
            }.themedRow()
            if let error {Text(error).foregroundStyle(.orange)}
            Section {
                Text("Sharing your address is a request to pay you; it does not create or track a payment request. Saved encrypted packets appear in chat. Confirm payments on chain before treating them as settled.").font(Theme.footnote)
            }.themedRow()
        }.scrollContentBackground(.hidden).background(AmbientBackground())
            .navigationTitle(contact.name)
            .sheet(isPresented:$showReceive){ReceiveView()}
            .sheet(item:$addressToEdit) {entry in SaveWalletAddressView(address:entry.address,contactID:contact.id)}
            .confirmationDialog("Remove this local address?",isPresented:Binding(get:{removingAddress != nil},set:{if !$0{removingAddress=nil}}),presenting:removingAddress) {entry in
                Button("Remove address",role:.destructive) {
                    Task {do {try await WalletAddressBook.shared.remove(entry.address,root:root);await reloadAddresses()} catch {self.error=error.localizedDescription}}
                    removingAddress=nil
                }
            }
            .task {
                do {
                    let checked=try await ConnectedContact.inspect(contact.invitation)
                    guard checked.id==contact.id,checked.address==contact.address,checked.boxKey==contact.boxKey else {throw AppFailure("Saved contact does not match its signed invitation. Remove and reconnect this contact.")}
                    guard !Task.isCancelled,!wallet.locked else{return}
                    verified=true
                    if let ownRoot=wallet.accounts.first(where:{$0.index==0})?.address,
                       let own=try? await MessagingProfileStore.shared.invitation(for:ownRoot),
                       let ownCard=try? await ConnectedContact.inspect(own),ownCard.address==ownRoot {myInvitation=own}
                    await reloadAddresses()
                }catch{if !Task.isCancelled {self.error=error.localizedDescription}}
            }
            .onReceive(NotificationCenter.default.publisher(for:WalletAddressBook.changed).receive(on:RunLoop.main)) {_ in Task {await reloadAddresses()}}
            .onChange(of:wallet.locked){_,locked in if locked{verified=false}}
    }
    private func reloadAddresses() async {
        let scope=root
        guard !wallet.locked else{return}
        do {
            let entries=try await WalletAddressBook.shared.load(root:scope)
            guard !wallet.locked,root==scope else{return}
            linkedAddresses=entries.filter{$0.contactID==contact.id && $0.address != contact.address}
        } catch {if !wallet.locked {self.error=error.localizedDescription}}
    }
}

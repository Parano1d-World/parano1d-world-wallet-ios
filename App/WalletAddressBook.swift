import SwiftUI
import CryptoKit

struct SavedWalletAddress: Codable, Identifiable {
    var id: String { address }
    let address: String
    var name: String
    var favorite: Bool
    var icon: String = "initials"
    var category: String = ""
    var contactID: String? = nil
    init(address:String,name:String,favorite:Bool,icon:String="initials",category:String="",contactID:String?=nil) {
        self.address=address;self.name=name;self.favorite=favorite;self.icon=icon;self.category=category;self.contactID=contactID
    }
    private enum CodingKeys:String,CodingKey {case address,name,favorite,icon,category,contactID}
    init(from decoder:Decoder) throws {
        let row=try decoder.container(keyedBy:CodingKeys.self)
        address=try row.decode(String.self,forKey:.address)
        name=try row.decode(String.self,forKey:.name)
        favorite=try row.decode(Bool.self,forKey:.favorite)
        icon=try row.decodeIfPresent(String.self,forKey:.icon) ?? "initials"
        category=try row.decodeIfPresent(String.self,forKey:.category) ?? ""
        contactID=try row.decodeIfPresent(String.self,forKey:.contactID)
    }
}
enum ContactIcon {
    static let choices:[(String,String)]=[("initials","Name initials"),("person.fill","Person"),("man","Man"),("woman","Woman"),("cpu.fill","GPU / miner"),("laptopcomputer","Laptop"),("desktopcomputer","Desktop"),("iphone","Phone"),("globe","Website"),("gamecontroller.fill","Controller"),("building.2.fill","Business"),("house.fill","Home")]
    static func valid(_ value:String)->Bool {choices.contains{$0.0==value}}
}
struct SavedContactCategory:Codable,Identifiable {
    var id:String {name}
    var name:String
    var icon:String
}
actor WalletAddressBook {
    static let shared = WalletAddressBook()
    static let changed = Notification.Name("WalletAddressBookChanged")
    private func file(root: String) throws -> URL {
        guard AddressValidator.valid(root) else { throw AppFailure("Unlock your wallet to use its address book.") }
        var folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("WalletAddressBook", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey:FileProtectionType.complete])
        var values=URLResourceValues(); values.isExcludedFromBackup=true; try folder.setResourceValues(values)
        let key=SHA256.hash(data:Data(root.utf8)).map{String(format:"%02x",$0)}.joined()
        return folder.appendingPathComponent(key+".json")
    }
    func load(root: String) throws -> [SavedWalletAddress] {
        let url=try file(root:root)
        guard FileManager.default.fileExists(atPath:url.path) else {return []}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<100_000 else {throw AppFailure("Address book exceeds size limit.")}
        let entries=try JSONDecoder().decode([SavedWalletAddress].self,from:Data(contentsOf:url))
        guard entries.count<=250, Set(entries.map(\.address)).count==entries.count,
              entries.allSatisfy({AddressValidator.valid($0.address) && !$0.name.isEmpty && $0.name.count<=60 && ContactIcon.valid($0.icon) && $0.category.count<=40 && ($0.contactID?.count ?? 0)<=128}) else {throw AppFailure("Invalid saved address book.")}
        return entries.sorted { $0.favorite != $1.favorite ? $0.favorite : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func save(_ entry: SavedWalletAddress, root: String) throws {
        let name=entry.name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard AddressValidator.valid(entry.address), !name.isEmpty, name.count<=60,ContactIcon.valid(entry.icon),entry.category.count<=40,(entry.contactID?.count ?? 0)<=128 else {throw AppFailure("Enter a valid name, icon, category, and address.")}
        var entries=try load(root:root)
        if let existing=entries.first(where:{$0.address==entry.address}),let current=existing.contactID,
           let proposed=entry.contactID,current != proposed {throw AppFailure("This address belongs to another contact. Remove it there before assigning it here.")}
        entries.removeAll{$0.address==entry.address}
        guard entries.count<250 else {throw AppFailure("Address book is full.")}
        entries.append(.init(address:entry.address,name:name,favorite:entry.favorite,icon:entry.icon,category:entry.category,contactID:entry.contactID))
        try JSONEncoder().encode(entries).write(to:file(root:root),options:[.atomic,.completeFileProtection])
        NotificationCenter.default.post(name:Self.changed,object:nil)
    }
    func remove(_ address:String,root:String) throws {
        let entries=try load(root:root).filter{$0.address != address}
        try JSONEncoder().encode(entries).write(to:file(root:root),options:[.atomic,.completeFileProtection])
        NotificationCenter.default.post(name:Self.changed,object:nil)
    }
    private func categoriesFile(root:String) throws -> URL {try file(root:root).deletingLastPathComponent().appendingPathComponent("categories-"+SHA256.hash(data:Data(root.utf8)).map{String(format:"%02x",$0)}.joined()+".json")}
    func categories(root:String) throws -> [SavedContactCategory] {
        let url=try categoriesFile(root:root)
        guard FileManager.default.fileExists(atPath:url.path) else{return []}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<20_000 else{throw AppFailure("Contact categories exceed size limit.")}
        let values=try JSONDecoder().decode([SavedContactCategory].self,from:Data(contentsOf:url))
        guard values.count<=30,Set(values.map(\.name)).count==values.count,values.allSatisfy({!$0.name.isEmpty && $0.name.count<=40 && ContactIcon.valid($0.icon)}) else{throw AppFailure("Invalid contact categories.")}
        return values
    }
    func saveCategory(_ value:SavedContactCategory,root:String) throws {
        let name=value.name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=40,ContactIcon.valid(value.icon) else{throw AppFailure("Enter a category name and icon.")}
        var values=try categories(root:root);values.removeAll{$0.name==name}
        guard values.count<30 else{throw AppFailure("Too many categories.")}
        values.append(.init(name:name,icon:value.icon))
        try JSONEncoder().encode(values).write(to:categoriesFile(root:root),options:[.atomic,.completeFileProtection])
        NotificationCenter.default.post(name:Self.changed,object:nil)
    }
}
struct SaveWalletAddressView: View {
    let address: String
    var contactID:String?=nil
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var favorite=false
    @State private var icon="initials"
    @State private var category=""
    @State private var associatedContactID:String?=nil
    @State private var categories:[SavedContactCategory]=[]
    @State private var error:String?
    @State private var saving=false
    private var root:String {wallet.accounts.first(where:{$0.index==0})?.address ?? wallet.address}
    var body: some View {
        NavigationStack {
            Form {
                Section("Full receiving address") { Text(address).font(Theme.footnote).textSelection(.enabled) }.themedRow()
                TextField("Name",text:$name)
                Toggle("Favorite",isOn:$favorite)
                Picker("Contact icon",selection:$icon) {
                    ForEach(ContactIcon.choices.indices,id:\.self) {index in
                        let value=ContactIcon.choices[index]
                        Text(value.1).tag(value.0)
                    }
                }
                Picker("Category",selection:$category) {
                    Text("None").tag("")
                    ForEach(categories) {value in Text(value.name).tag(value.name)}
                }
                NavigationLink("Manage categories") {ContactCategoryEditor()}
                Text("Saved locally for this wallet. A saved name does not verify ownership or create a chat contact. Check the full address through a trusted channel.").font(Theme.footnote)
                if let error {Text(error).foregroundStyle(.orange)}
                Button(saving ? "Saving…" : "Save address") {
                    let scope=root
                    saving=true
                    Task { @MainActor in
                        defer {saving=false}
                        do {
                            guard !wallet.locked else {throw AppFailure("Unlock first.")}
                            try await WalletAddressBook.shared.save(.init(address:address,name:name,favorite:favorite,icon:icon,category:category,contactID:associatedContactID ?? contactID),root:scope)
                            if !wallet.locked && root==scope {dismiss()}
                        } catch {self.error=error.localizedDescription}
                    }
                }.disabled(saving || wallet.locked || !AddressValidator.valid(address) || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || name.count>60)
            }.navigationTitle("Save address").navigationBarTitleDisplayMode(.inline).keyboardDismissControl()
                .scrollContentBackground(.hidden).background(AmbientBackground())
                .toolbar {ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}}
                .task {
                    let scope=root
                    if let entries=try? await WalletAddressBook.shared.load(root:scope),!wallet.locked,root==scope,
                       let entry=entries.first(where:{$0.address==address}) {name=entry.name;favorite=entry.favorite;icon=entry.icon;category=entry.category;associatedContactID=entry.contactID}
                    categories=(try? await WalletAddressBook.shared.categories(root:scope)) ?? []
                }
                .onReceive(NotificationCenter.default.publisher(for:WalletAddressBook.changed).receive(on:RunLoop.main)) {_ in
                    Task {categories=(try? await WalletAddressBook.shared.categories(root:root)) ?? []}
                }
                .onChange(of:wallet.locked){_,locked in if locked {dismiss()}}
        }
    }
}
struct SaveableAddress: View {
    let address:String
    var prefix=""
    @State private var save=false
    static func shortened(_ address:String)->String {String(address.prefix(9))+"…"+String(address.suffix(6))}
    var body: some View {
        if AddressValidator.valid(address) {
            Button {save=true} label: {Label(prefix+Self.shortened(address),systemImage:"person.crop.circle.badge.plus").font(Theme.caption)}
                .accessibilityLabel(prefix+address+". View and save address")
                .sheet(isPresented:$save){SaveWalletAddressView(address:address)}
        }
    }
}
struct WalletAddressBookView: View {
    var select:((String)->Void)?=nil
    @EnvironmentObject private var wallet:WalletState
    @State private var entries:[SavedWalletAddress]=[]
    @State private var query=""
    @State private var address=""
    @State private var adding=false
    @State private var error:String?
    @State private var removing:SavedWalletAddress?
    @State private var editing:SavedWalletAddress?
    @State private var contacts:[ConnectedContact]=[]
    private var root:String {wallet.accounts.first(where:{$0.index==0})?.address ?? wallet.address}
    var body:some View {
        List {
            Section("Connected contacts") {
                ForEach(contacts.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query)},id:\.id) {contact in
                    HStack {
                        PeerAvatar(identity:contact.id,name:contact.name,size:40)
                        VStack(alignment:.leading) {Text(contact.name);Text(SaveableAddress.shortened(contact.address)).font(Theme.caption)}
                        Spacer()
                        Button("Edit") {editing = .init(address:contact.address,name:contact.name,favorite:false,contactID:contact.id)}
                        if let select {Button("Use") {select(contact.address)}}
                    }
                }
            }.themedRow()
            Section("Saved addresses") {
                ForEach(entries.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query)}) {entry in
                    HStack {
                        if entry.favorite {Image(systemName:"star.fill").foregroundStyle(.yellow)}
                        ContactIconView(name:entry.name,icon:entry.icon)
                        VStack(alignment:.leading) {Text(entry.name).font(Theme.headline);SaveableAddress(address:entry.address)}
                        Spacer()
                        Button("Edit") {editing=entry}
                        if let select {Button("Use"){select(entry.address)}}
                    }.swipeActions(allowsFullSwipe:false){Button("Remove",role:.destructive){removing=entry}}
                }
                if entries.isEmpty {Text("Save an address from history or paste one below.").font(Theme.caption)}
            }.themedRow()
            Section("Add address") {
                TextField("Parano1d address",text:$address).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Name and save"){adding=true}.disabled(!AddressValidator.valid(address))
            }.themedRow()
            Section {NavigationLink("Contact categories") {ContactCategoryEditor()}}.themedRow()
            if let error {Text(error).foregroundStyle(.orange)}
        }.navigationTitle("Address book").navigationBarTitleDisplayMode(.inline).searchable(text:$query,prompt:"Name or address").keyboardDismissControl()
            .scrollContentBackground(.hidden).background(AmbientBackground())
            .sheet(isPresented:$adding){SaveWalletAddressView(address:address)}
            .sheet(item:$editing) {entry in SaveWalletAddressView(address:entry.address,contactID:entry.contactID)}
            .confirmationDialog("Remove saved address?",isPresented:Binding(get:{removing != nil},set:{if !$0{removing=nil}}),titleVisibility:.visible,presenting:removing) {entry in
                Button("Remove",role:.destructive){Task {do {try await WalletAddressBook.shared.remove(entry.address,root:root);await reload()}catch{self.error=error.localizedDescription}};removing=nil}
            }
            .task(id:root){await reload()}
            .onReceive(NotificationCenter.default.publisher(for:WalletAddressBook.changed).receive(on:RunLoop.main)){_ in Task{await reload()}}
            .onReceive(NotificationCenter.default.publisher(for:ContactBook.changed).receive(on:RunLoop.main)){_ in Task{await reload()}}
            .onChange(of:wallet.locked){_,locked in if locked{entries=[];query="";address="";adding=false}}
    }
    private func reload() async {
        guard !wallet.locked else{return}
        let scope=root
        do {
            let loaded=try await WalletAddressBook.shared.load(root:scope)
            guard !wallet.locked,root==scope else{return}
            entries=loaded;error=nil
        }catch {if !wallet.locked && root==scope {self.error=error.localizedDescription}}
        do {
            let connected=try await ContactBook.shared.load()
            guard !wallet.locked,root==scope else{return}
            contacts=connected
        }catch {if !wallet.locked && root==scope {self.error=error.localizedDescription}}
    }
}

struct ContactIconView:View {
    let name:String
    let icon:String
    var size:CGFloat=40
    var body:some View {
        Group {
            if icon == "initials" {ChatAvatar(name:name,size:size)}
            else if icon == "man" || icon == "woman" {
                Text(icon == "man" ? "👨" : "👩").font(.system(size:size*0.6))
                    .frame(width:size,height:size).background(Theme.mint.opacity(0.12),in:Circle())
            }
            else {Image(systemName:icon).font(.system(size:size*0.46,weight:.medium)).foregroundStyle(Theme.mint)
                .frame(width:size,height:size).background(Theme.mint.opacity(0.12),in:Circle())}
        }.accessibilityLabel(icon == "initials" ? name : (ContactIcon.choices.first{$0.0==icon}?.1 ?? "Contact")+" icon")
    }
}

struct ContactCategoryEditor:View {
    @EnvironmentObject private var wallet:WalletState
    @AppStorage("send.contactCategoriesVisible") private var showInSend=true
    @State private var values:[SavedContactCategory]=[]
    @State private var name=""
    @State private var icon="initials"
    @State private var error:String?
    private var root:String {wallet.accounts.first(where:{$0.index==0})?.address ?? wallet.address}
    var body:some View {
        Form {
            Toggle("Group contacts in Quick Send",isOn:$showInSend)
            Section("Categories") {
                ForEach(values) {value in
                    HStack {
                        ContactIconView(name:value.name,icon:value.icon)
                        Text(value.name)
                        Spacer()
                        Button("Edit icon") {name=value.name;icon=value.icon}
                    }
                }
                if values.isEmpty {Text("Create a category to organize your contacts.")}
            }.themedRow()
            Section("New category") {
                TextField("Name",text:$name)
                Picker("Icon",selection:$icon) {
                    ForEach(ContactIcon.choices.indices,id:\.self) {index in
                        let choice=ContactIcon.choices[index]
                        Text(choice.1).tag(choice.0)
                    }
                }
                Button("Save category") {
                    let scope=root
                    Task {do {try await WalletAddressBook.shared.saveCategory(.init(name:name,icon:icon),root:scope);values=try await WalletAddressBook.shared.categories(root:scope);name="";error=nil}catch{self.error=error.localizedDescription}}
                }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }.themedRow()
            if let error {Text(error).foregroundStyle(.orange)}
        }.navigationTitle("Contact categories").task(id:root){values=(try? await WalletAddressBook.shared.categories(root:root)) ?? []}
            .scrollContentBackground(.hidden).background(AmbientBackground())
    }
}

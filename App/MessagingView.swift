import LocalAuthentication
import SwiftUI
import MessageUI
import UIKit
import CryptoKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let privateMessageArrived=Notification.Name("Parano1dPrivateMessageArrived")
    static let privateMessageRead=Notification.Name("Parano1dPrivateMessageRead")
}

/// Signed public invitation only; never contains the master key or plaintext.
actor MessagingProfileStore {
    static let shared=MessagingProfileStore()
    private func location(_ root:String) throws -> URL {
        guard AddressValidator.valid(root) else{throw AppFailure("Invalid wallet identity.")}
        let base=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("MessagingProfiles",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var directory=base;var values=URLResourceValues();values.isExcludedFromBackup=true;try directory.setResourceValues(values)
        let suffix=SHA256.hash(data:Data(root.utf8)).map{String(format:"%02x",$0)}.joined()
        return base.appendingPathComponent(suffix+".txt")
    }
    func invitation(for root:String) throws -> String? {
        let url=try location(root)
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=4096 else{throw AppFailure("Stored invitation is invalid.")}
        return try String(contentsOf:url,encoding:.utf8)
    }
    func save(_ invitation:String,for root:String) throws {
        guard invitation.utf8.count<=4096,ScannedContactInvitation.parse(invitation) != nil else{throw AppFailure("Invalid invitation.")}
        try invitation.write(to:location(root),atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:location(root).path)
    }
}

/// Public contact cards and encrypted signed packets.
///
/// Version 2 layout (per identity, all files complete-protected and excluded from backup):
/// - `<id>.json`          accepted conversations (shown in chat), read state, cursor, tombstones.
/// - `<id>.older.json`    older messages rolled out of long conversations (still viewable).
/// - `<id>.requests.json` signed messages from senders who are not contacts and whom you
///                        never messaged; shown only under Message requests.
/// Nothing here ever blocks sending or stops the inbox cursor because history is long.
actor MessageArchive {
    static let shared=MessageArchive()
    private let directory:URL?
    /// Contact IDs supplied by tests; the app reads the contact book.
    private let contactsOverride:Set<String>?
    init(directory:URL?=nil,contacts:Set<String>?=nil) {self.directory=directory;self.contactsOverride=contacts}
    struct Packet:Codable,Identifiable {
        let id:String
        let contactID:String
        let received:Bool
        let date:Date
        let envelope:Data
    }
    /// A deleted or dropped message ID, remembered until the signed packet can no longer
    /// be delivered (envelopes live at most 7 days), so a resend is ignored.
    struct Tombstone:Codable {let id:String;let until:Date}
    static let perConversation=500, mainTotal=5000, mainBytes=12*1024*1024
    static let olderTotal=20000, olderBytes=64*1024*1024
    static let requestsPerSender=20, requestsTotal=200, requestsBytes=8*1024*1024
    static let tombstoneLimit=20000, tombstoneLifetime:TimeInterval=8*24*60*60
    private struct Archive:Codable {
        var version=2;var packets:[Packet]=[];var cursor:UInt64?=nil;var readIDs:[String]?=nil
        var deletedIDs:[String]?=nil   // version 1 only; migrated into tombstones
        var tombstones:[Tombstone]?=nil
        /// Senders whose messages go to chat even if they aren't (or are no longer) contacts:
        /// anyone already in your history, accepted from an invitation, or replied to.
        var acceptedSenders:[String]?=nil
        var conversationOrder:[String]?=nil;var archivedContactIDs:[String]?=nil
    }
    private struct Side:Codable {var version=2;var packets:[Packet]=[]}
    enum Kind {case main,older,requests}
    private func base() throws -> URL {
        let base=try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("Messages",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var url=base;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
        return base
    }
    private func location(_ identity:String,_ kind:Kind = .main) throws -> URL {
        guard identity.count==64,Data(hex:identity)?.count==32 else {throw AppFailure("Invalid messaging identity.")}
        switch kind {
        case .main: return try base().appendingPathComponent(identity+".json")
        case .older: return try base().appendingPathComponent(identity+".older.json")
        case .requests: return try base().appendingPathComponent(identity+".requests.json")
        }
    }
    private func write<T:Encodable>(_ value:T,_ identity:String,_ kind:Kind,limit:Int) throws {
        let data=try JSONEncoder().encode(value)
        guard data.count<=limit else {throw AppFailure("Message storage exceeded its limit. Nothing was overwritten.")}
        try data.write(to:location(identity,kind),options:[.atomic,.completeFileProtection])
    }
    private func snapshot(identity:String) throws -> Archive {
        let url=try location(identity)
        guard FileManager.default.fileExists(atPath:url.path) else{return Archive()}
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size<=16*1024*1024 else {throw AppFailure("Message archive exceeded its limit.")}
        var archive=try JSONDecoder().decode(Archive.self,from:Data(contentsOf:url))
        let order=archive.conversationOrder ?? [],archived=archive.archivedContactIDs ?? []
        let limit=archive.version==1 ? 500 : Self.mainTotal
        guard archive.version==1 || archive.version==2,archive.packets.count<=limit,(archive.deletedIDs ?? []).count<=5000,
              (archive.tombstones ?? []).count<=Self.tombstoneLimit,
              order.count<=500,archived.count<=500,Set(order).count==order.count,Set(archived).count==archived.count,
              Set(archive.packets.map(\.id)).count==archive.packets.count else {throw AppFailure("Message archive is invalid. It was not overwritten.")}
        if archive.version==1 {
            // Upgrade in memory (version stays 1 until saved, so refresh() can tell).
            let until=Date().addingTimeInterval(Self.tombstoneLifetime)
            archive.tombstones=(archive.deletedIDs ?? []).map{Tombstone(id:$0,until:until)}
            archive.deletedIDs=nil
        }
        return archive
    }
    private func side(_ identity:String,_ kind:Kind) throws -> Side {
        let url=try location(identity,kind)
        guard FileManager.default.fileExists(atPath:url.path) else{return Side()}
        let limit=kind == .older ? Self.olderBytes : Self.requestsBytes
        if (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)>limit+1024*1024 {
            let aside=url.deletingPathExtension().appendingPathExtension("oversized-\(Int(Date().timeIntervalSince1970)).json")
            try FileManager.default.moveItem(at:url,to:aside);return Side()
        }
        let data=try Data(contentsOf:url) // a read error is reported, never treated as damage
        if let value=try? JSONDecoder().decode(Side.self,from:data),value.version==2 {
            var unique=Set<String>();var copy=value;copy.packets=value.packets.filter{unique.insert($0.id).inserted}
            return copy
        }
        // A damaged side file is kept aside (never overwritten) so chat keeps working.
        let aside=url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at:url,to:aside)
        return Side()
    }
    /// A contact-book read error stops the import (nothing is mis-filed as a request).
    private func contactIDs() async throws -> Set<String> {
        if let contactsOverride {return contactsOverride}
        return Set(try await ContactBook.shared.load().map(\.id))
    }
    /// Senders whose messages go straight into chat: contacts, and anyone you have messaged.
    private func accepted(_ archive:Archive,contacts:Set<String>) -> Set<String> {
        // Before acceptedSenders existed, everyone already in your history counts as accepted.
        contacts.union(archive.acceptedSenders ?? archive.packets.map(\.contactID)).union(archive.packets.filter{!$0.received}.map(\.contactID))
    }
    private func remember(_ senders:[String],in archive:inout Archive) {
        var set=Set(archive.acceptedSenders ?? archive.packets.map(\.contactID));let before=set.count
        set.formUnion(senders.filter{!$0.isEmpty})
        if set.count != before {archive.acceptedSenders=Array(set).sorted()}
    }
    private func live(_ archive:inout Archive) -> Set<String> {
        let now=Date()
        var stones=(archive.tombstones ?? []).filter{$0.until>now}
        if stones.count>Self.tombstoneLimit {stones=Array(stones.sorted{$0.until>$1.until}.prefix(Self.tombstoneLimit))}
        archive.tombstones=stones
        return Set(stones.map(\.id))
    }
    private func bury(_ ids:[String],in archive:inout Archive) {
        guard !ids.isEmpty else{return}
        let until=Date().addingTimeInterval(Self.tombstoneLifetime)
        let set=Set(ids)
        var stones=(archive.tombstones ?? []).filter{!set.contains($0.id)}
        stones.append(contentsOf:ids.map{Tombstone(id:$0,until:until)})
        archive.tombstones=stones;_=live(&archive)
    }
    /// Move the oldest messages of over-long conversations to Older messages, then save.
    /// Never refuses because history is long.
    private func save(_ archive:inout Archive,identity:String) throws {
        // Record who is already in your history before anything is rolled to Older messages.
        if archive.acceptedSenders==nil {archive.acceptedSenders=Array(Set(archive.packets.map(\.contactID))).sorted()}
        func size(_ a:Archive) -> Int {(try? JSONEncoder().encode(a).count) ?? Int.max}
        var moved:[Packet]=[]
        var counts:[String:Int]=[:];for p in archive.packets {counts[p.contactID,default:0]+=1}
        let ordered=archive.packets.sorted{$0.date == $1.date ? $0.id < $1.id : $0.date < $1.date}
        var keep:[Packet]=[]
        // Roll in batches (down to 80%) so a long conversation isn't rewritten on every message.
        let conversationTarget=Self.perConversation*4/5,totalTarget=Self.mainTotal*4/5
        var over=Set<String>();for (id,n) in counts where n>Self.perConversation {over.insert(id)}
        for p in ordered {
            if over.contains(p.contactID),counts[p.contactID,default:0]>conversationTarget {counts[p.contactID]!-=1;moved.append(p)} else {keep.append(p)}
        }
        if keep.count>Self.mainTotal {while keep.count>totalTarget {moved.append(keep.removeFirst())}}
        archive.packets=keep
        // Estimate first (base64 is 4/3 of the bytes) so long histories aren't re-encoded per message.
        func estimate(_ p:Packet) -> Int {p.envelope.count*4/3+p.id.utf8.count+p.contactID.utf8.count+96}
        var total=archive.packets.reduce(0){$0+estimate($1)}
        let byteTarget=total>Self.mainBytes ? Self.mainBytes*4/5 : Self.mainBytes
        while total>byteTarget,!archive.packets.isEmpty {
            let p=archive.packets.removeFirst();total-=estimate(p);moved.append(p)
        }
        if total>Self.mainBytes*3/4 {
            while size(archive)>Self.mainBytes,!archive.packets.isEmpty {moved.append(archive.packets.removeFirst())}
        }
        if !moved.isEmpty {
            var older=try side(identity,.older)
            let known=Set(older.packets.map(\.id))
            older.packets.append(contentsOf:moved.filter{!known.contains($0.id)})
            older.packets.sort{$0.date == $1.date ? $0.id < $1.id : $0.date < $1.date}
            if older.packets.count>Self.olderTotal {older.packets.removeFirst(older.packets.count-Self.olderTotal)}
            while ((try? JSONEncoder().encode(older).count) ?? Int.max)>Self.olderBytes,!older.packets.isEmpty {older.packets.removeFirst(max(1,older.packets.count/20))}
            // Older messages are written first: a crash between the two writes leaves a
            // duplicate (ignored when reading), never a lost message.
            try write(older,identity,.older,limit:Self.olderBytes)
            let movedIDs=Set(moved.map(\.id))
            archive.readIDs=archive.readIDs?.filter{!movedIDs.contains($0)}
            // A relay may still carry a rolled-out message; don't let it return as new.
            bury(moved.map(\.id),in:&archive)
        }
        archive.version=2;archive.deletedIDs=nil
        try write(archive,identity,.main,limit:16*1024*1024)
    }
    private func saveRequests(_ requests:inout Side,identity:String) throws {
        var unique=Set<String>();requests.packets=requests.packets.filter{unique.insert($0.id).inserted}
        var bySender:[String:[Packet]]=[:]
        for p in requests.packets {bySender[p.contactID,default:[]].append(p)}
        var kept:[Packet]=[]
        for (_,list) in bySender {kept.append(contentsOf:list.sorted{$0.date<$1.date}.suffix(Self.requestsPerSender))}
        kept.sort{$0.date == $1.date ? $0.id < $1.id : $0.date < $1.date}
        if kept.count>Self.requestsTotal {kept.removeFirst(kept.count-Self.requestsTotal)}
        requests.packets=kept
        while ((try? JSONEncoder().encode(requests).count) ?? Int.max)>Self.requestsBytes,!requests.packets.isEmpty {requests.packets.removeFirst()}
        try write(requests,identity,.requests,limit:Self.requestsBytes)
    }
    /// Sort incoming signed messages: blocked senders are dropped (never saved or notified),
    /// contacts and people you messaged go to chat, everyone else goes to Message requests.
    /// Returns the messages that went to chat (the only ones that may notify).
    private func place(_ incoming:[Packet],archive:inout Archive,requests:inout Side,contacts:Set<String>) -> [Packet] {
        let buried=live(&archive)
        var seen=Set(archive.packets.map(\.id)).union(buried).union(requests.packets.map(\.id))
        let allowed=accepted(archive,contacts:contacts)
        var toChat:[Packet]=[],dropped:[String]=[]
        for packet in incoming {
            guard seen.insert(packet.id).inserted else{continue}
            if packet.received && PrivateChatBlocks.contains(packet.contactID) {dropped.append(packet.id);continue}
            if !packet.received || allowed.contains(packet.contactID) {
                archive.packets.append(packet);remember([packet.contactID],in:&archive)
                if packet.received {toChat.append(packet)}
            }
            else {requests.packets.append(packet)}
        }
        bury(dropped,in:&archive)
        return toChat
    }
    /// Ongoing tidy-up: discard requests from blocked senders and bring requests from newly
    /// accepted senders (contacts, people you replied to) into chat. Returns true if changed.
    private func reconcile(_ archive:inout Archive,_ requests:inout Side,contacts:Set<String>) -> Bool {
        var changed=false
        // Chat history already saved from a blocked contact is kept (hidden, as before) so
        // unblocking restores it; only requests from blocked senders are discarded.
        let blocked=requests.packets.filter{PrivateChatBlocks.contains($0.contactID)}.map(\.id)
        if !blocked.isEmpty {
            let ids=Set(blocked);requests.packets.removeAll{ids.contains($0.id)}
            bury(blocked,in:&archive);changed=true
        }
        // Saved chat history is never moved into requests; only new messages are sorted.
        let allowed=accepted(archive,contacts:contacts)
        let promoted=requests.packets.filter{allowed.contains($0.contactID)}
        if !promoted.isEmpty {
            let ids=Set(promoted.map(\.id)),known=Set(archive.packets.map(\.id))
            requests.packets.removeAll{ids.contains($0.id)}
            archive.packets.append(contentsOf:promoted.filter{!known.contains($0.id)});changed=true
            remember(promoted.map(\.contactID),in:&archive)
        }
        return changed
    }
    /// Apply blocks and contact changes to saved messages (cheap when nothing changed).
    func refresh(identity:String) async throws {
        let contacts=try await contactIDs()
        var archive=try snapshot(identity:identity)
        var requests=try side(identity,.requests)
        let needsUpgrade=archive.version==1 || archive.acceptedSenders==nil
        let changed=reconcile(&archive,&requests,contacts:contacts)
        guard changed || needsUpgrade else{return}
        try saveRequests(&requests,identity:identity)
        try save(&archive,identity:identity)
        NotificationCenter.default.post(name:.privateMessageRead,object:nil)
    }
    func packets(identity:String) throws -> [Packet] {try snapshot(identity:identity).packets}
    /// Older messages of one conversation, newest first.
    func olderPackets(identity:String,contactID:String) throws -> [Packet] {
        let main=Set(try snapshot(identity:identity).packets.map(\.id))
        return try side(identity,.older).packets.filter{$0.contactID==contactID && !main.contains($0.id)}.reversed()
    }
    func olderCount(identity:String,contactID:String) throws -> Int {try olderPackets(identity:identity,contactID:contactID).count}
    func requestPackets(identity:String) throws -> [Packet] {
        try side(identity,.requests).packets.filter{!PrivateChatBlocks.contains($0.contactID)}
    }
    /// Opening a verified invitation for someone accepts them: their requests move into chat.
    func accept(identity:String,senderID:String) throws -> Bool {
        guard !PrivateChatBlocks.contains(senderID) else{return false}
        var requests=try side(identity,.requests)
        let moving=requests.packets.filter{$0.contactID==senderID}
        guard !moving.isEmpty else{return false}
        var archive=try snapshot(identity:identity)
        let known=Set(archive.packets.map(\.id))
        archive.packets.append(contentsOf:moving.filter{!known.contains($0.id)})
        remember([senderID],in:&archive)
        requests.packets.removeAll{$0.contactID==senderID}
        try save(&archive,identity:identity)
        try saveRequests(&requests,identity:identity)
        return true
    }
    /// Remove all requests from one sender (Delete or Block); a resend is ignored.
    func discardRequests(identity:String,senderID:String) throws {
        var requests=try side(identity,.requests)
        let ids=requests.packets.filter{$0.contactID==senderID}.map(\.id)
        guard !ids.isEmpty else{return}
        var archive=try snapshot(identity:identity)
        requests.packets.removeAll{$0.contactID==senderID}
        bury(ids,in:&archive)
        try saveRequests(&requests,identity:identity)
        try save(&archive,identity:identity)
        NotificationCenter.default.post(name:.privateMessageRead,object:nil)
    }
    func conversationPreferences(identity:String) throws -> (order:[String],archived:Set<String>) {
        let archive=try snapshot(identity:identity)
        return (archive.conversationOrder ?? [],Set(archive.archivedContactIDs ?? []))
    }
    func setConversationOrder(identity:String,order:[String]) throws {
        guard order.count<=500,Set(order).count==order.count else{throw AppFailure("Conversation order is invalid.")}
        var archive=try snapshot(identity:identity)
        archive.conversationOrder=order
        try save(&archive,identity:identity)
    }
    func setArchived(identity:String,contactID:String,archived:Bool) throws {
        var archive=try snapshot(identity:identity)
        var ids=Set(archive.archivedContactIDs ?? [])
        if archived {guard ids.contains(contactID) || ids.count<500 else{throw AppFailure("Too many archived conversations.")};ids.insert(contactID)}
        else {ids.remove(contactID)}
        archive.archivedContactIDs=Array(ids).sorted()
        try save(&archive,identity:identity)
    }
    func deleteConversation(identity:String,contactID:String) throws {
        var archive=try snapshot(identity:identity)
        let removed=archive.packets.filter{$0.contactID==contactID}.map(\.id)
        archive.packets.removeAll{$0.contactID==contactID}
        archive.readIDs?.removeAll{removed.contains($0)}
        bury(removed,in:&archive)
        // Older messages of this conversation go too.
        var older=try side(identity,.older)
        let olderIDs=older.packets.filter{$0.contactID==contactID}.map(\.id)
        if !olderIDs.isEmpty {older.packets.removeAll{$0.contactID==contactID};try write(older,identity,.older,limit:Self.olderBytes);bury(olderIDs,in:&archive)}
        try save(&archive,identity:identity)
        NotificationCenter.default.post(name:.privateMessageRead,object:nil)
    }
    func cursor(identity:String) throws -> UInt64 {try snapshot(identity:identity).cursor ?? 0}
    func unreadCounts(identity:String) throws -> [String:Int] {
        let archive=try snapshot(identity:identity)
        let read=Set(archive.readIDs ?? [])
        var result:[String:Int]=[:]
        for packet in archive.packets where packet.received && !read.contains(packet.id) {
            result[packet.contactID,default:0]+=1
        }
        return result
    }
    func markRead(identity:String,contactID:String,packetIDs:[String]) throws {
        guard !packetIDs.isEmpty else{return}
        var archive=try snapshot(identity:identity)
        let known=Set(archive.packets.filter{$0.received && $0.contactID==contactID}.map(\.id))
        let previous=Set(archive.readIDs ?? [])
        let read=previous.union(packetIDs.filter{known.contains($0)})
        guard read.count != previous.count else{return} // nothing new (or an older message)
        archive.readIDs=Array(read).sorted()
        try save(&archive,identity:identity)
        NotificationCenter.default.post(name:.privateMessageRead,object:nil)
    }
    /// A local deletion does not retract an already delivered signed packet.
    /// Retain its ID to prevent a nearby retransmission from restoring it.
    func delete(identity:String,contactID:String,id:String) throws {
        var archive=try snapshot(identity:identity)
        if archive.packets.contains(where:{$0.id==id && $0.contactID==contactID}) {
            archive.packets.removeAll{$0.id==id && $0.contactID==contactID}
            archive.readIDs?.removeAll{$0==id}
        } else {
            var older=try side(identity,.older)
            guard older.packets.contains(where:{$0.id==id && $0.contactID==contactID}) else{return}
            older.packets.removeAll{$0.id==id && $0.contactID==contactID}
            try write(older,identity,.older,limit:Self.olderBytes)
        }
        bury([id],in:&archive)
        try save(&archive,identity:identity)
        NotificationCenter.default.post(name:.privateMessageRead,object:nil)
    }
    /// Commit a validated page and its cursor together; never skip unsaved messages.
    /// Blocked senders are dropped, strangers go to requests, and the cursor always advances.
    func commit(_ incoming:[Packet],identity:String,after:UInt64,cursor:UInt64) async throws {
        let contacts=try await contactIDs()
        var archive=try snapshot(identity:identity)
        guard (archive.cursor ?? 0)==after,cursor>=after,incoming.count<=30 else{throw AppFailure("Inbox changed; refresh again.")}
        guard incoming.allSatisfy({$0.envelope.count<=(1024*1024)}) else{throw AppFailure("Message exceeds storage limit.")}
        var requests=try side(identity,.requests)
        let before=requests.packets.count
        let toChat=place(incoming,archive:&archive,requests:&requests,contacts:contacts)
        archive.cursor=cursor
        if requests.packets.count != before {try saveRequests(&requests,identity:identity)}
        try save(&archive,identity:identity)
        NotificationCenter.default.post(name:.privateMessageArrived,object:nil)
        for packet in toChat {Task {@MainActor in WalletActivityNotifications.messageReceived(id:packet.id,contactID:packet.contactID)}}
    }
    /// Import already signature-checked mesh packets for this identity only.
    /// Packet storage never decrypts or executes a payment.
    func importNearby(_ incoming:[ValidatedMessage],identity:String) async throws {
        let contacts=try await contactIDs()
        var archive=try snapshot(identity:identity)
        let now=UInt64(Date().timeIntervalSince1970*1000)
        let fresh=incoming.filter{$0.recipientID == identity && $0.expires > now && $0.data.count<=NearbyFrameDecoder.limit}
            .map{Packet(id:$0.id,contactID:$0.senderID,received:true,date:Date(),envelope:$0.data)}
        guard !fresh.isEmpty else{return}
        var requests=try side(identity,.requests)
        let before=(archive.packets.count,requests.packets.count,(archive.tombstones ?? []).count)
        let toChat=place(fresh,archive:&archive,requests:&requests,contacts:contacts)
        guard (archive.packets.count,requests.packets.count,(archive.tombstones ?? []).count) != before else{return}
        if requests.packets.count != before.1 {try saveRequests(&requests,identity:identity)}
        try save(&archive,identity:identity)
        NotificationCenter.default.post(name:.privateMessageArrived,object:nil)
        for packet in toChat {Task {@MainActor in WalletActivityNotifications.messageReceived(id:packet.id,contactID:packet.contactID)}}
    }
    func append(_ packet:Packet,identity:String) throws {
        var archive=try snapshot(identity:identity)
        guard !archive.packets.contains(where:{$0.id==packet.id}) else {throw AppFailure("This message is already saved.")}
        guard packet.envelope.count<=(1024*1024) else {throw AppFailure("Message storage limit reached.")}
        archive.packets.append(packet)
        try save(&archive,identity:identity)
    }
}

struct MessagingView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    var initialInvitation:String=""
    var initialDraft:String=""
    var initialPaymentTools=false
    @State private var paymentCards: [String:ChatPaymentPreview] = [:]
    @State private var showPayments=false
    @State private var paymentToolsApplied=false
    @State private var initialDraftApplied=false
    @EnvironmentObject private var wallet:WalletState
    @EnvironmentObject private var node:DeviceNode
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var nearby:NearbyTransport
    @AppStorage("meshRelayEnabled") private var meshRelayEnabled=true
    @Environment(\.walletTabActive) private var tabActive
    @State private var showTools=false
    @State private var resumeInvitation=""
    @State private var visibleText:[String:String]=[:]
    @State private var replySnippet:String?
    @State private var showFullReply=false
    @State private var pendingDeletionID:String?
    @State private var packetStatus:[String:String]=[:]
    @FocusState private var composing:Bool
    @State private var name=""
    @State private var invite=""
    @State private var showInviteQR=false
    @State private var showSMS=false
    @State private var smsNumber=""
    @State private var scanContact=false
    @State private var copiedInvite=false
    @State private var profile:[String:Any]?
    @State private var contact:[String:Any]?
    @State private var contactInput=""
    @State private var acceptedInvite=""
    @State private var chooseContact=false
    @State private var draft=""
    @State private var requestAmount=""
    @State private var requestMemo=""
    @State private var incoming=""
    @State private var outgoing=""
    @State private var opened=""
    @State private var receivedPayment:[String:Any]?
    @State private var receivedInvoice:[String:Any]?
    @State private var receivedIntent:String?
    @State private var receivedUpdate:[String:Any]?
    @State private var checkedReceipt:VerifiedReceipt?
    @State private var packets:[MessageArchive.Packet]=[]
    /// Older messages of the open conversation, loaded only when asked for.
    @State private var olderLoaded:[MessageArchive.Packet]=[]
    @State private var olderAvailable=0
    @State private var error:String?
    @State private var busy=false
    @AppStorage("chatOnlineDeliveryEnabled") private var relayEnabled=false
    @State private var relayStatus:String?
    @State private var task:Task<Void,Never>?
    @State private var generation=UUID()
    @State private var screenVisible=false
    private let refreshClock=Timer.publish(every:5,on:.main,in:.common).autoconnect() // an open conversation checks every few seconds
    private let archive=MessageArchive.shared
    private var messagingRoot:String? {wallet.accounts.first(where:{$0.index==0})?.address}
    @EnvironmentObject private var avatarData: LiveData
    @State private var confirmAvatarShare = false
    @State private var reportCandidate:PublicChatReport?
    @State private var confirmBlock=false
    @State private var revealedScreened:Set<String>=[]
    @State private var blockRevision=0
    private var currentContactID:String? {contact?["id"] as? String}
    private var contactBlocked:Bool {_=blockRevision;return PrivateChatBlocks.contains(currentContactID)}
    private func privateReport(_ packet:MessageArchive.Packet?,target:String)->PublicChatReport {
        PublicChatReport(target:target,messageID:packet?.id ?? "",senderID:currentContactID ?? "",
                         displayName:contact?["name"] as? String ?? "Contact",
                         message:packet.flatMap{visibleText[$0.id]} ?? "(No message selected)",
                         created:packet?.date ?? Date(),room:"Private conversation")
    }
    /// Split in three so the compiler can type-check it quickly (one long chain timed out).
    private var messagingBase:some View {
        Group {
            if profile != nil && contact != nil { conversationBody }
            else {
                Form {
                    identitySection
                    if profile != nil { securitySection; recipientSection }
                    if busy {ProgressView("Opening messages…")}
                    if let error {Text(error).foregroundStyle(.orange)}
                }.scrollContentBackground(.hidden)
            }
        }.background(Theme.background).tint(Theme.mint)
            .navigationTitle(contact?["name"] as? String ?? "Chat setup and contacts").keyboardDismissControl()
            .navigationBarTitleDisplayMode(.inline)
            .disabled(wallet.locked)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button {composing=false;showTools=true} label:{Image(systemName:"ellipsis.circle")}
                        .accessibilityLabel("Conversation details and delivery")
                }
            }
            .sheet(item:$reportCandidate) { report in
                PublicChatReportView(report:report,onBlock:{
                    if let id=currentContactID {PrivateChatBlocks.block(id)}
                    return contactBlocked
                })
            }
            .alert("Block this contact?",isPresented:$confirmBlock) {
                Button("Block",role:.destructive) {if let id=currentContactID {PrivateChatBlocks.block(id)}}
                Button("Cancel",role:.cancel) {}
            } message: {Text("Their messages will be hidden and you won't be able to message them. You can unblock them in Chat settings.")}
            .onReceive(NotificationCenter.default.publisher(for:PrivateChatBlocks.changed)) {_ in blockRevision += 1}
            .navigationDestination(isPresented:$showPayments) {
                Form {
                    if profile != nil && contact != nil {requestSection}
                    Section("Verify a payment") {
                        NavigationLink {ReceiptLookupView(scope:.chat)} label:{ThemedLabel("Chat receipts", systemImage: "checkmark.shield")}
                        Text("Receipts are checked against this phone's verified chain before settlement is shown.").font(Theme.footnote)
                    }.themedRow()
                    if profile != nil && contact != nil {
                        DisclosureGroup("Advanced: import a saved encrypted packet") {receiveSection}
                    }
                    if busy {ProgressView("Working…")}
                    if let error {Text(error).foregroundStyle(.orange)}
                    if let relayStatus {Text(relayStatus).font(Theme.caption)}
                }.scrollContentBackground(.hidden).background(AmbientBackground()).navigationTitle("Requests & receipts").keyboardDismissControl()
                    .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Done") {showPayments=false}}}
            }
            .navigationDestination(isPresented:$showTools) {
                    Form {
                        if profile != nil && contact != nil {
                            SettingsSection("Contact") {
                                if let address=contact?["address"] as? String,AddressValidator.valid(address) {
                                    NavigationLink {SaveWalletAddressView(address:address,contactID:contact?["id"] as? String)} label: {SettingsLabel(title:"Name this contact's public address",icon:"person.text.rectangle")}
                                }
                                NavigationLink {ConnectedContactsView()} label: {SettingsLabel(title:"Manage connected contacts",icon:"person.crop.circle.badge.checkmark")}
                            }.themedRow()
                            SettingsSection("Safety") {
                                Button {reportCandidate=privateReport(nil,target:"user")} label:{ThemedLabel("Report contact", systemImage: "exclamationmark.bubble")}
                                if contactBlocked {
                                    Button {if let id=currentContactID {PrivateChatBlocks.unblock(id)}} label:{ThemedLabel("Unblock contact", systemImage: "hand.raised.slash")}
                                } else {
                                    Button(role:.destructive) {confirmBlock=true} label:{ThemedLabel("Block contact", systemImage: "hand.raised")}
                                }
                                NavigationLink {BlockedContactsView()} label: {SettingsLabel(title:"Blocked contacts",icon:"person.crop.circle.badge.xmark")}
                            }.themedRow()
                        }
                        DisclosureGroup {
                            identitySection
                            if profile != nil {recipientSection}
                        } label: {SettingsLabel(title:"Your identity and invitations",icon:"qrcode")}.themedRow()
                        if profile != nil {
                            DisclosureGroup {securitySection} label: {SettingsLabel(title:"Chat delivery and privacy",icon:"lock.shield")}.themedRow()
                            DisclosureGroup {
                                nearbySection
                                if contact != nil {sendSection;receiveSection;nearbyInboxSection;savedPacketsSection}
                            } label: {SettingsLabel(title:"Advanced packet tools",icon:"shippingbox")}.themedRow()
                        }
                        if busy {ProgressView()}
                        if let error {Text(error).foregroundStyle(.orange)}
                    }.scrollContentBackground(.hidden).background(Theme.background)
                        .navigationTitle("Conversation options").keyboardDismissControl()
                        .toolbar {ToolbarItem(placement:.confirmationAction){Button("Done"){showTools=false}}}
                        .disabled(wallet.locked || busy)
            }
        .task(id:"\(profile?["id"] as? String ?? "")-\(nearby.packets.map(\.id).joined())") {
            guard let own=profile?["id"] as? String,!wallet.locked,tabActive,scenePhase == .active else{return}
            let token=generation
            do {
                try await archive.importNearby(nearby.packets,identity:own)
                let saved=try await archive.packets(identity:own)
                guard valid(token) else{return}
                packets=saved
            }catch {if valid(token) {self.error=error.localizedDescription}}
        }
        .onChange(of:contactInput) {_,value in if value != acceptedInvite {contact=nil};outgoing="";opened="";receivedPayment=nil;receivedInvoice=nil;receivedIntent=nil;receivedUpdate=nil;checkedReceipt=nil}
    }
    private var messagingContent:some View {
        messagingBase
        .confirmationDialog("Share your selected avatar with this contact?",isPresented:$confirmAvatarShare,titleVisibility:.visible) {
            Button("Share encrypted avatar") { shareAvatar() }
            Button("Cancel",role:.cancel) {}
        } message: { Text("This contact can retain or forward the avatar. NFT selections include their collection and number. Older clients may show the avatar recipe as text. This does not publish it to the community.") }
        .confirmationDialog("Delete this message from this device?",isPresented:Binding(get:{pendingDeletionID != nil},set:{if !$0 {pendingDeletionID=nil}}),titleVisibility:.visible,presenting:pendingDeletionID) {id in
            Button("Delete locally",role:.destructive) {deleteMessage(id);pendingDeletionID=nil}
            Button("Keep message",role:.cancel) {pendingDeletionID=nil}
        } message: {_ in Text("This does not remove a packet already delivered to the other person or cancel a payment.")}
        .sheet(isPresented:$chooseContact) {
            NavigationStack {
                ConnectedContactsView { selected in
                    resumeInvitation=selected.invitation;acceptedInvite=selected.invitation;contactInput=selected.invitation
                    contact=["id":selected.id,"box_key":selected.boxKey,"name":selected.name,"address":selected.address]
                    outgoing="";opened="";receivedPayment=nil;receivedIntent=nil;receivedUpdate=nil;checkedReceipt=nil
                }
            }
        }
        .sheet(isPresented:$scanContact) {ContactInvitationScanner {uri in contactInput=uri;importContact(uri)}}
        .sheet(isPresented:$showSMS) {SMSInvitationComposer(recipient:smsNumber,invitation:invite,onFinish:{showSMS=false})}
        .sheet(isPresented:$showFullReply) {
            NavigationStack {
                ScrollView {Text(replySnippet ?? "").frame(maxWidth:.infinity,alignment:.leading).padding().textSelection(.enabled)}
                    .navigationTitle("Original message").navigationBarTitleDisplayMode(.inline)
                    .toolbar {ToolbarItem(placement:.topBarTrailing){Button("Done"){showFullReply=false}}}
            }
        }
    }
    var body:some View {
        messagingContent
        .onChange(of:draft) {_,value in if !value.isEmpty {outgoing=""}}
        .onChange(of:wallet.locked) {_,locked in if locked {clear()}}
        .onChange(of:scenePhase) {_,phase in if phase == .background {clear()}}
        .onChange(of:wallet.offlineMode) {_,offline in if offline {generation=UUID();task?.cancel();task=nil;busy=false;relayStatus=nil}}
        .onChange(of:tabActive) {_,active in if !active {clear()}}
        .task(id:"\(scenePhase)-\(tabActive)-\(wallet.address)-\(messagingRoot ?? "")-\(wallet.locked)") {
            guard scenePhase == .active,tabActive,!wallet.locked else{return}
            let token=generation
            if let root=messagingRoot {
                do {
                    if let saved=try await MessagingProfileStore.shared.invitation(for:root) {
                        let own=try await ConnectedContact.inspect(saved)
                        guard own.address==root else{throw AppFailure("Saved messaging identity does not match this wallet.")}
                        try await archive.refresh(identity:own.id)
                        let stored=try await archive.packets(identity:own.id)
                        guard valid(token),messagingRoot==root else{return}
                        profile=own.card;invite=saved;name=own.name;packets=stored
                    }
                }catch{if valid(token){self.error=error.localizedDescription}}
            }
            if !initialDraftApplied {draft=initialDraft;initialDraftApplied=true}
            let selected=resumeInvitation.isEmpty ? initialInvitation : resumeInvitation
            if contactInput.isEmpty,ScannedContactInvitation.parse(selected) != nil {
                contactInput=selected
                importContact(selected)
            }
        }
        .onChange(of:contact?["id"] as? String) {_,id in
            olderLoaded=[];olderAvailable=0
            if id != nil,initialPaymentTools,!paymentToolsApplied {paymentToolsApplied=true;showPayments=true}
        }
        .task(id: "conversation-\(profile?["id"] as? String ?? "")-\(contact?["id"] as? String ?? "")-\(wallet.locked)-\(packets.map(\.id).joined())") {
            await unlockSavedConversation()
        }
        .onAppear {screenVisible=true}
        .onReceive(refreshClock) { _ in
            // Keep checking while the keyboard is up; pause only while a message is being typed, so Send is never blocked.
            guard screenVisible,scenePhase == .active,tabActive,!busy,!composing || draft.isEmpty,!wallet.locked,
                  !wallet.offlineMode,relayEnabled,profile != nil,wallet.canRefreshMessages else{return}
            fetchInbox(automatic:true)
        }
        .onDisappear {screenVisible=false;if !chooseContact && !scanContact && !showSMS && !showTools && !showPayments && !showFullReply {clear()}}
    }
    private var conversationPackets:[MessageArchive.Packet] {
        let blocked=contactBlocked
        let current=Set(packets.map(\.id))
        return (packets+olderLoaded.filter{!current.contains($0.id)}).filter{$0.contactID == (contact?["id"] as? String) && !(blocked && $0.received)}.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }
    private static let cancelPrefix="parano1d:cancel-request:v1:"
    private func cancellationID(_ text:String)->String? {
        guard text.hasPrefix(Self.cancelPrefix) else{return nil}
        let id=String(text.dropFirst(Self.cancelPrefix.count))
        guard id.count==32,id.utf8.allSatisfy({($0>=48 && $0<=57) || ($0>=97 && $0<=102)}) else{return nil}
        return id
    }
    private func requestCanceled(_ payment:ChatPaymentPreview,received:Bool)->Bool {
        guard payment.kind == .request,let invoiceID=payment.invoiceID else{return false}
        return conversationPackets.contains {packet in
            packet.received == received && visibleText[packet.id].flatMap(cancellationID) == invoiceID
        }
    }
    private func reply(to packet:MessageArchive.Packet) {
        guard let text=visibleText[packet.id] else{return}
        let summary=paymentCards[packet.id].map { $0.title + ($0.amount.map {" · " + $0 + " NOID"} ?? "") }
            ?? (cancellationID(text) == nil ? SharedAvatar.displayText(text) : "Canceled payment request")
        let author=packet.received ? (contact?["name"] as? String ?? "Contact") : (profile?["name"] as? String ?? "You")
        replySnippet=CommunityReply.quote(name:author,message:summary)
        composing=true
    }
    private func copyMessage(_ packet:MessageArchive.Packet) {
        guard let text=visibleText[packet.id],cancellationID(text) == nil else{return}
        let plain=SharedAvatar.displayText(text)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier:plain]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(120)])
    }
    private var composedMessageBytes:Int {
        CommunityReply.compose(quote:replySnippet,draft:draft).utf8.count
    }
    /// Load this conversation's older messages (moved out of the main history when it got long).
    private func loadOlder() {
        guard let own=profile?["id"] as? String,let peer=contact?["id"] as? String else{return}
        Task {
            if let older=try? await archive.olderPackets(identity:own,contactID:peer),contact?["id"] as? String == peer {
                olderLoaded=older
                await unlockSavedConversation()
            }
        }
    }
    private func unlockSavedConversation() async {
        guard !wallet.locked,let own=profile?["id"] as? String,
              let selected=contact,let peer=selected["id"] as? String else{return}
        let token=generation
        do {
            // This contact came from a verified invitation, so anything they sent before
            // being saved moves out of Message requests into this conversation.
            let olderCount=(try? await archive.olderCount(identity:own,contactID:peer)) ?? 0
            if valid(token) {olderAvailable=olderCount}
            if try await archive.accept(identity:own,senderID:peer) {
                let refreshed=try await archive.packets(identity:own)
                guard valid(token) else{return}
                packets=refreshed
            }
            let saved=(try await archive.packets(identity:own))+olderLoaded
            let unread=saved.filter {$0.contactID == peer && visibleText[$0.id] == nil}
                .sorted {$0.date < $1.date}
            guard !unread.isEmpty,valid(token) else{return}
            let context=try wallet.messagingSessionContext()
            for packet in unread {
                guard valid(token),contact?["id"] as? String == peer else{return}
                do {
                    let envelope=try JSONSerialization.jsonObject(with:packet.envelope)
                    let result=try await WalletVault.shared.message(["op":packet.received ? "chat_open_archived" : "chat_open_saved","envelope":envelope,"contact":selected,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
                    guard valid(token),contact?["id"] as? String == peer,
                          result["id"] as? String == packet.id else{return}
                    let preview=ChatPaymentPreview(result)
                    if let display=(result["text"] as? String) ?? preview?.title {
                        visibleText[packet.id]=display
                        if packet.received {try await archive.markRead(identity:own,contactID:peer,packetIDs:[packet.id])}
                        paymentCards[packet.id]=preview
                        if let preview,let root=messagingRoot {
                            try? await ChatReceiptIndex.shared.observe(root:root,preview:preview,date:packet.date)
                            autoCheckChatPayment(preview)
                        }
                        if packet.received,let text=result["text"] as? String,let avatar=SharedAvatar.parse(text),let root=messagingRoot,
                           let object=envelope as? [String:Any],let payload=object["data"] as? [String:Any],
                           let created=payload["created_ms"] as? NSNumber {
                            try await PeerAvatarStore.shared.accept(avatar,identity:peer,createdMS:created.uint64Value,messageID:packet.id,scope:"private:"+root)
                        }
                    }
                } catch {
                    if valid(token) {packetStatus[packet.id]="Could not open: " + error.localizedDescription}
                }
            }
        } catch {
            if valid(token) {self.error=error.localizedDescription}
        }
    }
    private var conversationBody:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                if let address=contact?["address"] as? String,AddressValidator.valid(address) {
                    NavigationLink {SendView(initialRecipient:address)} label:{ThemedLabel("Pay", systemImage: "arrow.up.right")}
                        .buttonStyle(ThemedButtonStyle())
                }
                Button {composing=false;showPayments=true} label:{ThemedLabel("Request", systemImage: "arrow.down.left")}.buttonStyle(ThemedButtonStyle())
                Button {composing=false;showPayments=true} label:{ThemedLabel("Receipts", systemImage: "doc.text.magnifyingglass")}.buttonStyle(ThemedButtonStyle())
            }.padding(.horizontal,12).padding(.vertical,8)

            HStack(spacing:8) {
                Image(systemName:"lock.shield").foregroundStyle(Theme.mint)
                Text("Encrypted chat").font(Theme.caption)
                Spacer()
                if relayEnabled {
                    Button("Refresh inbox") { composing=false;fetchInbox() }
                        .disabled(busy || wallet.offlineMode)
                }
                Button(relayEnabled ? "Delivery settings" : "Enable online delivery") {composing=false;showTools=true}
                    .font(.caption.weight(.medium))
            }.foregroundStyle(Theme.secondary).padding(.horizontal,18).padding(.vertical,12)
            Divider().overlay(Theme.line)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing:14) {
                        Color.clear.frame(height:1).id("conversation-top")
                        if conversationPackets.isEmpty {
                            VStack(spacing:12) {
                                PeerAvatar(identity:contact?["id"] as? String ?? "",name:contact?["name"] as? String ?? "Contact",size:64)
                                Text("Start a private conversation").font(Theme.headline)
                                Text("Encrypted is the default. Compare this contact's identity in conversation details.")
                                    .font(Theme.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                            }.padding(.vertical,42).padding(.horizontal,24)
                        }
                        ForEach(conversationPackets.filter { packet in
                            guard let text=visibleText[packet.id] else{return true}
                            return cancellationID(text)==nil
                        }) { packet in
                            HStack(alignment:.bottom,spacing:8) {
                                if !packet.received {Spacer(minLength:38)}
                                if packet.received {PeerAvatar(identity:contact?["id"] as? String ?? "",name:contact?["name"] as? String ?? "Contact",size:32)}
                                VStack(alignment:packet.received ? .leading : .trailing,spacing:5) {
                                    if let payment = paymentCards[packet.id] {
                                        ChatPaymentCard(payment:payment,outgoing:!packet.received,canceled:requestCanceled(payment,received:packet.received))
                                        if !packet.received && payment.kind == .request && !requestCanceled(payment,received:false),payment.invoiceID != nil {
                                            Button("Cancel request") {cancelRequest(payment)}.font(Theme.caption).foregroundStyle(Theme.mint)
                                        }
                                    } else if let text=visibleText[packet.id],packet.received,!revealedScreened.contains(packet.id),
                                              let reason=PublicChatSafety.contentReason(text) {
                                        Button {revealedScreened.insert(packet.id)} label: {
                                            VStack(alignment:.leading,spacing:4) {
                                                Label("Message hidden",systemImage:"eye.slash").font(Theme.headline)
                                                Text(reason+". Tap to show it, or press and hold to report.").font(Theme.caption).foregroundStyle(Theme.secondary)
                                            }.padding(14).foregroundStyle(Theme.text)
                                            .themedCard(18)
                                        }.buttonStyle(.plain)
                                    } else if let text=visibleText[packet.id] {
                                        Text(cancellationID(text) == nil ? SharedAvatar.displayText(text) : "Payment request canceled").lineSpacing(4).textSelection(.enabled).font(Theme.body)
                                            .padding(14).foregroundStyle(Theme.text)
                                            .background(packet.received ? Theme.panel : Theme.soft,in:RoundedRectangle(cornerRadius:18))
                                            .overlay(RoundedRectangle(cornerRadius:18).stroke(Theme.cyber ? Theme.line : Color.clear,lineWidth:1))
                                    } else {
                                        Button {
                                            if packet.received {open(String(decoding:packet.envelope,as:UTF8.self),save:false)}
                                            else {Task {await unlockSavedConversation()}}
                                        } label: {
                                            Label(packet.received ? "Unlock message" : "Unlock sent message",systemImage:"lock.bubble").font(Theme.body)
                                                .padding(14).foregroundStyle(Theme.text)
                                                .background(packet.received ? Theme.panel : Theme.mint.opacity(0.12),in:RoundedRectangle(cornerRadius:18))
                                        }.disabled(busy)
                                    }
                                    if let failure=packetStatus[packet.id],failure.hasPrefix("Could not open") {
                                        Text(failure).font(Theme.caption2).foregroundStyle(.orange)
                                    }
                                    HStack(spacing:10) {
                                        Text(packet.date,style:.time)
                                        if !packet.received {Text("· " + (packetStatus[packet.id] ?? "Saved locally"))}
                                        if visibleText[packet.id] != nil {
                                            Button {reply(to:packet)} label:{ThemedLabel("Reply", systemImage: "arrowshape.turn.up.left")}
                                                .buttonStyle(.plain).foregroundStyle(Theme.mint)
                                            if let text=visibleText[packet.id],cancellationID(text) == nil {
                                                Button {copyMessage(packet)} label:{ThemedLabel("Copy", systemImage: "doc.on.doc")}
                                                    .buttonStyle(.plain).foregroundStyle(Theme.mint)
                                            }
                                        }
                                    }.font(Theme.caption2).foregroundStyle(Theme.secondary).labelStyle(.titleAndIcon)
                                }
                                .contextMenu {
                                    if visibleText[packet.id] != nil {Button("Reply",systemImage:"arrowshape.turn.up.left") {reply(to:packet)}}
                                    if let text=visibleText[packet.id],cancellationID(text) == nil {
                                        Button("Copy message",systemImage:"doc.on.doc") {copyMessage(packet)}
                                    }
                                    if packet.received && visibleText[packet.id] != nil {
                                        Button("Report message",systemImage:"exclamationmark.bubble") {reportCandidate=privateReport(packet,target:"message")}
                                        Button("Block contact",systemImage:"hand.raised",role:.destructive) {confirmBlock=true}
                                    }
                                    Button("Delete from this device",systemImage:"trash",role:.destructive) {pendingDeletionID=packet.id}
                                    if packet.received {
                                        Button("Open message and payment details") { open(String(decoding:packet.envelope,as:UTF8.self),save:false) }.disabled(busy)
                                    }
                                    ShareLink(item:String(decoding:packet.envelope,as:UTF8.self)) {Label("Share signed packet",systemImage:"square.and.arrow.up")}
                                    if !packet.received && relayEnabled {
                                        Button("Retry identical packet") {sendOnline(String(decoding:packet.envelope,as:UTF8.self))}.disabled(wallet.offlineMode || busy)
                                    }
                                }
                                if packet.received {Spacer(minLength:38)}
                                else {PersonalAvatar(root:messagingRoot ?? "",size:32)}
                            }.id(packet.id)
                        }
                        if olderAvailable>olderLoaded.filter({$0.contactID == (contact?["id"] as? String)}).count {
                            Button {loadOlder()} label:{ThemedLabel("Show older messages (\(olderAvailable))", systemImage: "clock.arrow.circlepath")}
                                .font(Theme.caption).foregroundStyle(Theme.mint).padding(.vertical,8)
                        }
                        Color.clear.frame(height:1).id("conversation-bottom")
                    }.padding(18)
                }.scrollDismissesKeyboard(.interactively)
                .onAppear {scroll.scrollTo("conversation-top",anchor:.top)}

            }
            if receivedInvoice != nil || receivedPayment != nil || receivedUpdate != nil {
                Button {composing=false;showPayments=true} label:{ThemedLabel("Review payment message", systemImage: "doc.text.magnifyingglass")}
                    .padding(10)
            }
            if let error {Text(error).font(Theme.caption).foregroundStyle(.orange).padding(.horizontal,18)}
            if let relayStatus {Text(relayStatus).font(Theme.caption2).foregroundStyle(Theme.secondary).padding(.horizontal,18).padding(.bottom,6)}
            if busy {ProgressView("Working…").font(Theme.caption).padding(8)}
            if let replySnippet {
                HStack {Image(systemName:"arrowshape.turn.up.left");Text(replySnippet).lineLimit(2);Button("Full"){showFullReply=true};Spacer();Button("Cancel reply",systemImage:"xmark") {self.replySnippet=nil}.labelStyle(.iconOnly)}
                    .font(Theme.caption).foregroundStyle(Theme.secondary).padding(.horizontal,18)
            }
            if contactBlocked {
                HStack(spacing:10) {
                    Image(systemName:"hand.raised.fill").foregroundStyle(.orange)
                    Text("You blocked this contact. Their messages are hidden and you can't message them.").font(Theme.caption)
                    Spacer(minLength:4)
                    Button("Unblock") {if let id=currentContactID {PrivateChatBlocks.unblock(id)}}.font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                }.padding(12).themedCard(14).padding(.horizontal,14)
            }
            if composedMessageBytes > CommunityReply.maximumBytes {
                Text("The full quote and reply exceed the 4,096-byte message limit. Shorten your message or cancel the quote; no text will be cut automatically.")
                    .font(Theme.caption).foregroundStyle(.orange).padding(.horizontal,18)
            }
            HStack(alignment:.bottom,spacing:12) {
                Menu {
                    Button("Request payment or verify receipt") {composing=false;showPayments=true}
                    if let address=contact?["address"] as? String,AddressValidator.valid(address) {
                        NavigationLink("Send NOID, tokens or NFTs") {SendView(initialRecipient:address)}
                        NavigationLink("Name this contact's public address") {SaveWalletAddressView(address:address,contactID:contact?["id"] as? String)}
                    }
                    Button("Delivery and saved packets") {composing=false;showTools=true}
                } label:{Image(systemName:"plus").font(.title3).frame(width:36,height:44)}
                    .accessibilityLabel("Message actions")
                TextField("Message",text:$draft,axis:.vertical).lineLimit(1...5).focused($composing)
                    .padding(.horizontal,14).padding(.vertical,11)
                    .themedCard(22)
                    .contentShape(Rectangle()).simultaneousGesture(TapGesture().onEnded { composing = true })
                Button {seal()} label:{Image(systemName:"arrow.up").font(Theme.headline).frame(width:44,height:44).background(Theme.mint,in:Circle()).foregroundStyle(Theme.background)}
                    .accessibilityLabel("Send encrypted message")
                    .disabled(busy || contactBlocked || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || composedMessageBytes>CommunityReply.maximumBytes)
            }.padding(.horizontal,12).padding(.vertical,10)
            if relayEnabled && wallet.canRefreshMessages {Text("Auto-refresh · 15 seconds · pauses while typing").font(Theme.caption2).foregroundStyle(Theme.secondary)}
            if relayEnabled && !wallet.canRefreshMessages {Text("Tap Refresh inbox to resume updates. Messages remain saved and readable after unlock.").font(Theme.caption2).foregroundStyle(Theme.secondary)}
            if !relayEnabled {Text(nearby.enabled ? "Saved locally · mesh forwards when nearby links are available" : "Saved locally · enable mesh or online delivery to send").font(Theme.caption2).foregroundStyle(Theme.secondary).padding(.bottom,8)}
        }
    }
    private var identitySection:some View {
        Section("Your messaging identity") {
                if let profile {
                    HStack {
                        PersonalAvatar(root:messagingRoot ?? "")
                        Text(profile["name"] as? String ?? "Your contact")
                    }
                    Text("Chat identity saved on this device").font(Theme.caption).foregroundStyle(Theme.secondary)
                    NavigationLink("Personalize avatar") { AvatarSettingsView(root:messagingRoot ?? "") }
                    Text(profile["id"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    if !invite.isEmpty {
                        Button(copiedInvite ? "Invitation copied" : "Copy invitation", systemImage: copiedInvite ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": invite]], options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(120)])
                            copiedInvite=true
                        }
                        ShareLink("Share invitation",item:invite)
                        Button(showInviteQR ? "Hide invitation QR" : "Show invitation QR",systemImage:"qrcode") {showInviteQR.toggle()}
                        if showInviteQR,let image=ReceiveView.qr(invite) {
                            Image(uiImage:image).interpolation(.none).resizable().scaledToFit().frame(maxWidth:230)
                                .padding(16).background(.white,in:RoundedRectangle(cornerRadius:16))
                                .frame(maxWidth:.infinity).accessibilityLabel("QR code for your signed contact invitation")
                        }
                        TextField("Phone number for SMS (optional)",text:$smsNumber).keyboardType(.phonePad).textContentType(.telephoneNumber)
                        Button("Text invitation",systemImage:"message") {
                            let input=smsNumber.trimmingCharacters(in:.whitespacesAndNewlines)
                            let allowed=CharacterSet(charactersIn:"+0123456789 ()-")
                            let digits=input.filter(\.isNumber)
                            if !input.isEmpty && (digits.count<7 || digits.count>15 || input.unicodeScalars.contains(where:{!allowed.contains($0)})) {
                                error="Enter a valid phone number or leave it blank to choose a recipient in Messages."
                            } else {smsNumber=input;showSMS=true}
                        }.disabled(!MFMessageComposeViewController.canSendText())
                        if !MFMessageComposeViewController.canSendText() {
                            Text("SMS is unavailable in this simulator. Use Share or Copy; test Messages on an iPhone.").font(Theme.caption)
                        }
                        Text("A phone number only delivers the invitation. It does not verify a person, link a number to a wallet or recover a seed.").font(Theme.caption)
                    }
                } else {
                    Text("Set up chat: enter a display name and enable your identity, then add a contact below.").font(Theme.footnote)
                    TextField("Display name",text:$name).autocorrectionDisabled()
                    Button("Enable encrypted messages") { enable() }.disabled(busy || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Text(ChatDeliveryDefault.setupNote).font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                Text("One messaging identity per master key, shared across your wallet accounts. The invitation includes Wallet 1's public address.").font(Theme.footnote)
            }.themedRow()
    }
    private var nearbySection:some View {
        Section("Wallet mesh · Bluetooth") {
            Toggle("Relay encrypted nearby messages",isOn:$meshRelayEnabled)
            Text(nearby.status)
            Text("Links: \(nearby.links) · Received: \(nearby.receivedCount) · Written: \(nearby.writtenCount)").font(Theme.caption)
            Text("The relay runs across wallet screens and requests iOS background Bluetooth execution. It carries encrypted signed packets. Written packets are not read receipts or proof of payment.").font(Theme.footnote)
            Text("This wallet's BLE protocol is not compatible with Bitchat or Android RFCOMM. Background availability is controlled by iOS; force-quitting stops reliable relaying. Three-phone forwarding still requires physical testing.").font(Theme.caption)
            Button("Clear stored nearby packets",role:.destructive) {perform {_ in try await nearby.clearStoredPackets()}}.disabled(nearby.enabled)
        }.themedRow()
    }
    private var recipientSection:some View {
        Section("Recipient") {
                    Button("Choose a connected contact") {chooseContact=true}
                    TextField("Paste their contact invitation",text:$contactInput,axis:.vertical).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Paste invitation from clipboard",systemImage:"doc.on.clipboard") {
                        let pasted=UIPasteboard.general.string ?? ""
                        if ScannedContactInvitation.parse(pasted) != nil {contactInput=pasted;importContact(pasted)}
                        else {error="Clipboard does not contain a Paramo1d contact invitation."}
                    }
                    Button("Scan invitation QR",systemImage:"qrcode.viewfinder") {scanContact=true}
                    Button("Check contact") { importContact() }.disabled(busy || contactInput.isEmpty)
                    if let contact {
                        Text(contact["name"] as? String ?? "Contact").font(Theme.headline)
                        Text(contact["id"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        Text("Compare this full identity with your friend through another trusted channel before sending. A display name is not proof of identity.").font(Theme.footnote)
                        Button("Save verified contact",systemImage:"person.crop.circle.badge.checkmark") {saveContact()}
                            .disabled(busy || acceptedInvite.isEmpty)
                    }
                }.themedRow()
    }
    @ViewBuilder private var sendSection:some View {
        Section("Send an encrypted message") {
                        TextField("Message",text:$draft,axis:.vertical).lineLimit(3...8)
                        Button(relayEnabled && !wallet.offlineMode ? "Send encrypted message" : "Encrypt message") { seal() }.disabled(busy || draft.isEmpty || composedMessageBytes>4096)
                        Button("Attach saved authorized payment") {sealPayment()}
                        Text("Carries the exact pending payment already authorized in Send. It creates no new spend authorization and does not change its recipient.").font(Theme.footnote)
                        if !outgoing.isEmpty {
                            ShareLink("Share encrypted packet",item:outgoing)
                            if nearby.enabled {Button("Send over nearby Bluetooth") {sendNearby(outgoing)}}
                            if relayEnabled {Button("Send encrypted packet online") {sendOnline(outgoing)}.disabled(wallet.offlineMode)}
                            Text("Encrypted and saved locally. Sharing does not confirm delivery. Use AirDrop when available, or another transport your friend can receive.").font(Theme.footnote)
                        }
                    }.themedRow()
        requestSection
    }
    private var requestSection:some View {
        Section("Request NOID from this contact") {
            TextField("Amount in NOID",text:$requestAmount).keyboardType(.decimalPad)
            TextField("Note (optional)",text:$requestMemo).lineLimit(1...3)
            Button("Send payment request",systemImage:"arrow.up.circle") {sealInvoice()}.buttonStyle(MintButtonStyle())
                .disabled(busy || (Amounts.parse(requestAmount).flatMap { UInt64($0) } ?? 0)==0 || requestMemo.utf8.count>256)
            DisclosureGroup("How payment requests work") {
                Text("The recipient chooses whether to pay. Cancel sends an encrypted withdrawal notice; it cannot recall a payment already authorized. The amount and address are reviewed again in Send.").font(Theme.footnote)
            }
        }.themedRow()
    }
    private var receiveSection:some View {
        Section("Receive from this contact") {
                        TextField("Paste an encrypted packet",text:$incoming,axis:.vertical).lineLimit(3...5).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Verify and decrypt") { open(incoming,save:true) }.disabled(busy || incoming.isEmpty)
                        if !opened.isEmpty && receivedInvoice == nil && receivedPayment == nil && receivedUpdate == nil {Text(opened).textSelection(.enabled)}
                        if let invoice=receivedInvoice,let address=invoice["address"] as? String,
                           let amount=invoice["amount"] as? String,AddressValidator.valid(address) {
                            LabeledContent("Requested",value:amount+" NOID")
                            Text(address).font(.caption.monospaced()).textSelection(.enabled)
                            if let memo=invoice["memo"] as? String,!memo.isEmpty {Text(memo).font(Theme.footnote)}
                            let canceled=ChatPaymentPreview(["invoice":invoice]).map {requestCanceled($0,received:true)} ?? false
                            if canceled {Text("Request canceled by sender").foregroundStyle(.orange)}
                            else {NavigationLink("Review payment request") {SendView(initialRecipient:address,initialAmount:amount)}
                                .disabled(wallet.localWallet?.recoveryVerified != true)}
                            Text("Check the contact identity, address and amount. Opening Send does not authorize payment.").font(Theme.footnote)
                        }
                        if let payment=receivedPayment,let id=payment["txid"] as? String {
                            Text("Authorization verified · settlement pending").font(Theme.headline)
                            Text(id).font(.caption.monospaced()).textSelection(.enabled)
                            TransactionExplorerLink(transactionID:id)
                            if let outputs=payment["outputs"] as? [[String:Any]] {
                                ForEach(outputs.indices,id:\.self){index in
                                    Text((outputs[index]["address"] as? String ?? "")+" · "+(Amounts.format(outputs[index]["amount_micronoid"] as? String ?? "") ?? "—")+" NOID").font(.caption.monospaced())
                                }
                            }
                            Button("Forward exact payment to network"){forwardPayment()}.disabled(wallet.offlineMode || !node.enabled)
                            NavigationLink("Verify blockchain settlement"){ReceiptVerificationView(transactionID:id)}
                            Button("Fetch, verify and prepare receipt reply"){receiptReply(id)}.disabled(wallet.offlineMode || !node.enabled)
                            Text("The sender's authorization is valid. This does not establish that inputs remain unspent, that you are the payment recipient, or that the network will accept it.").font(Theme.footnote)
                        }
                        if let update=receivedUpdate,let id=update["txid"] as? String {
                            Text("Peer reports: "+(update["claimed_stage"] as? String ?? "unknown"))
                            Text(id).font(.caption.monospaced()).textSelection(.enabled)
                            TransactionExplorerLink(transactionID:id)
                            if update["receipt_hex"] as? String != nil {
                                Button("Verify received receipt locally"){verifyReceivedReceipt()}.disabled(!node.enabled)
                            }
                            if let checkedReceipt {
                                Text(checkedReceipt.finalized ? "Finalized in this device's verified chain" : "Included; finality not reached in this device's verified chain")
                            } else {Text("Peer status is unverified.").font(Theme.footnote)}
                        }
                    }.themedRow()
    }
    private var nearbyInboxSection:some View {
        Section("Nearby inbox from this contact") {
                        ForEach(nearby.packets.filter{$0.recipientID == (profile?["id"] as? String) && $0.senderID == (contact?["id"] as? String)}) { packet in
                            Button("Verify and read · " + String(packet.id.prefix(12))) {
                                open(String(decoding:packet.data,as:UTF8.self),save:!packets.contains(where:{$0.id==packet.id}))
                            }
                        }
                    }.themedRow()
    }
    private var savedPacketsSection:some View {
        Section("Saved encrypted packets") {
                        ForEach(packets.filter{$0.contactID == (contact?["id"] as? String)}.reversed()) { packet in
                            if packet.received {
                                Button {open(String(decoding:packet.envelope,as:UTF8.self),save:false)} label:{Label(packet.date.formatted(),systemImage:"envelope.badge.shield.half.filled")}.disabled(busy)
                            } else {
                                ShareLink(item:String(decoding:packet.envelope,as:UTF8.self)) {Label("Share sent packet · \(packet.date.formatted())",systemImage:"square.and.arrow.up")}
                                if nearby.enabled {Button("Send this packet nearby") {sendNearby(String(decoding:packet.envelope,as:UTF8.self))}}
                                if relayEnabled {Button("Retry this saved packet online") {sendOnline(String(decoding:packet.envelope,as:UTF8.self))}.disabled(wallet.offlineMode)}
                            }
                        }
                    }.themedRow()
    }
    private var securitySection:some View {
        Section("Transport and security") {
                Toggle("Allow online relay delivery",isOn:$relayEnabled).disabled(wallet.offlineMode)
                if relayEnabled,profile != nil {
                    Button("Refresh private inbox") {fetchInbox()}.disabled(wallet.offlineMode)
                    Text("Fetches up to 30 packets per tap. Packets are verified before storage; encrypted text opens for the trusted contact.")
                }
                Text("Online delivery sends encrypted packets and public sender/recipient identities to chat.parano1d.org. Relay acceptance is not a read receipt.")
                if let relayStatus {Text(relayStatus)}
                Text("Private chat uses X25519/XSalsa20-Poly1305 and Ed25519 authentication. Messaging is not post-quantum. Decrypted text clears on lock or background and reopens from saved ciphertext after unlock.")
                Text("Nearby carries signed packets and supports store-and-forward when enabled. Receiving a packet never automatically submits a payment. Offline delivery cannot establish final payment settlement.")
            }.themedRow()
    }
    private func clear() {replySnippet=nil;showFullReply=false;paymentCards=[:];visibleText=[:];packetStatus=[:];showTools=false;showPayments=false;composing=false;chooseContact=false;scanContact=false;showSMS=false;showInviteQR=false;smsNumber="";copiedInvite=false;acceptedInvite="";generation=UUID();task?.cancel();task=nil;busy=false;profile=nil;contact=nil;draft="";requestAmount="";requestMemo="";incoming="";outgoing="";opened="";receivedPayment=nil;receivedInvoice=nil;receivedIntent=nil;receivedUpdate=nil;checkedReceipt=nil;invite="";contactInput="";packets=[];olderLoaded=[];olderAvailable=0;error=nil;relayStatus=nil}
    private func deleteMessage(_ id:String) {
        guard let own=profile?["id"] as? String,let peer=contact?["id"] as? String else{return}
        perform {token in
            try await archive.delete(identity:own,contactID:peer,id:id)
            let saved=try await archive.packets(identity:own)
            guard valid(token) else{return}
            packets=saved;visibleText.removeValue(forKey:id);paymentCards.removeValue(forKey:id);packetStatus.removeValue(forKey:id)
        }
    }
    private func fetchInbox(automatic:Bool=false) {
        guard relayEnabled,!wallet.offlineMode,let own=profile?["id"] as? String else{return}
        perform {token in
            let after=try await archive.cursor(identity:own)
            let context: LAContext
            if automatic { context = try wallet.messagingRefreshContext() }
            else { context = try await wallet.requireAuthentication("Check your private message inbox") }
            guard valid(token),relayEnabled,!wallet.offlineMode else{return}
            let page=try await InboxPaging.load {limit in
                guard valid(token),relayEnabled,!wallet.offlineMode else{throw CancellationError()}
                // Retry the same cursor with a newly signed, smaller page.
                // Archive.commit below is the only cursor advance.
                await InstantAlerts.registerIfNeeded(context:context)
                let auth=try await WalletVault.shared.message(["op":"chat_inbox_auth","after":after,"limit":limit,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
                guard valid(token),relayEnabled,!wallet.offlineMode else{throw CancellationError()}
                return try await MessageRelay.shared.inbox(auth:auth)
            }
            guard valid(token),relayEnabled,!wallet.offlineMode else{return}
            let validated=try await MessageInbox.validate(page,identity:own,after:after)
            guard valid(token),relayEnabled,!wallet.offlineMode else{return}
            try await archive.commit(validated.packets,identity:own,after:after,cursor:validated.cursor)
            let saved=try await archive.packets(identity:own)
            guard valid(token) else{return}
            packets=saved
            if let selected = contact, let peer = selected["id"] as? String, let root = messagingRoot {
                for packet in saved.filter({ $0.received && $0.contactID == peer }).sorted(by: { $0.date > $1.date }).prefix(30) where visibleText[packet.id] == nil {
                    guard valid(token),contact?["id"] as? String == peer else { return }
                    do {
                    let envelope = try JSONSerialization.jsonObject(with:packet.envelope)
                    let opened=try await WalletVault.shared.message(["op":"chat_open_archived","envelope":envelope,"contact":selected,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
                    guard valid(token),contact?["id"] as? String == peer,opened["id"] as? String == packet.id else { return }
                    let preview=ChatPaymentPreview(opened)
                    if let display=(opened["text"] as? String) ?? preview?.title {
                        visibleText[packet.id] = display
                        try await archive.markRead(identity:own,contactID:peer,packetIDs:[packet.id])
                        paymentCards[packet.id] = preview
                        if let preview {
                            try? await ChatReceiptIndex.shared.observe(root:root,preview:preview,date:packet.date)
                            autoCheckChatPayment(preview)
                        }
                        if let text=opened["text"] as? String,let avatar = SharedAvatar.parse(text), let object = envelope as? [String:Any], let payload = object["data"] as? [String:Any],let created = payload["created_ms"] as? NSNumber {
                            try await PeerAvatarStore.shared.accept(avatar,identity:peer,createdMS:created.uint64Value,messageID:packet.id,scope:"private:" + root)
                        }
                    }
                    } catch {
                        guard valid(token) else { return }
                        packetStatus[packet.id]="Could not open this message. Tap Unlock message to retry."
                    }
                }
            }
            guard valid(token) else { return }
            packets=saved;relayStatus="Inbox saved: \(validated.packets.count) verified packets. Select the sender's contact invitation to read."
        }
    }
    private func sendNearby(_ packet:String) {
        perform {token in
            try await nearby.offer(Data(packet.utf8))
            guard valid(token) else{return}
            relayStatus="Saved for nearby delivery. Keep this screen open; the recipient must verify and decrypt."
        }
    }
    private func sendOnline(_ packet:String) {
        guard relayEnabled,!wallet.offlineMode else{return}
        perform { token in
            relayStatus="Submitting saved message…"
            try await MessageRelay.shared.send(Data(packet.utf8))
            guard valid(token),!wallet.offlineMode,relayEnabled else{return}
            relayStatus="Accepted by relay. Recipient delivery/read status is unknown."
        }
    }
    private func valid(_ token:UUID)->Bool {token==generation && tabActive && scenePhase != .background && !wallet.locked && !Task.isCancelled}
    private func perform(_ operation:@escaping (UUID) async throws -> Void) {
        guard !busy,!wallet.locked else{return};busy=true;error=nil;let token=generation
        task=Task { @MainActor in
            defer {if token==generation {busy=false;task=nil}}
            do {try await operation(token)} catch {if valid(token) {self.error=error.localizedDescription}}
        }
    }
    private func enable() {
        let displayName=name.trimmingCharacters(in:.whitespacesAndNewlines)
        perform { token in
            let context=try await wallet.requireAuthentication("Enable local encrypted messaging")
            guard valid(token) else{return}
            let response=try await WalletVault.shared.message(["op":"chat_profile","name":displayName],context:context)
            guard valid(token),let card=response["contact"] as? [String:Any],let id=card["id"] as? String,let invitation=response["invite"] as? String else{return}
            guard let root=messagingRoot,card["address"] as? String==root else{throw AppFailure("Messaging identity does not match this wallet.")}
            let checked=try await ConnectedContact.inspect(invitation)
            guard checked.id==id,checked.address==root else{throw AppFailure("Messaging invitation did not verify.")}
            try await MessagingProfileStore.shared.save(invitation,for:root)
            let stored=try await archive.packets(identity:id)
            guard valid(token),messagingRoot==root else{return};profile=card;invite=invitation;packets=stored
            ChatDeliveryDefault.applyOnFirstSetup()
        }
    }
    private func importContact(_ invitation:String?=nil) {
        let uri=invitation ?? contactInput
        perform { token in
            let checked=try await ConnectedContact.inspect(uri)
            guard valid(token) else{return};acceptedInvite=checked.invitation;resumeInvitation=checked.invitation;contactInput=checked.invitation;contact=checked.card
        }
    }
    private func saveContact() {
        let uri=acceptedInvite
        guard !uri.isEmpty,let contactID=contact?["id"] as? String else{return}
        perform {token in
            let candidate=try await ConnectedContact.inspect(uri)
            guard candidate.id==contactID else{throw AppFailure("Contact changed. Scan or paste the invitation again.")}
            _=try await wallet.requireAuthentication("Save this verified contact")
            guard valid(token) else{return}
            try await ContactBook.shared.approve(candidate)
            guard valid(token) else{return}
            relayStatus="Contact saved on this device. Compare its identity with your friend before relying on it."
        }
    }
    private func shareAvatar() {
        do {
            let avatar = try SharedAvatar.selected(root:messagingRoot ?? "",holdings:avatarData.holdings,listings:avatarData.listings,owner:wallet.address,verified:(avatarData.holdingsHeight ?? 0) > 0,listingsVerified:(avatarData.listingsHeight ?? 0) > 0)
            seal(override:try avatar.message())
        } catch { self.error = error.localizedDescription }
    }
    private func cancelRequest(_ payment:ChatPaymentPreview) {
        guard let id=payment.invoiceID, id.count==32 else{return}
        seal(override:Self.cancelPrefix + id)
    }
    private func seal(override: String? = nil) {
        guard let profile,let contact,let own=profile["id"] as? String,let peer=contact["id"] as? String else{return}
        let text=override ?? CommunityReply.compose(quote:replySnippet,draft:draft)
        guard CommunityReply.fits(text) else { error="The full quote and reply exceed the 4,096-byte message limit. Shorten your message or cancel the quote.";return }
        guard !PrivateChatBlocks.contains(peer) else { error="You blocked this contact. Unblock them to send messages.";return }
        if override == nil, let reason=PublicChatSafety.contentReason(draft) { error=reason+" breaks the chat rules. Edit it before sending.";return }
        perform { token in
            let context=try wallet.messagingSessionContext()
            guard valid(token) else{return}
            let response=try await WalletVault.shared.message(["op":"chat_seal","sender":profile,"contact":contact,"text":text,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
            guard valid(token),let envelope=response["envelope"] as? [String:Any],let id=envelope["id"] as? String else{return}
            let data=try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
            try await archive.append(.init(id:id,contactID:peer,received:false,date:Date(),envelope:data),identity:own)
            let saved=try await archive.packets(identity:own)
            guard valid(token) else{return};if override == nil {draft="";replySnippet=nil;composing=false};packets=saved;visibleText[id]=text;packetStatus[id]="Saved on this device";outgoing=String(decoding:data,as:UTF8.self)
            if nearby.enabled {
                do {
                    try await nearby.offer(data)
                    guard valid(token) else{return}
                    packetStatus[id]="Queued for mesh delivery"
                } catch {
                    guard valid(token) else{return}
                    relayStatus="Mesh queue unavailable. The message is saved; retry from details."
                }
            }
            if relayEnabled && !wallet.offlineMode {
                try await MessageRelay.shared.send(data)
                await InstantAlerts.ping(recipient:peer,context:context)
                if valid(token) {packetStatus[id]="Accepted by relay";relayStatus="Encrypted message accepted by relay. Read status is unknown."}
            }
        }
    }
    private func sealInvoice() {
        guard let profile,let contact,let own=profile["id"] as? String,let peer=contact["id"] as? String,
              let raw=Amounts.parse(requestAmount),let units=UInt64(raw),units>0,requestMemo.utf8.count<=256 else{return}
        let amount=requestAmount,memo=requestMemo
        let invoiceID=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        perform {token in
            let context=try wallet.messagingSessionContext()
            guard valid(token) else{return}
            let result=try await WalletVault.shared.message(["op":"chat_seal_invoice","sender":profile,"contact":contact,"invoice_id":invoiceID,"amount":amount,"memo":memo,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
            guard valid(token),let envelope=result["envelope"] as? [String:Any],let id=envelope["id"] as? String else{return}
            let bytes=try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
            try await archive.append(.init(id:id,contactID:peer,received:false,date:Date(),envelope:bytes),identity:own)
            let saved=try await archive.packets(identity:own)
            guard valid(token) else{return};packets=saved;outgoing=String(decoding:bytes,as:UTF8.self);requestAmount="";requestMemo=""
            paymentCards[id] = ChatPaymentPreview(["invoice":["invoice_id":invoiceID,"address":profile["address"] as? String ?? "","amount":amount,"memo":memo]])
            if relayEnabled && !wallet.offlineMode {
                try await MessageRelay.shared.send(bytes)
                await InstantAlerts.ping(recipient:peer,context:context)
                if valid(token) {relayStatus="Payment request accepted by relay. Delivery and payment remain unconfirmed."}
            }
        }
    }
    private func sealPayment() {
        guard let profile,let contact,let own=profile["id"] as? String,let peer=contact["id"] as? String else{return}
        perform {token in
            let context=try await wallet.requireAuthentication("Share the identical saved authorized payment")
            guard valid(token) else{return}
            let result=try await WalletVault.shared.message(["op":"chat_seal_payment","sender":profile,"contact":contact,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
            guard valid(token),let envelope=result["envelope"] as? [String:Any],let id=envelope["id"] as? String else{return}
            let bytes=try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
            try await archive.append(.init(id:id,contactID:peer,received:false,date:Date(),envelope:bytes),identity:own)
            let saved=try await archive.packets(identity:own)
            guard valid(token) else{return};packets=saved;outgoing=String(decoding:bytes,as:UTF8.self)
            if nearby.enabled {
                do {try await nearby.offer(bytes);if valid(token) {relayStatus="Authorized payment packet queued for nearby delivery. Settlement is unverified."}}
                catch {if valid(token) {relayStatus="Payment packet saved. Nearby queue unavailable; retry from saved packets."}}
            }
            if relayEnabled && !wallet.offlineMode {
                try await MessageRelay.shared.send(bytes)
                await InstantAlerts.ping(recipient:peer,context:context)
                if valid(token) {relayStatus="Authorized payment packet accepted by relay. Blockchain settlement is unverified."}
            }
        }
    }
    private func forwardPayment() {
        guard !wallet.offlineMode,let intent=receivedIntent,let id=receivedPayment?["txid"] as? String else{return}
        perform {token in
            let response=try await node.paymentOperation(["op":"broadcast_send","intent_hex":intent,"txid":id])
            guard valid(token),!wallet.offlineMode,response["txid"] as? String==id else{return}
            relayStatus="Exact payment submitted. Blockchain settlement remains unverified."
        }
    }
    private func verifyReceivedReceipt() {
        guard let update=receivedUpdate,let id=update["txid"] as? String,let hex=update["receipt_hex"] as? String else{return}
        perform {token in
            let checked=try await node.verifyReceipt(hex,transactionID:id)
            guard valid(token) else{return}
            try ReceiptStore.device().save(ReceiptInput(hex:hex,transactionID:id))
            checkedReceipt=checked
            if checked.finalized,let root=messagingRoot {
                _ = try await PaymentReconciliation.apply(receipt:checked,hex:hex,root:root,node:node)
            }
        }
    }
    private func receiptReply(_ id:String) {
        guard !wallet.offlineMode,let profile,let contact,let own=profile["id"] as? String,let peer=contact["id"] as? String else{return}
        perform {token in
            let (_,verified,hex)=try await node.fetchSettlement(transactionID:id)
            guard valid(token),!wallet.offlineMode else{return}
            guard verified != nil,let hex else{throw AppFailure("No independently verified inclusion receipt is available yet.")}
            let context=try await wallet.requireAuthentication("Encrypt the verified receipt for this contact")
            guard valid(token) else{return}
            let result=try await WalletVault.shared.message(["op":"chat_seal_receipt","sender":profile,"contact":contact,"txid":id,"receipt_hex":hex,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
            guard valid(token),let envelope=result["envelope"] as? [String:Any],let messageID=envelope["id"] as? String else{return}
            let bytes=try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
            try await archive.append(.init(id:messageID,contactID:peer,received:false,date:Date(),envelope:bytes),identity:own)
            let saved=try await archive.packets(identity:own)
            guard valid(token) else{return};packets=saved;outgoing=String(decoding:bytes,as:UTF8.self)
            if nearby.enabled {
                do {try await nearby.offer(bytes);if valid(token) {relayStatus="Verified receipt reply queued for nearby delivery."}}
                catch {if valid(token) {relayStatus="Receipt reply saved. Nearby queue unavailable; retry from saved packets."}}
            }
            if relayEnabled && !wallet.offlineMode {
                try await MessageRelay.shared.send(bytes)
                await InstantAlerts.ping(recipient:peer,context:context)
                if valid(token) {relayStatus="Verified receipt reply accepted by relay. Read status is unknown."}
            }
        }
    }
    private func open(_ packet:String,save:Bool) {
        guard let contact,let own=profile?["id"] as? String,let peer=contact["id"] as? String else{return}
        perform { token in
            guard packet.utf8.count<=(1024*1024) else{throw AppFailure("Message is too large.")}
            if !save {
                let saved=try await archive.packets(identity:own)
                guard saved.contains(where:{$0.contactID == peer && $0.received && $0.envelope == Data(packet.utf8)}) else {
                    throw AppFailure("Only an exact saved message can be reopened after its delivery window. Receive new packets while they are valid.")
                }
            }
            let envelope=try JSONSerialization.jsonObject(with:Data(packet.utf8))
            let context=try wallet.messagingSessionContext()
            guard valid(token) else{return}
            let response=try await WalletVault.shared.message(["op":save ? "chat_open" : "chat_open_archived","envelope":envelope,"contact":contact,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context)
            guard valid(token) else{return}
            let preview=ChatPaymentPreview(response)
            guard let id=response["id"] as? String,let display=(response["text"] as? String) ?? preview?.title else{throw AppFailure("The decrypted message response is incomplete. No payment was executed.")}
            if let text=response["text"] as? String,let avatar = SharedAvatar.parse(text), let root = messagingRoot,
               let sender = response["sender"] as? [String:Any], sender["id"] as? String == peer,
               let object = envelope as? [String:Any], let payload = object["data"] as? [String:Any],
               let created = payload["created_ms"] as? NSNumber {
                try await PeerAvatarStore.shared.accept(avatar,identity:peer,createdMS:created.uint64Value,messageID:id,scope:"private:" + root)
                guard valid(token) else { return }
            }
            paymentCards[id] = preview
            if let preview,let root=messagingRoot {
                try? await ChatReceiptIndex.shared.observe(root:root,preview:preview,date:Date())
                autoCheckChatPayment(preview)
            }
            if save {try await archive.append(.init(id:id,contactID:peer,received:true,date:Date(),envelope:Data(packet.utf8)),identity:own)}
            try await archive.markRead(identity:own,contactID:peer,packetIDs:[id])
            let saved=try await archive.packets(identity:own)
            guard valid(token) else{return};packets=saved;visibleText[id]=display;opened=preview == nil ? display : "";incoming="";receivedPayment=response["payment"] as? [String:Any];receivedInvoice=response["invoice"] as? [String:Any];receivedIntent=response["intent_hex"] as? String;receivedUpdate=response["relay_update"] as? [String:Any];checkedReceipt=nil
        }
    }
    private func autoCheckChatPayment(_ preview:ChatPaymentPreview) {
        guard let id=preview.transactionID else{return}
        let token=generation
        Task { @MainActor in
            guard valid(token),node.enabled,!node.running,!wallet.offlineMode else{return}
            do {
                if let hex=preview.receipt {
                    _=try await node.verifyReceipt(hex,transactionID:id)
                    guard valid(token) else{return}
                    try ReceiptStore.device().save(ReceiptInput(hex:hex,transactionID:id))
                } else {
                    _=try await node.fetchSettlement(transactionID:id)
                }
            } catch {
                // Peer reports are never displayed as verified. Receipts retries on later blocks.
            }
        }
    }
}

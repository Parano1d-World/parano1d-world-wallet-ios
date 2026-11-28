import SwiftUI
import LocalAuthentication

/// Signed messages from people who are not your contacts and whom you never messaged.
/// They never notify, never reach the Watch, and show text only. Payment requests inside
/// them stay closed until the sender is added as a contact from their own invitation.
struct MessageRequestsView: View {
    let identity:String
    @EnvironmentObject private var wallet:WalletState
    @State private var senders:[Sender]=[]
    @State private var error:String?
    @State private var busy=false
    struct Sender:Identifiable {
        let id:String
        let claimedName:String
        let card:[String:Any]?
        var packets:[MessageArchive.Packet]
    }
    var body: some View {
        List {
            Section {
                Text("These people aren't in your contacts. Their names aren't verified. To accept someone, add them from their own contact invitation in Chat setup and contacts; their messages then move into your chat.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            if senders.isEmpty && !busy {Text("No message requests.").foregroundStyle(Theme.secondary)}
            ForEach(senders) {sender in
                NavigationLink {MessageRequestDetail(identity:identity,sender:sender,done:{Task {await load()}})} label: {
                    HStack(spacing:12) {
                        PeerAvatar(identity:sender.id,name:sender.claimedName,size:36)
                        VStack(alignment:.leading,spacing:3) {
                            Text(sender.claimedName).font(Theme.subheadline.weight(.medium))
                            Text("Unverified · \(sender.id.prefix(8))… · \(sender.packets.count) message\(sender.packets.count == 1 ? "" : "s")")
                                .font(Theme.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            if let error {Text(error).font(Theme.caption).foregroundStyle(.red)}
        }
        .navigationTitle("Message requests")
        .task {await load()}
    }
    private func load() async {
        busy=true;defer{busy=false}
        do {
            let packets=try await MessageArchive.shared.requestPackets(identity:identity)
            var grouped:[String:[MessageArchive.Packet]]=[:]
            for packet in packets {grouped[packet.contactID,default:[]].append(packet)}
            var rows:[Sender]=[]
            for (id,list) in grouped {
                let sorted=list.sorted{$0.date>$1.date}
                var card:[String:Any]?;var name="Unknown sender"
                if let first=sorted.first,let envelope=try? JSONSerialization.jsonObject(with:first.envelope),
                   let inspected=try? await NativeCore.shared.call(["op":"chat_inspect","envelope":envelope,"now_ms":UInt64(Date().timeIntervalSince1970*1000)]),
                   let sender=inspected["sender"] as? [String:Any],sender["id"] as? String == id {
                    card=sender
                    if let claimed=sender["name"] as? String,!claimed.trimmingCharacters(in:.whitespaces).isEmpty {name=String(claimed.prefix(40))}
                }
                rows.append(.init(id:id,claimedName:name,card:card,packets:sorted))
            }
            senders=rows.sorted{($0.packets.first?.date ?? .distantPast)>($1.packets.first?.date ?? .distantPast)}
            error=nil
        } catch {self.error=error.localizedDescription}
    }
}

private struct MessageRequestDetail: View {
    let identity:String
    let sender:MessageRequestsView.Sender
    let done:()->Void
    @EnvironmentObject private var wallet:WalletState
    @Environment(\.dismiss) private var dismiss
    @State private var lines:[String:String]=[:]
    @State private var error:String?
    @State private var confirmBlock=false
    var body: some View {
        List {
            Section("From \(sender.claimedName) (unverified)") {
                Text("ID \(sender.id)").font(.caption.monospaced()).foregroundStyle(Theme.secondary).textSelection(.enabled)
            }
            Section("Messages") {
                ForEach(sender.packets) {packet in
                    VStack(alignment:.leading,spacing:4) {
                        Text(lines[packet.id] ?? "Locked — unlock the wallet to read").font(Theme.body)
                        Text(packet.date.formatted(date:.abbreviated,time:.shortened)).font(Theme.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Section {
                Button("Delete these messages",role:.destructive) {discard(block:false)}
                Button("Block and delete",role:.destructive) {confirmBlock=true}
            } footer: {
                Text("To accept, add this person from their own contact invitation in Chat setup and contacts.")
            }
            if let error {Text(error).font(Theme.caption).foregroundStyle(.red)}
        }
        .navigationTitle("Request")
        .confirmationDialog("Block this sender?",isPresented:$confirmBlock,titleVisibility:.visible) {
            Button("Block and delete",role:.destructive) {discard(block:true)}
        } message: {Text("You won't receive their messages. Blocking can be undone in Blocked contacts, but deleted messages don't come back.")}
        .task {await open()}
    }
    private func open() async {
        guard let card=sender.card,let context=try? wallet.messagingSessionContext() else{return}
        for packet in sender.packets.prefix(MessageArchive.requestsPerSender) {
            guard let envelope=try? JSONSerialization.jsonObject(with:packet.envelope),
                  let result=try? await WalletVault.shared.message(["op":"chat_open_archived","envelope":envelope,"contact":card,"now_ms":UInt64(Date().timeIntervalSince1970*1000)],context:context),
                  result["id"] as? String == packet.id else {lines[packet.id]="This message can't be opened.";continue}
            if result["invoice"] != nil || result["payment"] != nil {
                lines[packet.id]="Contains a payment or payment request. Add this person as a contact to view it."
            } else if let text=result["text"] as? String {
                let plain=SharedAvatar.displayText(text)
                if let reason=PublicChatSafety.contentReason(plain) {lines[packet.id]="Message hidden: \(reason)."}
                else {lines[packet.id]=String(plain.prefix(2000))}
            } else {lines[packet.id]="Unsupported message."}
        }
    }
    private func discard(block:Bool) {
        Task {
            do {
                if block {PrivateChatBlocks.block(sender.id)}
                try await MessageArchive.shared.discardRequests(identity:identity,senderID:sender.id)
                done();dismiss()
            } catch {self.error=error.localizedDescription}
        }
    }
}

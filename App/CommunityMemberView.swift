import SwiftUI

struct CommunityMemberView:View {
    let identity:String
    let name:String
    @EnvironmentObject private var wallet:WalletState
    @State private var saved:ConnectedContact?
    @State private var myInvitation=""
    @State private var error:String?
    var body:some View {
        Form {
            Section {
                HStack(spacing:14) {PeerAvatar(identity:identity,name:name,publicOnly:true);Text(name).font(Theme.editorial(26))}
                Text(identity).font(.caption.monospaced()).textSelection(.enabled)
                Text("This is the signing identity of the public post. A display name does not verify a person or their payment address.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
            Section("Contact actions") {
                Text("A public chat identity alone has no private delivery key. Add their signed invitation to connect; public receiving addresses can be named on the connected contact later.").font(Theme.caption).foregroundStyle(Theme.secondary)
                if let saved {
                    NavigationLink {MessagingView(initialInvitation:saved.invitation)} label: {ThemedLabel("Direct message", systemImage: "message")}
                    NavigationLink {SendView(initialRecipient:saved.address)} label: {ThemedLabel("Pay · NOID, tokens or NFTs", systemImage: "arrow.up.right")}
                    NavigationLink {MessagingView(initialInvitation:saved.invitation,initialPaymentTools:true)} label: {ThemedLabel("Request payment or verify a receipt", systemImage: "doc.text")}
                } else {
                    if !myInvitation.isEmpty {
                        ShareLink(item:"Let's connect privately in Parano1d. Reply with your signed contact invitation so I can open our encrypted chat:\n\(myInvitation)") {
                            Label("Invite privately",systemImage:"square.and.arrow.up")
                        }
                        Text("Choose a private recipient in the share sheet. This does not post to #parano1d. They must send their signed invitation back before encrypted messages can begin.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    } else {
                        NavigationLink {MessagingView()} label:{ThemedLabel("Set up private invitations", systemImage: "person.crop.circle.badge.plus")}
                    }
                    NavigationLink {ConnectedContactsView(expectedIdentity:identity)} label: {ThemedLabel("Add their signed invitation", systemImage: "person.badge.plus")}
                    Text("A public post provides a signing identity but no private delivery key. The returned invitation must match this member before it can be saved.").font(Theme.subheadline)
                }
            }.themedRow().buttonStyle(ThemedButtonStyle())
            if let error {Text(error).foregroundStyle(.orange)}
        }.scrollContentBackground(.hidden).background(AmbientBackground()).navigationTitle("Member")
            .task {
                do {
                    if let root=wallet.accounts.first(where:{$0.index==0})?.address,
                       let own=try await MessagingProfileStore.shared.invitation(for:root),
                       let checked=try? await ConnectedContact.inspect(own),checked.address==root {
                        myInvitation=own
                    }
                    let contacts = try await ContactBook.shared.load()
                    if let match = contacts.first(where: { $0.id == identity }) {
                        let checked=try await ConnectedContact.inspect(match.invitation)
                        guard !Task.isCancelled,!wallet.locked,checked.id==identity,checked.address==match.address,checked.boxKey==match.boxKey else{return}
                        saved=checked
                    }
                } catch {self.error=error.localizedDescription}
            }
            .onChange(of:wallet.locked) {_,locked in if locked {saved=nil;myInvitation=""}}
    }
}

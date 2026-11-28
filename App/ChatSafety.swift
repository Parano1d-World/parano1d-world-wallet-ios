import SwiftUI

/// Private-chat safeguards for user-generated content (App Store guideline 1.2):
/// local blocking, reporting a selected message, screening of known abusive
/// phrases before display or sending, and one-time agreement to chat rules.
/// Blocking and screening run only on this device; nothing is uploaded.
enum PrivateChatBlocks {
    static let storageKey = "chat.blockedContacts.v1"
    static let changed = Notification.Name("Parano1dWallet.blockedContactsChanged")
    static func all() -> Set<String> {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids.filter { !$0.isEmpty && $0.count <= 256 }.prefix(2048))
    }
    static func contains(_ id: String?) -> Bool { id.map { all().contains($0) } ?? false }
    static func block(_ id: String) { update { $0.insert(id) } }
    static func unblock(_ id: String) { update { $0.remove(id) } }
    private static func update(_ change: (inout Set<String>) -> Void) {
        var ids = all(); change(&ids)
        let encoded = (try? JSONEncoder().encode(ids.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        UserDefaults.standard.set(encoded, forKey: storageKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

enum ChatRules {
    static let acceptedKey = "chat.rules.accepted.v1"
    static let summary = [
        ("hand.raised", "No threats, harassment or hate", "Abusive messages can be reported and their senders blocked."),
        ("exclamationmark.shield", "No scams or impersonation", "Never ask for or share recovery keys, passwords or private information."),
        ("eye.slash", "No sexual or violent content", "Messages with known abusive phrases are hidden until you choose to view them."),
        ("envelope", "Report concerns", "Reports go to support@koajent.com. We review them and act on accounts that break these rules.")
    ]
}

/// Shown once before chat can be used; there is no way to dismiss it without agreeing.
struct ChatRulesGate: ViewModifier {
    @AppStorage(ChatRules.acceptedKey) private var accepted = false
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { !accepted }, set: { _ in })) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 34, weight: .light)).foregroundStyle(Theme.mint)
                            .frame(width: 64, height: 64).background(Theme.soft, in: RoundedRectangle(cornerRadius: 18))
                        Text("Chat rules").font(Theme.editorial(30))
                        Text("#parano1d is a public room: anyone can read it and it is not encrypted. Private chats are end-to-end encrypted between connected contacts. To keep chat safe, you agree to these rules.")
                            .font(Theme.subheadline).foregroundStyle(Theme.secondary)
                        ForEach(ChatRules.summary, id: \.1) { icon, title, detail in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.mint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title).font(Theme.headline)
                                    Text(detail).font(Theme.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        Text("There is no tolerance for objectionable content or abusive users.").font(Theme.footnote).foregroundStyle(Theme.secondary)
                        Button("I agree") { accepted = true }.buttonStyle(MintButtonStyle()).frame(maxWidth: .infinity)
                    }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }.background(AmbientBackground())
            }.interactiveDismissDisabled()
        }
    }
}
extension View { func chatRulesGate() -> some View { modifier(ChatRulesGate()) } }

/// Settings list of blocked contacts with unblock.
struct BlockedContactsView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle = "system"
    @State private var ids: [String] = PrivateChatBlocks.all().sorted()
    @State private var names: [String: String] = [:]
    var body: some View {
        Form {
            if ids.isEmpty {
                Section { Text("No blocked contacts.").foregroundStyle(Theme.secondary) }.themedRow()
            } else {
                Section {
                    ForEach(ids, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(names[id] ?? "Contact").font(Theme.headline)
                                Text(String(id.prefix(16)) + "…").font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Button("Unblock") { PrivateChatBlocks.unblock(id); ids = PrivateChatBlocks.all().sorted() }
                                .buttonStyle(ThemedButtonStyle()).tint(Theme.mint)
                        }
                    }
                } footer: { Text("Messages from blocked contacts are not shown and you cannot message them. Blocking is stored only on this device.") }.themedRow()
            }
        }.modifier(WalletSettingsSurface()).navigationTitle("Blocked contacts")
            .onReceive(NotificationCenter.default.publisher(for: PrivateChatBlocks.changed)) { _ in ids = PrivateChatBlocks.all().sorted() }
            .task {
                let contacts = (try? await ContactBook.shared.load()) ?? []
                names = Dictionary(contacts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
    }
}

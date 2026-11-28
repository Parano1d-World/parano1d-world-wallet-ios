import SwiftUI

/// App Store edition. This tree is the public release only; the private
/// TestFlight build lives in its own separate source tree.
enum Edition {
    static let isPublic = true

    /// Nearby Bluetooth relay carries other people's encrypted packets, so the
    /// public edition asks people to opt in rather than enabling it by default.
    static var nearbyRelayDefault: Bool { !isPublic }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["meshRelayEnabled": nearbyRelayDefault])
    }
}

/// Support and legal links. URLs come from build settings so a placeholder is
/// never shipped; a row is shown only when its URL is configured.
enum SupportLinks {
    static let email = "support@koajent.com"
    static var privacyPolicy: URL? { configured("Parano1dPrivacyPolicyURL") }
    static var terms: URL? { configured("Parano1dTermsURL") }
    static var website: URL? { configured("Parano1dSupportURL") }
    private static func configured(_ key: String) -> URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Parano1d World's own links, the Parano1d team's sites (parano1d.org; run by
/// the Parano1d team, not by this wallet) and independent services, each in its
/// own labelled group, for the public edition. Every link opens in the system browser after a leaving notice;
/// nothing is embedded and the wallet is never connected. Nothing here trades.
enum PublicEcosystemLinks {
    /// How a row is drawn. `.logo` shows the official full logo (it already
    /// carries the name), `.mark` a small icon plus an optional wordmark.
    enum Look { case icon, logo(String, height: CGFloat), mark(String, wordmark: String?) }
    struct Link: Identifiable {
        let title: String; let detail: String; let icon: String; let url: URL
        var look: Look = .icon
        var independent = false
        /// Run by the Parano1d team (parano1d.org), not by this wallet.
        var team = false
        var id: String { url.absoluteString }
    }
    static let official: [Link] = [
        Link(title: "Parano1d World", detail: "Explorer and NOID price", icon: "globe", url: URL(string: "https://parano1dworld.com")!, look: .logo("WorldFullLogo", height: 92)),
        Link(title: "Parano1d World Mining", detail: "Mine NOID and check mining status", icon: "hammer", url: URL(string: "https://parano1dworld.com/#Mining")!, look: .logo("MiningFullLogo", height: 92))
    ]
    static let project: [Link] = [
        Link(title: "Parano1d", detail: "The Parano1d team's site", icon: "globe", url: URL(string: "https://parano1d.org")!, team: true),
        Link(title: "Documentation", detail: "How the Parano1d chain works", icon: "book", url: URL(string: "https://docs.parano1d.org")!, team: true),
        Link(title: "Lab", detail: "The Parano1d team's research and tools", icon: "flask", url: URL(string: "https://lab.parano1d.org")!, team: true)
    ]
    static let independent: [Link] = [
        Link(title: "NO ONE", detail: "Social deduction game", icon: "gamecontroller", url: URL(string: "https://noone.parano1d.org")!, look: .logo("NoOneLogo", height: 46), independent: true)
    ]
    static var all: [Link] { official + project + independent }
}

struct PublicEcosystemView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle = "system"
    @Environment(\.openURL) private var openURL
    @State private var leaving: PublicEcosystemLinks.Link?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ecosystem").font(Theme.cyber ? Theme.editorial(34) : .system(size: 34, weight: .bold, design: .rounded))
                Text("Links open in your browser. Your wallet isn't connected or shared.")
                    .font(Theme.subheadline).foregroundStyle(Theme.secondary)
                ForEach(PublicEcosystemLinks.official) { row($0) }
                group("Parano1d project", "Run by the Parano1d team. Parano1d World Wallet is a separate wallet and isn't run by them.")
                ForEach(PublicEcosystemLinks.project) { row($0) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Independent services").font(Theme.headline)
                    Text("Third-party sites and games. They aren't run by or affiliated with Parano1d World Wallet.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }.padding(.top, 8)
                ForEach(PublicEcosystemLinks.independent) { row($0) }
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(AmbientBackground()).foregroundStyle(Theme.text).navigationBarTitleDisplayMode(.inline)
        .alert("You're leaving Parano1d World Wallet", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }), presenting: leaving) { link in
            Button("Open \(link.url.host ?? "site")") { openURL(link.url); leaving = nil }
            Button("Stay", role: .cancel) { leaving = nil }
        } message: { link in
            Text(link.independent
                 ? "\(link.title) is an independent service, not affiliated with Parano1d World Wallet. The wallet doesn't run it, hold your funds or see your keys. It opens in your browser."
                 : link.team
                 ? "\(link.url.host ?? "This site") is run by the Parano1d team, not by Parano1d World Wallet. It opens in your browser; your wallet isn't connected or shared."
                 : "\(link.url.host ?? "This site") opens in your browser. Your wallet isn't connected or shared.")
        }
    }

    private func group(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.headline)
            Text(note).font(Theme.caption).foregroundStyle(Theme.secondary)
        }.padding(.top, 8)
    }

    @ViewBuilder private func row(_ link: PublicEcosystemLinks.Link) -> some View {
        Button { leaving = link } label: {
            HStack(spacing: 14) {
                switch link.look {
                case .logo(let name, let height):
                    VStack(alignment: .leading, spacing: 6) {
                        Image(name).resizable().scaledToFit().frame(height: height)
                        Text(link.url.host ?? "").font(Theme.caption2).foregroundStyle(Theme.secondary)
                    }
                case .mark(let name, let wordmark):
                    Image(name).resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        if let wordmark {
                            Image(wordmark).renderingMode(.template).resizable().scaledToFit().frame(height: 15).foregroundStyle(Theme.text)
                        } else { Text(link.title).font(Theme.headline) }
                        Text(link.detail).font(Theme.caption).foregroundStyle(Theme.secondary)
                        Text(link.url.host ?? "").font(Theme.caption2).foregroundStyle(Theme.secondary)
                    }
                case .icon:
                    Group {
                        if Theme.world { WorldIcon(tab: link.icon, size: 46) }
                        else {
                            Image(systemName: link.icon).font(.system(size: 19)).foregroundStyle(Theme.mint)
                                .frame(width: 44, height: 44).background(Theme.soft, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.title).font(Theme.headline)
                        Text(link.detail).font(Theme.caption).foregroundStyle(Theme.secondary)
                        Text(link.url.host ?? "").font(Theme.caption2).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).themedCard(16)
                .themedOutline(16, Theme.cyber ? Theme.line : .clear, 1)
        }.buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(link.title), \(link.detail), \(link.url.host ?? "")")
        .accessibilityHint(link.independent ? "Independent service. Opens in your browser" : link.team ? "Parano1d team site. Opens in your browser" : "Opens in your browser")
    }
}

/// Support, rules and legal rows used in the public edition's settings.
struct SupportSection: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        SettingsSection("Help and legal") {
            Button { if let url = URL(string: "mailto:" + SupportLinks.email) { openURL(url) } } label: {
                LabeledContent { Text(SupportLinks.email).foregroundStyle(Theme.secondary) } label: { SettingsLabel(title:"Contact support",icon:"envelope",tint:SettingsTint.color("about")) }
            }
            if let url = SupportLinks.website { Button { openURL(url) } label: { SettingsLabel(title:"Support website",icon:"globe",tint:SettingsTint.color("about")) } }
            if let url = SupportLinks.privacyPolicy { Button { openURL(url) } label: { SettingsLabel(title:"Privacy policy",icon:"hand.raised",tint:SettingsTint.color("about")) } }
            if let url = SupportLinks.terms { Button { openURL(url) } label: { SettingsLabel(title:"Terms of use",icon:"doc.text",tint:SettingsTint.color("about")) } }
            NavigationLink { ChatRulesView() } label: { SettingsLabel(title:"Chat rules",icon:"bubble.left.and.exclamationmark.bubble.right",tint:SettingsTint.color("about")) }
        }.themedRow()
    }
}

struct ChatRulesView: View {
    var body: some View {
        Form {
            Section {
                ForEach(ChatRules.summary, id: \.1) { icon, title, detail in
                    Label { VStack(alignment: .leading, spacing: 3) { Text(title); Text(detail).font(Theme.caption).foregroundStyle(Theme.secondary) } } icon: { Image(systemName: icon).foregroundStyle(Theme.mint) }
                }
            } footer: { Text("There is no tolerance for objectionable content or abusive users. Report a message by pressing and holding it, or from a conversation's options.") }.themedRow()
            Section { NavigationLink("Blocked contacts") { BlockedContactsView() } }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Chat rules")
    }
}

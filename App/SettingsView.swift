import SwiftUI
import UIKit

struct WalletSettingsSurface: ViewModifier {
    func body(content:Content)->some View {
        content.scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .foregroundStyle(Theme.text)
            .tint(Theme.mint)
    }
}

struct SettingsView: View {
    @AppStorage(ParanoidLook.key) private var paranoidMode=false
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var nearby:NearbyTransport
    @AppStorage("meshRelayEnabled") private var meshRelayEnabled=true
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("livePrices") private var livePrices = true
    @AppStorage("externalMedia") private var externalMedia = true
    @AppStorage(SendLayout.storageKey) private var sendLayout=SendLayout.standard
    @State private var watchAddress = ""
    @State private var watchError: String?
    @State private var confirmLocalErase=false
    @AppStorage("chatOnlineDeliveryEnabled") private var onlineDelivery=false
    @AppStorage(WalletActivityNotifications.balanceKey) private var balanceAlerts=false
    @AppStorage(WalletActivityNotifications.sendKey) private var sendAlerts=false
    @AppStorage(WalletActivityNotifications.assetsKey) private var assetAlerts=false
    @AppStorage(WalletActivityNotifications.foregroundKey) private var foregroundAlerts=true
    @AppStorage(WalletActivityNotifications.messageKey) private var messageAlerts=false
    @AppStorage(InstantAlerts.enabledKey) private var instantAlerts=false
    @AppStorage(WalletActivityNotifications.nftChangeKey) private var nftChangeAlerts=false
    @State private var notificationError:String?
    var body:some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $paranoidMode) {
                        Label {VStack(alignment:.leading,spacing:4){Text("Parano1d mode").foregroundStyle(Theme.text);Text(paranoidMode ? "On: your wallet talks only to blockchain peers" : "Most private setting. Turns the app orange.").font(Theme.caption).foregroundStyle(Theme.secondary)}} icon:{SettingsIcon(systemName:paranoidMode ? "checkmark.shield.fill" : "shield")}.padding(.vertical,4)
                    }.accessibilityHint("Sends wallet traffic only to mainnet peers and turns the app orange")
                }.themedRow(standard: Theme.panel)
                Section {SettingsWalletCard()}.themedRow(standard: Theme.panel)
                Section {
                    NavigationLink { walletSettings } label: { category("Wallet", "Lock, backup and your accounts", "wallet.pass", "wallet") }
                    NavigationLink { chatSettings } label: { category("Chat", "Your contacts and how messages travel", "bubble.left.and.bubble.right", "chat") }
                    NavigationLink { notificationSettings } label: { category("Notifications", "Choose what you're alerted about", "bell.badge", "alerts") }
                    NavigationLink { SiriVoiceSettingsView() } label: { category("Siri & voice", "What Siri can do, off until you allow it", "waveform", "alerts") }
                    NavigationLink { nftSettings } label: { category("NFTs", "Show or hide NFT pictures", "square.stack", "nft") }
                    NavigationLink { networkSettings } label: { category("Network", "Offline mode and checking the chain", "network", "network") }
                    NavigationLink { appearanceSettings } label: { category("Appearance", "Pick a look and hide balances", "paintpalette", "look") }
                    NavigationLink { aboutSettings } label: { category("About", "Version, privacy and help", "info.circle", "about") }
                }.themedRow(standard: Theme.panel)
                SupportSection().themedRow(standard: Theme.panel)
            }.modifier(WalletSettingsSurface())
                // Redraw at once when Parano1d mode changes, so every colour turns orange together.
                .id(paranoidMode)
                .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction){Button("Done"){dismiss()}}}
        }.modifier(AppearanceScheme())
    }
    private func category(_ title:String,_ subtitle:String,_ icon:String,_ area:String="")->some View {
        SettingsLabel(title:title,subtitle:subtitle,icon:icon,tint:SettingsTint.color(area))
    }
    private var walletSettings:some View {
        Form {
            Section {SettingsHero(icon:"wallet.pass",title:"Wallet",subtitle:"Keep your wallet locked, backed up and organized.",tint:SettingsTint.color("wallet"))}.themedRow(standard: Theme.panel)
                SettingsSection("Wallet access") {
                    Button { dismiss(); wallet.lock() } label: { SettingsLabel(title:"Lock wallet now",icon:"lock") }
                    NavigationLink { AppCodeSetupView() } label: { SettingsLabel(title:wallet.appCodeKind.map { "Change app \($0.label)" } ?? "Set app PIN or password",icon:"key") }
                    Toggle(isOn:Binding(get:{wallet.biometricEnabled},set:{enabled in Task {await wallet.setBiometricUnlock(enabled)}})){SettingsLabel(title:"Unlock with \(wallet.biometricName)",icon:"faceid")}.disabled(wallet.authenticating)
                    DisclosureGroup("How wallet unlock works") {
                        Text("Your app PIN or password stays available when biometric unlock is on. iOS device authentication still protects the wallet key when it is used.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    }
                    NavigationLink {WalletSetupView()} label: {SettingsLabel(title:"Master key and backup",icon:"key.horizontal",tint:SettingsTint.color("wallet"))}.disabled(wallet.localWallet == nil)
                    UnavailableNotice(needs:[.backup])
                }.themedRow()
                Section {NavigationLink {AutoLockSettingsView()} label: {SettingsLabel(title:"Auto-lock",icon:"timer",tint:SettingsTint.color("wallet"))}}.themedRow()
                SettingsSection("Wallet management") {
                    NavigationLink {AccountsView()} label: {SettingsLabel(title:"Wallets and accounts",icon:"person.2.crop.square.stack",tint:SettingsTint.color("wallet"))}.disabled(wallet.localWallet == nil)
                    Toggle(isOn:Binding(
                        get:{wallet.eraseOnTenFailures},
                        set:{enabled in if enabled {confirmLocalErase=true} else {Task {await wallet.setErasureOnTenFailures(false)}}}
                    )){SettingsLabel(title:"Erase local wallet key after 10 wrong app-code entries",icon:"trash",tint:SettingsTint.color("danger"))}.disabled(wallet.authenticating || wallet.localWallet?.recoveryVerified != true || wallet.appCodeKind == nil)
                    DisclosureGroup("About local key erase") {
                        Text("Off by default. Only wrong app PIN/password entries count, not Face ID or device-passcode failures. A thief can intentionally trigger this erase. Funds remain on-chain and anyone with the original master key can restore them. Pending signed payments may still settle.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    }
                    if let notice=wallet.notice {Text(notice).font(Theme.caption).foregroundStyle(.orange)}
                }.themedRow()
                SettingsSection("Send screen") {
                    Picker("Preferred layout",selection:$sendLayout) {
                        Text("Standard Send").tag(SendLayout.standard)
                        Text("Quick Send").tag(SendLayout.quick)
                    }
                    Text("Both layouts use the same review and confirmation.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }.themedRow()
                SettingsSection("Apple Watch") {
                    NavigationLink {WatchSendSettingsView()} label: {SettingsLabel(title:"Sends from Apple Watch",icon:"applewatch",tint:SettingsTint.color("wallet"))}.disabled(wallet.localWallet?.recoveryVerified != true)
                }.themedRow()
                if wallet.localWallet == nil && !wallet.recoveryRequired && !wallet.address.isEmpty {
                    SettingsSection("Watch-only address") {
                        TextField("o1…",text:$watchAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Change watched address") {
                            do {try wallet.saveAddress(watchAddress); watchError=nil}
                            catch {watchError=error.localizedDescription}
                        }
                        if let watchError {Text(watchError).foregroundStyle(.orange)}
                        Text("Watch-only never enables sending. Create or import a wallet to use local signing.").font(Theme.caption)
                    }.themedRow()
                }
        }.modifier(WalletSettingsSurface()).navigationTitle("Wallet").onAppear{watchAddress=wallet.address}
        .confirmationDialog("Enable local-key erase?",isPresented:$confirmLocalErase,titleVisibility:.visible) {
            Button("Enable erase after 10 wrong entries",role:.destructive){Task{await wallet.setErasureOnTenFailures(true)}}
            Button("Keep it off",role:.cancel){}
        } message: {
            Text("The tenth confirmed wrong app PIN/password entry deletes the local wallet Keychain secret. This cannot be undone without the original master key. Anyone holding the phone can deliberately trigger it. Face ID and device-passcode failures do not count.")
        }
    }
    private var chatAvatarRoot: String {
        wallet.accounts.first(where: { $0.index == 0 })?.address ?? ""
    }
    private var notificationSettings:some View {
        Form {
            Section {SettingsHero(icon:"bell.badge",title:"Notifications",subtitle:"Alerts never show your address or amounts.",tint:SettingsTint.color("alerts"))}.themedRow(standard: Theme.panel)
            SettingsSection("Wallet activity") {
                Toggle(isOn:$balanceAlerts){SettingsLabel(title:"Verified NOID balance increases",icon:"arrow.down.circle",tint:Theme.mint)}
                Toggle(isOn:$assetAlerts){SettingsLabel(title:"Verified token and NFT additions",icon:"square.stack",tint:Theme.mint)}
                Toggle(isOn:$nftChangeAlerts){SettingsLabel(title:"NFT ownership changes to review",icon:"arrow.left.arrow.right.square",tint:Theme.mint)}
                Toggle(isOn:$sendAlerts){SettingsLabel(title:"Finalized outgoing payments",icon:"paperplane",tint:Theme.mint)}
                DisclosureGroup("About wallet alerts") {
                    Text("Alerts use the app icon and contain no wallet address or amount. A balance increase can include a transfer, trade, reward or returned change; review history to identify it.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }.themedRow()
            SettingsSection("Mining") {
                NavigationLink {MiningAlertsSettingsView()} label: {SettingsLabel(title:"Mining alerts",icon:"hammer",tint:Theme.mint)}
            }.themedRow()
            SettingsSection("Private chat") {
                Toggle(isOn:$messageAlerts){SettingsLabel(title:"New private messages",icon:"bubble.left",tint:Theme.mint)}
                DisclosureGroup("Private message alerts") {
                    Text("Alerts say only that a signed packet arrived. Message text and sender identity stay off the lock screen. Tap an alert to open the conversation after unlocking the wallet.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                Toggle(isOn:$instantAlerts){SettingsLabel(title:"Instant alerts when the app is closed",icon:"bolt",tint:Theme.mint)}.disabled(!messageAlerts)
                DisclosureGroup("What happens when this is on") {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Off by default. When on, alerts for new private messages arrive within seconds, even when Parano1d is closed.")
                        Text("• This phone sends its Apple push address to the Parano1d World alert service (run by KoAjent), signed by your chat identity.")
                        Text("• When you send a private message, your app asks that service to alert the recipient, if they turned this on too.")
                        Text("• The alert says only \"New private message\". Message text is never sent to the service, which can't read your chats.")
                        Text("• The service can see which chat identities message each other and when, plus your IP address. It keeps your push address until you turn this off or for at most 60 days without use.")
                        Text("• Turn it off at any time; your push address stops working right away. Offline mode never contacts the service.")
                    }.font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }.themedRow()
            SettingsSection("Delivery") {
                Toggle(isOn:$foregroundAlerts){SettingsLabel(title:"Show alerts while the app is open",icon:"app.badge",tint:Theme.mint)}
                DisclosureGroup("When alerts arrive") {
                    Text("Local alerts appear when the phone next verifies activity. iOS may pause the app in the background; force-quitting prevents monitoring. For alerts while the app is closed, turn on Instant alerts under Private chat.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                if let notificationError {Text(notificationError).foregroundStyle(.orange)}
                Button {if let url=URL(string:UIApplication.openSettingsURLString){UIApplication.shared.open(url)}} label: {SettingsLabel(title:"Open iOS notification settings",icon:"gearshape")}
            }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Notifications")
            .onChange(of:balanceAlerts) {_,enabled in if enabled {Task {if !(await WalletActivityNotifications.authorize()) {balanceAlerts=false;notificationError="Allow notifications in iOS Settings to receive wallet alerts."}}}}
            .onChange(of:assetAlerts) {_,enabled in if enabled {Task {if !(await WalletActivityNotifications.authorize()) {assetAlerts=false;notificationError="Allow notifications in iOS Settings to receive wallet alerts."}}}}
            .onChange(of:sendAlerts) {_,enabled in if enabled {Task {if !(await WalletActivityNotifications.authorize()) {sendAlerts=false;notificationError="Allow notifications in iOS Settings to receive wallet alerts."}}}}
            .onChange(of:messageAlerts) {_,enabled in if enabled {Task {if !(await WalletActivityNotifications.authorize()) {messageAlerts=false;notificationError="Allow notifications in iOS Settings to receive wallet alerts."} else {InstantAlerts.refreshToken()}}} else if instantAlerts {instantAlerts=false}}
            .onChange(of:instantAlerts) {_,enabled in if enabled {InstantAlerts.refreshToken()} else {InstantAlerts.turnOff()}}
            .onChange(of:nftChangeAlerts) {_,enabled in if enabled {Task {if !(await WalletActivityNotifications.authorize()) {nftChangeAlerts=false;notificationError="Allow notifications in iOS Settings to receive wallet alerts."}}}}
    }
    private var chatSettings:some View {
        Form {
            Section {SettingsHero(icon:"bubble.left.and.bubble.right",title:"Chat",subtitle:"Private messages, signed by your wallet.",tint:SettingsTint.color("chat"))}.themedRow(standard: Theme.panel)
            SettingsSection("Siri") {
                NavigationLink {SiriVoiceSettingsView()} label: {SettingsLabel(title:"Siri & voice for chat",icon:"waveform",tint:SettingsTint.color("chat"))}
            }.themedRow()
            SettingsSection("Your chat account") {
                NavigationLink { AvatarSettingsView(root: chatAvatarRoot) } label: {
                    HStack { PersonalAvatar(root: chatAvatarRoot); Text("Personalize avatar") }
                }
                NavigationLink {MessagingView()} label: {SettingsLabel(title:"Chat identity and invitation",icon:"qrcode",tint:SettingsTint.color("chat"))}
                Text("Your signed chat identity is saved for this wallet. Unlocking does not require creating it again.").font(Theme.caption)
            }.themedRow()
            SettingsSection("Conversations") {
                NavigationLink {ConnectedContactsView()} label: {SettingsLabel(title:"Connected contacts",icon:"person.crop.circle.badge.checkmark",tint:SettingsTint.color("chat"))}
                Toggle(isOn:$onlineDelivery){SettingsLabel(title:"Online message delivery",icon:"network",tint:Theme.mint)}
                Text("Allows encrypted private messages to use the configured online relay. Offline mode pauses internet delivery.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
            SettingsSection("Safety") {
                NavigationLink {BlockedContactsView()} label: {SettingsLabel(title:"Blocked contacts",icon:"hand.raised",tint:SettingsTint.color("danger"))}
                NavigationLink {ChatRulesView()} label: {SettingsLabel(title:"Chat rules",icon:"text.book.closed",tint:SettingsTint.color("chat"))}
                Text("Report a message by pressing and holding it. Reports go to \(SupportLinks.email).").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
            Section {NavigationLink {meshSettings} label: {SettingsLabel(title:"Nearby mesh relay",icon:"dot.radiowaves.left.and.right",tint:SettingsTint.color("chat"))}}.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Chat")
    }
    private var meshSettings:some View {
        Form {
            Section {SettingsHero(icon:"dot.radiowaves.left.and.right",title:"Nearby relay",subtitle:"Pass messages to nearby phones over Bluetooth.",tint:SettingsTint.color("chat"))}.themedRow(standard: Theme.panel)
                SettingsSection("Mesh relay") {
                    Toggle(isOn:$meshRelayEnabled){SettingsLabel(title:"Relay signed nearby messages",icon:"dot.radiowaves.left.and.right",tint:Theme.mint)}
                    Text(nearby.status).font(Theme.caption).foregroundStyle(Theme.secondary)
                    LabeledContent("Nearby links",value:String(nearby.links))
                    LabeledContent("Carried packets",value:String(nearby.packets.count))
                    DisclosureGroup("How nearby relay works") {
                        Text("\(Edition.isPublic ? "Off unless you turn it on." : "Enabled by default for every wallet.") This phone carries encrypted signed packets for nearby wallets, including other people. Bluetooth permission is required. Background runtime is controlled by iOS; force-quitting stops reliable relaying. Offline mode disables internet, not Bluetooth.").font(Theme.footnote).foregroundStyle(Theme.secondary)
                    }
                }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Nearby relay")
    }
    private var nftSettings:some View {
        Form {
            Section {SettingsHero(icon:"square.stack",title:Edition.isPublic ? "NFTs" : "NFTs and offers",subtitle:"Every picture is checked against the blockchain.",tint:SettingsTint.color("nft"))}.themedRow(standard: Theme.panel)
            SettingsSection("Artwork") {
                Toggle(isOn:$externalMedia){SettingsLabel(title:"Show NFT and token artwork",icon:"photo",tint:Theme.mint)}
                Text("Pictures load from tradedata.parano1d.org, which can see your IP address and which images you view. Each image is checked against its on-chain metadata hash. On by default; turn it off here. Offline mode always blocks it.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle(Edition.isPublic ? "NFTs" : "NFTs and offers")
    }
    private var networkSettings:some View {
        Form {
            Section {SettingsHero(icon:"network",title:"Network",subtitle:"How this phone connects and checks the blockchain.",tint:SettingsTint.color("network"))}.themedRow(standard: Theme.panel)
            SettingsSection("Connections") {
                Toggle(isOn:$wallet.offlineMode){SettingsLabel(title:"Offline mode",icon:"airplane",tint:Theme.mint)}
                Toggle(isOn:$livePrices){SettingsLabel(title:"Live USD estimates",icon:"dollarsign.circle",tint:Theme.mint)}
                Text("Price requests omit your wallet address. Estimates require a fresh quote and balance. Offline mode disables internet access, not nearby Bluetooth relay.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
            SettingsSection("Verification") {
                NavigationLink {DeviceNodeView()} label: {SettingsLabel(title:"On-device node",icon:"cpu",tint:SettingsTint.color("network"))}
                NavigationLink {NodeEndpointsSettingsView()} label: {SettingsLabel(title:"Connection: peers or endpoint",icon:"point.3.connected.trianglepath.dotted",tint:SettingsTint.color("network"))}
                NavigationLink {CrashReportsView()} label: {SettingsLabel(title:"Crash reports",icon:"ladybug",tint:SettingsTint.color("about"))}
                NavigationLink {NetworkStatusView()} label: {SettingsLabel(title:"Network check",icon:"checkmark.seal",tint:SettingsTint.color("network"))}
            }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Network")
    }
    private var appearanceSettings:some View {AppearanceSettingsView()}
    private var aboutSettings:some View {
        Form {
            Section {SettingsHero(icon:"info.circle",title:"About",subtitle:"Version, privacy and help.",tint:SettingsTint.color("about"))}.themedRow(standard: Theme.panel)
                SettingsSection("About this build") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")
                }.themedRow()
            Section {NavigationLink {PrivacyView()} label: {SettingsLabel(title:"Privacy",icon:"lock.shield",tint:SettingsTint.color("about"))}}.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("About")
    }
}

struct AutoLockSettingsView:View {
    @EnvironmentObject private var wallet:WalletState
    var body:some View {
        Form {
            Section {SettingsHero(icon:"timer",title:"Auto-lock",subtitle:"Choose when the wallet locks itself.",tint:SettingsTint.color("wallet"))}.themedRow(standard: Theme.panel)
            SettingsSection("Inactivity period") {
                Picker("Auto-lock",selection:$wallet.autoLockSeconds){
                    Text("Off while app is open").tag(0)
                    Text("30 seconds").tag(30);Text("1 minute").tag(60)
                    Text("5 minutes").tag(300);Text("15 minutes").tag(900)
                }.pickerStyle(.inline)
                Text("Off keeps the wallet open until you lock it or leave the app; it locks as soon as the app enters the background. Other periods include background time.\(Edition.isPublic ? "" : " Temporary website data is forgotten when the wallet locks; remembered website data is retained.")").font(Theme.footnote).foregroundStyle(Theme.secondary)
            }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Auto-lock")
    }
}

/// Its own view, so picking a look redraws this page at once (the theme colours are read
/// while drawing, so a page only changes when it redraws). `.id(appearance)` rebuilds just
/// this page, not the navigation around it.
struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @EnvironmentObject private var wallet: WalletState
    struct Look { let tag, name, detail, icon: String }
    static let looks: [Look] = [
        Look(tag:"system",name:"System",detail:"Follows your iPhone light or dark setting",icon:"circle.lefthalf.filled"),
        Look(tag:"light",name:"Light",detail:"Always light",icon:"sun.max.fill"),
        Look(tag:"dark",name:"Dark",detail:"Always dark",icon:"moon.fill"),
        Look(tag:"world",name:"Parano1d World",detail:"Lime on black, like the game",icon:"gamecontroller.fill"),
        Look(tag:"cyber",name:"Cyber",detail:"Pixel headings and outlined panels",icon:"square.grid.3x3.fill")]
    var body: some View {
        Form {
            Section {SettingsHero(icon:"paintpalette",title:"Appearance",subtitle:"Tap a look to see it right away.",tint:SettingsTint.color("look"))}.themedRow(standard: Theme.panel)
            SettingsSection("Main tabs") {PublicTabChoice()}.themedRow()
            SettingsSection("Look") {
                ForEach(AppearanceSettingsView.looks, id:\.tag) { look in
                    Button { withAnimation(.easeInOut(duration:0.2)) { appearance = look.tag } } label: {
                        HStack { SettingsLabel(title:look.name,subtitle:look.detail,icon:look.icon,tint:SettingsTint.color("look")); Spacer()
                            if appearance == look.tag { Image(systemName:"checkmark.circle.fill").foregroundStyle(Theme.mint).font(.title3) } }
                        // The whole row is tappable, including the empty space on the right.
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(appearance == look.tag ? .isSelected : [])
                }
                DisclosureGroup("About appearance") {
                    Text("Cyber adds monospaced headings, pixel details, green accents and outlined panels, with orange accents in Parano1d mode. Parano1d World is the same layout in lime on black, like the Parano1d World brand. Your wallet, saved sessions, artwork and transactions work the same way.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }.themedRow()
            SettingsSection("Balances") {Toggle(isOn:$wallet.hideBalances){SettingsLabel(title:"Hide balances and amounts",icon:"eye.slash",tint:Theme.mint)}}.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle("Appearance").id(appearance)
    }
}

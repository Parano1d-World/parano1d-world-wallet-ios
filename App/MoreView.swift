import SwiftUI
struct MoreView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var directory = EcosystemDirectory()
    @State private var settings = false
    var body: some View {
        List {
            Section {SettingsHero(icon:"square.grid.2x2",title:"More",subtitle:"Your wallets, history, NFTs and contacts.")}.themedRow(standard: Theme.panel)
            Section {
                Button { settings = true } label: { SettingsLabel(title:"Settings",icon:"gearshape",tint:SettingsTint.color("about")) }
                NavigationLink { AccountsView() } label: { SettingsLabel(title:"Your wallets",icon:"wallet.pass",tint:SettingsTint.color("wallet")) }.disabled(wallet.localWallet == nil)
                NavigationLink { ActivityView() } label: { SettingsLabel(title:"Activity and receipts",icon:"clock.arrow.circlepath",tint:SettingsTint.color("wallet")) }
                NavigationLink { WalletAddressBookView() } label: { SettingsLabel(title:"Address book",icon:"person.crop.rectangle.stack",tint:SettingsTint.color("wallet")) }
            }.themedRow(standard: Theme.panel)
            SettingsSection("NFTs and contacts") {
                NavigationLink { CollectionsView() } label: { SettingsLabel(title:"NFT gallery",icon:"square.stack",tint:SettingsTint.color("nft")) }
                NavigationLink { ContactNFTGallery() } label: { SettingsLabel(title:"A contact's NFTs",icon:"person.2.crop.square.stack",tint:SettingsTint.color("nft")) }
                NavigationLink { ConnectedContactsView() } label: { SettingsLabel(title:"Connected contacts",icon:"person.crop.circle.badge.checkmark",tint:SettingsTint.color("chat")) }
            }.themedRow(standard: Theme.panel)
            SettingsSection("Verification") {
                NavigationLink { DeviceNodeView() } label: { SettingsLabel(title:"On-device node",icon:"cpu",tint:SettingsTint.color("network")) }
                NavigationLink { NetworkStatusView() } label: { SettingsLabel(title:"Network check",icon:"network",tint:SettingsTint.color("network")) }
                NavigationLink { PrivacyView() } label: { SettingsLabel(title:"Privacy",icon:"lock.shield",tint:SettingsTint.color("about")) }
            }.themedRow(standard: Theme.panel)
            SupportSection().themedRow(standard: Theme.panel)
        }.modifier(WalletSettingsSurface()).navigationTitle("More").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $settings) { SettingsView() }
    }
}

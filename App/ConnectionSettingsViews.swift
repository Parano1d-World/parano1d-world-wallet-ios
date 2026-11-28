import SwiftUI

struct ChatDeliverySettingsView:View {
    @AppStorage(DisplayStyle.storageKey) private var appearance="system"
    @AppStorage(ChatPrivacy.storageKey) private var privateOnly=false
    @AppStorage("chatOnlineDeliveryEnabled") private var online=false
    @AppStorage("meshRelayEnabled") private var mesh=true
    @EnvironmentObject private var nearby:NearbyTransport
    var body:some View {
        Form {
            Section("Delivery") {
                Toggle("Online private-message delivery",isOn:$online)
                Toggle("Nearby mesh relay",isOn:$mesh)
                LabeledContent("Nearby connected links",value:String(nearby.links))
                DisclosureGroup("Delivery limits") {
                    Text("These preferences are saved. Nearby delivery depends on Bluetooth and iOS background limits. Force-quitting the app can stop relaying.").font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }.themedRow()
            Section("Identity") {
                NavigationLink("Chat identity, contacts and payments") {MessagingView()}
            }.themedRow()
            Section("Safety") {
                NavigationLink("Blocked contacts") {BlockedContactsView()}
                NavigationLink("Chat rules") {ChatRulesView()}
            }.themedRow()
        }.modifier(WalletSettingsSurface()).navigationTitle(Edition.isPublic ? "Chat settings" : "Chat and nearby")
    }
}

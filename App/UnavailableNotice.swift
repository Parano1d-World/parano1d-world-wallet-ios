import SwiftUI

/// Says in plain words why something on this screen is unavailable, with one button
/// that fixes it. Shows nothing when everything it checks is ready.
struct UnavailableNotice: View {
    enum Need { case backup, online, deviceNode, idleNode }
    let needs: [Need]
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var node: DeviceNode
    @State private var setup: WalletSetupMode?
    private var missing: Need? {
        #if DEBUG
        if StoreShots.on { return nil }
        #endif
        return needs.first { !met($0) }
    }
    var body: some View {
        if let need = missing, !wallet.locked {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(need)).foregroundStyle(.orange).frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason(need)).font(Theme.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if let label = fixLabel(need) {
                        Button(label) { fix(need) }.font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(14)
            .themedOutline(14, Color.orange.opacity(0.35), 1)
            .accessibilityElement(children: .combine)
            .fullScreenCover(item: $setup) { mode in NavigationStack { WalletSetupView(mode: mode) } }
        }
    }
    private func met(_ need: Need) -> Bool {
        switch need {
        case .backup: return wallet.localWallet?.recoveryVerified == true
        case .online: return !wallet.offlineMode
        case .deviceNode: return node.enabled && DeviceNodeBridge.available
        case .idleNode: return !node.running
        }
    }
    private func icon(_ need: Need) -> String {
        switch need {
        case .backup: return "key.fill"
        case .online: return "network.slash"
        case .deviceNode: return "cube.transparent"
        case .idleNode: return "hourglass"
        }
    }
    private func reason(_ need: Need) -> String {
        switch need {
        case .backup:
            return wallet.localWallet == nil
                ? "This is a watch-only address, so it can't send or sign. Add its master key to use it fully."
                : "Sending and signing stay locked until you confirm your recovery backup. This protects your funds if you lose this phone."
        case .online: return "Offline mode is on, so this needs a connection. Your wallet and saved data are still available."
        case .deviceNode: return DeviceNodeBridge.available
            ? "The device node is off. It checks the chain on this phone and is needed for this."
            : "This build doesn't include the device node, so chain checks are unavailable."
        case .idleNode: return "Your phone is finishing a chain check. This becomes available automatically when it's done."
        }
    }
    private func fixLabel(_ need: Need) -> String? {
        switch need {
        case .backup: return wallet.localWallet == nil ? "Add master key" : "Finish recovery backup"
        case .online: return "Go online"
        case .deviceNode: return DeviceNodeBridge.available ? "Turn on device node" : nil
        case .idleNode: return nil
        }
    }
    private func fix(_ need: Need) {
        switch need {
        case .backup: setup = wallet.localWallet == nil ? .recover : .manage
        case .online: wallet.offlineMode = false
        case .deviceNode: node.enabled = true; node.synchronize(unlocked: !wallet.locked, offline: wallet.offlineMode, force: true, owner: wallet.address)
        case .idleNode: break
        }
    }
}

/// Public chat is switched off by the person's own Private-only chat setting.
struct PublicChatOffNotice: View {
    @AppStorage(ChatPrivacy.storageKey) private var privateOnly = false
    var body: some View {
        if privateOnly {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.mint).frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Public chat is off because Private-only chat is on. Your private messages are unaffected.")
                        .font(Theme.caption).foregroundStyle(Theme.text)
                    Button("Turn on public chat") { privateOnly = false }.font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                }
                Spacer(minLength: 0)
            }.padding(12).themedCard(14).padding(.horizontal, 16).padding(.top, 6)
        }
    }
}

/// An NFT that a pending token/NFT transaction is using: greyed out with a clear badge
/// until the transaction settles on-chain.
struct PendingNFTStyle: ViewModifier {
    let pending: Bool
    func body(content: Content) -> some View {
        content
            .saturation(pending ? 0 : 1)
            .opacity(pending ? 0.5 : 1)
            .overlay(alignment: .topTrailing) {
                if pending {
                    Label("Pending", systemImage: "clock.arrow.circlepath")
                        .font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.orange.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(.orange).padding(6)
                        .accessibilityLabel("Pending transaction, locked until it settles")
                }
            }
            .animation(.easeInOut(duration: 0.25), value: pending)
    }
}

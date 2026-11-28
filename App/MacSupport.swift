import SwiftUI

/// Mac (Mac Catalyst): left sidebar navigation in place of the bottom tab bar.
struct AppSidebar: View {
    static var enabled: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }
    @Binding var selected: Int
    @AppStorage(TabLayout.storageKey) private var rawTabs = TabLayout.encoded(TabLayout.defaults)
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Brand().padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 14)
            ForEach(0..<4, id: \.self) { index in
                Button { selected = index } label: {
                    Label { Text(index == 0 ? "Home" : TabLayout.read(rawTabs)[index - 1].title) }
                          icon: { TabSymbol(name: index == 0 ? "house" : TabLayout.read(rawTabs)[index - 1].icon, size: 17) }
                        .font(.body.weight(selected == index ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundStyle(selected == index ? Theme.mint : Theme.text)
                        .background(selected == index ? Theme.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .accessibilityAddTraits(selected == index ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 220)
        .background(Theme.panel.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 0.5).ignoresSafeArea() }
    }
}

/// Menu bar commands (Mac, and iPad with a keyboard).
struct WalletCommands: Commands {
    let wallet: WalletState
    let node: DeviceNode
    let live: LiveData
    var body: some Commands {
        CommandMenu("Wallet") {
            Button("Refresh Balance and Assets") {
                guard !wallet.locked else { return }
                node.synchronize(unlocked: true, offline: wallet.offlineMode, force: true, owner: wallet.address)
                live.refresh(owner: wallet.address, offline: wallet.offlineMode, force: true)
            }.keyboardShortcut("r", modifiers: .command)
            Button("Lock Wallet") { wallet.lock() }.keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

/// Mac: drag NFT artwork you own out to Finder or another app.
struct MacDragOut: ViewModifier {
    let image: UIImage?
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if let image { content.draggable(Image(uiImage: image)) } else { content }
        #else
        content
        #endif
    }
}

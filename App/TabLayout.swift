import SwiftUI

enum WalletTab: String, CaseIterable, Identifiable {
    case chat, nfts, ecosystem, mining
    var id: String { rawValue }
    var title: String {
        switch self { case .nfts: "NFTs"; case .chat: "Chat"; case .ecosystem: "Ecosystem"; case .mining: "Mining" }
    }
    var icon: String {
        switch self { case .nfts: "square.3.layers.3d"; case .chat: "bubble.left"; case .ecosystem: "safari"; case .mining: "pickaxe" }
    }
}

struct TabLayout {
    static let storageKey = "walletTabLayout"
    /// Public-edition tabs: gallery, private chat and links by default; Mining can replace any of them.
    static let defaults: [WalletTab] = [.nfts, .chat, .ecosystem]
    static let choices: [WalletTab] = [.nfts, .chat, .ecosystem, .mining]
    /// A saved layout is used only when all three slots are distinct public choices; otherwise the defaults.
    static func read(_ raw: String) -> [WalletTab] {
        let saved = raw.split(separator: ",", omittingEmptySubsequences: false).compactMap { WalletTab(rawValue: String($0)) }
        guard saved.count == 3, Set(saved).count == 3, saved.allSatisfy(choices.contains) else { return defaults }
        return saved
    }

    static func replacing(_ tabs: [WalletTab], at slot: Int, with choice: WalletTab) -> [WalletTab] {
        guard tabs.count == 3, (0..<3).contains(slot) else { return defaults }
        var next = tabs
        if let previous = next.firstIndex(of: choice) { next[previous] = next[slot] }
        next[slot] = choice
        return next
    }
    static func encoded(_ tabs: [WalletTab]) -> String { tabs.map(\.rawValue).joined(separator: ",") }
}

struct PublicTabChoice: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @AppStorage(TabLayout.storageKey) private var raw = TabLayout.encoded(TabLayout.defaults)
    var body: some View {
        ForEach(0..<3, id: \.self) { slot in
            Picker("Tab \(slot + 2)", selection: Binding(
                get: { TabLayout.read(raw)[slot] },
                set: { raw = TabLayout.encoded(TabLayout.replacing(TabLayout.read(raw), at: slot, with: $0)) }
            )) {
                ForEach(TabLayout.choices) { tab in Label { Text(tab.title == "NFTs" ? "NFT gallery" : tab.title) } icon: { TabSymbol(name: tab.icon) }.tag(tab) }
            }
        }
        Text("Home always shows your wallet. Choosing a tab already in use swaps their places. Mining shows and controls your own mining computer; this phone never mines.")
            .font(Theme.caption).foregroundStyle(Theme.secondary)
    }
}

/// A tab symbol: an SF Symbol, or for Mining the crossed pickaxes from the Parano1d World Mining emblem,
/// drawn at the same size as the SF Symbols beside it.
struct TabSymbol: View {
    let name: String
    var size: CGFloat = 19
    var weight: Font.Weight = .regular
    var body: some View {
        if name == "pickaxe" {
            Image("MiningGlyph").renderingMode(.template).resizable().scaledToFit()
                .frame(width: size * 1.12, height: size * 1.12).accessibilityHidden(true)
        } else {
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }
}

import SwiftUI
import UIKit

enum CollectionPresentation {
    static func name(id: String, collections: [NativeItem], names: [String: String]) -> String {
        if let definition = collections.first(where: { $0.collection == id }),
           let name = names[definition.text("metadata_hash")]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Collection " + String(id.prefix(10)) + "…"
    }
    static func ownership(count: Int, collection: NativeItem?) -> String {
        guard let collection, let total = UInt64(collection.text("issued_items")), total >= UInt64(count) else {
            return "\(count) owned · total unavailable"
        }
        return "\(count) owned of \(total) issued"
    }
    /// Floor price: the lowest current ask among verified listings in the collection.
    static func floor(_ collection: String, listings: [NativeItem]) -> String? {
        let asks = listings.filter { $0.collection == collection }.compactMap { UInt64($0.text("ask_micronoid")) }
        guard let lowest = asks.min(), let text = Amounts.format(String(lowest)) else { return nil }
        return text + " NOID"
    }
    static func sale(_ item: NativeItem) -> String? {
        guard !item.text("seller").isEmpty else { return nil }
        guard let price = Amounts.format(item.text("ask_micronoid")) else { return "Listed for sale · price unavailable" }
        return "Listed for sale · " + price + " NOID"
    }
}
/// App Store edition: your own listed NFTs are shown view-only with this badge. No price,
/// no actions and no link to a marketplace (App Review 3.1.1: viewing your own NFTs only).
struct ListedBadge: View {
    var body: some View {
        Text("LISTED").font(.system(size: 9, weight: .bold)).tracking(1.1)
            .foregroundStyle(Theme.mint).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.soft, in: Capsule()).overlay(Capsule().strokeBorder(Theme.mint.opacity(0.6), lineWidth: 1))
            .accessibilityLabel("Listed")
    }
}
extension NativeItem {
    /// True for an NFT this wallet listed (the listing holds it; it can't be sent while listed).
    func isListed(by owner: String) -> Bool { !owner.isEmpty && text("seller") == owner }
}
struct CollectionNameLabel: View {
    let id: String
    @EnvironmentObject private var data: LiveData
    @AppStorage("nft.collectionNames.v1") private var raw = Data()
    var body: some View {
        Text(CollectionPresentation.name(id: id, collections: data.collections, names: (try? JSONDecoder().decode([String:String].self, from: raw)) ?? [:]))
    }
}
struct LayoutChoice: View {
    @Binding var grid: Bool
    var body: some View {
        Menu {
            Picker("Layout", selection: $grid) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Grid", systemImage: "square.grid.2x2").tag(true)
            }
        } label: {
            Image(systemName: grid ? "square.grid.2x2" : "list.bullet").frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel("Layout: " + (grid ? "Grid" : "List"))
    }
}
/// Tap to switch layouts; press and hold to set the NFT grid density.
struct NFTGridChoice: View {
    @Binding var grid: Bool
    @Binding var columns: Int
    var body: some View {
        Button { grid.toggle() } label: {
            Image(systemName:grid ? "square.grid.2x2.fill" : "list.bullet")
                .frame(minWidth:44,minHeight:44)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach([2,3,4],id:\.self) { count in
                Button {
                    columns=count
                    grid=true
                } label: {
                    Label("\(count) columns",systemImage:columns==count && grid ? "checkmark" : "square.grid.2x2")
                }
            }
        }
        .accessibilityLabel(grid ? "NFT grid, \(columns) columns" : "NFT list")
        .accessibilityHint("Tap to switch between list and grid. Press and hold to choose two, three, or four columns.")
    }
}
/// Tracks whether the on-screen keyboard is showing, from the system keyboard notifications.
/// The tab bar hides while it is up, and the Done button only shows while it is up.
@MainActor final class KeyboardState: ObservableObject {
    static let shared = KeyboardState()
    @Published private(set) var visible = false
    private var tokens: [NSObjectProtocol] = []
    private init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardState.shared.visible = true } })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardState.shared.visible = false } })
    }
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.endEditing(true) }
        }
    }
}

/// Done button above the keyboard. Drawn by the app rather than as an iOS keyboard toolbar,
/// which could stay on screen after the keyboard closed and keep the next tap from opening it.
struct KeyboardDismissControl: ViewModifier {
    @ObservedObject private var keyboard = KeyboardState.shared
    func body(content: Content) -> some View {
        // A slim bar that sits on top of the keyboard (not over the page), so the tap always
        // reaches Done instead of the field underneath.
        content.scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboard.visible {
                    HStack {
                        Spacer()
                        Button { KeyboardState.dismiss() } label: {
                            Text("Done").font(Theme.headline).foregroundStyle(Theme.mint)
                                .padding(.horizontal, 18).padding(.vertical, 8).contentShape(Rectangle())
                        }.accessibilityLabel("Done typing")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.panel)
                    .overlay(alignment: .top) { Divider().overlay(Theme.line) }
                }
            }
    }
}
extension View {
    func keyboardDismissControl() -> some View { modifier(KeyboardDismissControl()) }
    func chatBubble(outgoing: Bool = false) -> some View { modifier(ChatBubbleStyle(outgoing: outgoing)) }
}

/// Message and post bubbles. Parano1d World: the game's metal frame (lit lime for your own).
/// Cyber: square post, 2-point outline (accent for your own), dot grid (DESIGN-SPEC "Public room").
struct ChatBubbleStyle: ViewModifier {
    var outgoing: Bool
    func body(content: Content) -> some View {
        if Theme.world {
            content.padding(.horizontal, 20).padding(.vertical, 18).foregroundStyle(Theme.text)
                .background(WorldFrame(kind: .auto))
                .overlay { if outgoing { RoundedRectangle(cornerRadius: 10).stroke(Theme.mint.opacity(0.6), lineWidth: 1.2).padding(9).shadow(color: Theme.mint.opacity(0.5), radius: 5) } }
        } else {
            content.padding(14).foregroundStyle(Theme.text)
                .background { if Theme.cyberOnly { DotGrid(color: Theme.mint.opacity(0.08)) } }
                .background(Theme.cyberOnly ? AnyShapeStyle(Theme.background) : AnyShapeStyle(outgoing ? Theme.soft : Theme.panel), in: RoundedRectangle(cornerRadius: Theme.cyberOnly ? 0 : 18))
                .overlay(RoundedRectangle(cornerRadius: Theme.cyberOnly ? 0 : 18).inset(by: Theme.cyberOnly ? 1 : 0.5).stroke(Theme.cyber ? (outgoing ? Theme.mint : Theme.line) : Color.clear, lineWidth: Theme.cyberOnly ? 2 : 1))
        }
    }
}

import SwiftUI

/// One shared look for Settings and More, consistent across every page:
/// every page starts with a header card, sections carry an accent title, and rows show a tinted
/// icon tile. The standard looks use one colour per area; Cyber, Parano1d World and Parano1d mode
/// keep their own accent so every look stays on-theme.
enum SettingsTint {
    /// Every tile uses the selected look's own accent (green, orange in Parano1d mode, lime in
    /// Parano1d World, pixel green in Cyber). Only destructive rows use red.
    static func color(_ area: String) -> Color { area == "danger" ? Color(hex: 0xE5484D) : Theme.mint }
}

/// A soft accent tile with an outline (standard looks), or the look's own icon style
/// (Cyber pixel panel / Parano1d World game icon). `filled` is the stronger page-header tile.
struct SettingsIcon: View {
    let systemName: String
    var tint: Color = Theme.mint
    var size: CGFloat = 30
    var filled = false
    var body: some View {
        if Theme.world {
            if let game = SettingsIcon.worldIcon(systemName) {
                WorldIcon(tab: game, size: size * 1.15)
            } else {
                // No game icon fits: the symbol sits in a riveted game-style socket in the look's lime.
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                Image(systemName: systemName).font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(Theme.mint).shadow(color: Theme.mint.opacity(0.5), radius: 3)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [Theme.soft, Theme.panel], startPoint: .top, endPoint: .bottom), in: shape)
                    .overlay(shape.strokeBorder(Theme.line, lineWidth: 2))
                    .overlay(shape.inset(by: 3).strokeBorder(Theme.mint.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
        } else if Theme.cyber {
            Image(systemName: systemName).font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(filled ? Theme.background : tint).frame(width: size, height: size)
                .background(filled ? AnyView(Rectangle().fill(tint)) : AnyView(PixelPanelBackground(cut: 5)))
        } else if filled {
            // Page header: a soft accent disc behind the outline icon.
            Image(systemName: systemName).font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(tint).frame(width: size, height: size)
                .background(tint.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        } else {
            // Rows: a clean outline icon in the look's accent.
            Image(systemName: SettingsIcon.outline(systemName)).font(.system(size: size * 0.7, weight: .regular))
                .foregroundStyle(tint).frame(width: size, height: size)
        }
    }
    /// Settings symbols that the shared game-icon match leaves out, mapped to the closest
    /// Parano1d World game icon. Kept here so other screens' icons don't change.
    /// The outline form of a symbol: drops a whole ".fill" part ("moon.fill" -> "moon"), never part
    /// of a longer word ("circle.lefthalf.filled" keeps its name).
    static func outline(_ name: String) -> String {
        name.split(separator: ".").filter { $0 != "fill" }.joined(separator: ".")
    }
    static func worldIcon(_ name: String) -> String? {
        let extra = ["timer": "sync", "ladybug": "support", "checkmark.seal": "node", "applewatch": "nearby",
                     "tag": "alliance", "square.and.arrow.down": "receive", "rectangle.split.3x1": "more",
                     "square.grid.2x2": "more", "server.rack": "node"]
        return extra[name] ?? WorldIcon.match(name)
    }
}

/// A row label: icon tile, title and an optional one-line explanation.
struct SettingsLabel: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var tint: Color = Theme.mint
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(Theme.caption).foregroundStyle(Theme.secondary) }
            }
        }.padding(.vertical, 3)
    }
}

/// Section title with a short accent bar.
struct SettingsSectionTitle: View {
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Capsule().fill(Theme.mint).frame(width: 3, height: 12).opacity(Theme.cyber ? 0 : 1)
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.secondary)
        }.padding(.top, 8).padding(.bottom, 2).accessibilityAddTraits(.isHeader).accessibilityLabel(title)
    }
}

/// `Section("Title") { … }` with the shared title style.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View { Section { content } header: { SettingsSectionTitle(title: title) } }
}

/// The header card that opens every Settings and More page.
struct SettingsHero: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = Theme.mint
    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemName: icon, tint: tint, size: 50, filled: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.editorial(24)).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
    }
}

/// Settings home: the selected wallet at a glance.
struct SettingsWalletCard: View {
    @EnvironmentObject private var wallet: WalletState
    private var root: String { wallet.accounts.first(where: { $0.index == 0 })?.address ?? wallet.address }
    private var name: String { wallet.accounts.first(where: { $0.index == wallet.selectedIndex })?.name ?? "Wallet" }
    private var shortAddress: String {
        let a = wallet.address
        return a.count > 18 ? String(a.prefix(10)) + "…" + String(a.suffix(6)) : a
    }
    var body: some View {
        HStack(spacing: 14) {
            PersonalAvatar(root: root, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(Theme.editorial(22)).foregroundStyle(Theme.text).lineLimit(1)
                Text(shortAddress).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(wallet.localWallet == nil ? "Watch-only" : (wallet.locked ? "Locked" : "Unlocked on this iPhone"))
                    .font(Theme.caption2).foregroundStyle(Theme.mint)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
    }
}

/// Applies the chosen light/dark look to a sheet as well. A sheet that is already open keeps
/// its own colour scheme, so without this, picking Light from Settings left the sheet dark.
struct AppearanceScheme: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase
    @State private var deviceScheme = AppearanceScheme.currentDeviceScheme()
    func body(content: Content) -> some View {
        let style = DisplayStyle.read(appearance)
        // "System" uses the device's own light/dark setting explicitly. Passing nil to an open sheet keeps
        // the sheet's previous look until it is reopened.
        content.preferredColorScheme(style == .system ? deviceScheme : style == .light ? .light : .dark)
            .onChange(of: appearance) { _, _ in deviceScheme = AppearanceScheme.currentDeviceScheme() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { deviceScheme = AppearanceScheme.currentDeviceScheme() } }
    }
    /// The device's light/dark setting, read from the screen (not affected by the app's own override).
    static func currentDeviceScheme() -> ColorScheme {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return (screen?.traitCollection.userInterfaceStyle ?? .unspecified) == .light ? .light : .dark
    }
}

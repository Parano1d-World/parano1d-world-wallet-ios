import SwiftUI
import UIKit
import CoreText

enum DisplayStyle:String,CaseIterable {
    case system,dark,light,cyber,world
    static let storageKey="appearance"
    /// Cyber and Parano1d World share the pixel, outlined layout (docs/DESIGN-SPEC.md, html[data-mono]).
    var mono:Bool {self == .cyber || self == .world}
    static func read(_ raw:String)->Self {Self(rawValue:raw) ?? .system}
}

/// Appearance tokens.
/// - Cyber follows the website's theme-cyber.css (docs/DESIGN-SPEC.md) in ignotus's Paramo1d green: Departure Mono
///   pixel type, chamfered octagon panels with a 2-point outline and 12-point dot grid, chamfered buttons, pixel emblem.
/// - Parano1d World is the Parano1d World game: its own metal HUD frames, icons and HQ art (App/World-*.png, from the
///   game's art sheets), the game's slate and lime colours, and bold capital labels.
/// Paranoid mode turns every accent orange.
/// Parano1d mode, in both editions: the wallet goes straight to mainnet peers (no node server; formerly "Paranoid
/// mode", the Connection "Peers" setting) and every look turns ignotus orange. It is not a VPN. Private-only chat is a
/// separate choice.
enum ParanoidLook {
    static let key = NodeEndpoints.paranoidKey
    static var enabled: Bool { NodeEndpoints.paranoid }
}
enum Theme {
    private static var style:DisplayStyle {DisplayStyle.read(UserDefaults.standard.string(forKey:DisplayStyle.storageKey) ?? "system")}
    /// Cyber or Parano1d World: the shared pixel layout (layout switches use this).
    static var cyber:Bool {style.mono}
    /// Cyber only: green terminal palette (ignotus's Paramo1d green #00FF80).
    static var cyberOnly:Bool {style == .cyber}
    /// Parano1d World: lime on black.
    static var world:Bool {style == .world}
    private static var orange:Bool {ParanoidLook.enabled}
    private static func pick(world w:UInt32,worldOrange wo:UInt32,cyber c:UInt32,cyberOrange co:UInt32)->Color {
        Color(hex: world ? (orange ? wo : w) : (orange ? co : c))
    }
    // ---- Tokens (theme-cyber.css: --bg --panel --text --lav --acc --line-2 --acc-bg) ----
    static var background:Color {cyber ? pick(world:0x0B1519,worldOrange:0x0B1519,cyber:0x060F0C,cyberOrange:0x171410) : adaptive(0x020706,0xF4F7F5)}
    static var panel:Color {cyber ? pick(world:0x0C191B,worldOrange:0x0C191B,cyber:0x102019,cyberOrange:0x241E17) : adaptive(0x0B1716,0xFFFFFF)}
    static var text:Color {cyber ? pick(world:0xE9F9E2,worldOrange:0xFFF3DF,cyber:0xEEF6EF,cyberOrange:0xFFF1DF) : adaptive(0xF4F7F5, 0x14231E)}
    /// Lavender secondary text in the pixel looks.
    static var secondary:Color {cyber ? pick(world:0xA9B8AC,worldOrange:0xFFCF9E,cyber:0x9FC7AF,cyberOrange:0xCBBCA9) : adaptive(0xA1B6AC, 0x4F6258)}
    /// Accent.
    static var mint:Color {cyber ? pick(world:0x9BDE7E,worldOrange:0xFF9B36,cyber:0x00FF80,cyberOrange:0xFF9B36) : orange ? adaptive(0xFF9B36,0xB35A00) : adaptive(0x30E374,0x0A7440)}
    /// Outline (--line-2): panels, inputs, tab bar edge.
    static var line:Color {cyber ? pick(world:0x4B6358,worldOrange:0x6B4A28,cyber:0x2BA765,cyberOrange:0x66503C) : adaptive(0x234336,0xC9DCD1).opacity(0.75)}
    /// Dim divider (--line).
    static var lineDim:Color {cyber ? pick(world:0x2A3B35,worldOrange:0x4A3520,cyber:0x1F5A3A,cyberOrange:0x4A3A2B) : line}
    /// Accent fill behind selected items (--acc-bg).
    static var soft:Color {cyber ? pick(world:0x1F362D,worldOrange:0x2A1806,cyber:0x16301F,cyberOrange:0x382B1F) : mint.opacity(0.12)}
    /// Pressed / hover accent (--acc-2) and disabled accent (--acc-dim).
    static var accent2:Color {cyber ? pick(world:0xB5EA8F,worldOrange:0xFF8A12,cyber:0x2BD66F,cyberOrange:0xFF8A12) : mint}
    static var accentDim:Color {cyber ? pick(world:0x5E7F5A,worldOrange:0x9A5A1C,cyber:0x2BA765,cyberOrange:0x875218) : secondary}
    /// Link / info colour (--sky).
    static var sky:Color {cyber ? pick(world:0x9FD8C4,worldOrange:0xFFD7A8,cyber:0x8FE8C0,cyberOrange:0xFFC37D) : mint}
    /// Accent glow (--acc-glow, 25%).
    static var glow:Color {mint.opacity(0.25)}
    /// Kept for older call sites.
    static var shadow:Color {glow}
    /// Pixel type: Departure Mono (SIL OFL 1.1, Helena Zhang), one weight, never synthesised bold.
    static func pixel(_ size:CGFloat,_ style:Font.TextStyle = .body)->Font {.custom("DepartureMono-Regular",size:size,relativeTo:style)}
    /// Label font for the pixel looks (weight is ignored: Departure Mono has one weight).
    static func worldLabel(_ size:CGFloat,_ weight:Font.Weight = .heavy)->Font {world ? .system(size:size,weight:weight) : pixel(size)}
    static var body:Font {world ? .body : cyber ? pixel(15,.body) : .body}
    static var headline:Font {world ? .system(size:16,weight:.heavy) : cyber ? pixel(17,.headline) : .headline}
    static var subheadline:Font {world ? .subheadline : cyber ? pixel(14,.subheadline) : .subheadline}
    static var caption:Font {world ? .system(size:12,weight:.semibold) : cyber ? pixel(12,.caption) : .caption}
    static var caption2:Font {world ? .system(size:11,weight:.semibold) : cyber ? pixel(11,.caption2) : .caption2}
    static var footnote:Font {world ? .footnote : cyber ? pixel(13,.footnote) : .footnote}
    static var control:Font {world ? .system(size:14,weight:.heavy) : cyber ? pixel(15,.subheadline) : .subheadline.weight(.semibold)}
    private static func adaptive(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
        })
    }
    static func editorial(_ size: CGFloat) -> Font { world ? .system(size: size * 0.8, weight: .heavy) : cyber ? pixel(size * 0.92, size >= 32 ? .largeTitle : .title3) : .custom("Georgia", size: size, relativeTo: size >= 32 ? .largeTitle : .title3) }
}
extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
}

/// The pixel "1" ring (deploy/cyber-emblem.svg, 34 x 34), drawn crisp and tinted with the accent.
struct PixelEmblem: Shape {
    static let rows: [String] = [
        "...............####...............",
        "...........############...........",
        ".........################.........",
        ".......########....########.......",
        "......######..........######......",
        ".....#####..............#####.....",
        "....####..................####....",
        "...####....................####...",
        "...###......................###...",
        "..####.........####.........####..",
        "..###.........#####..........###..",
        ".####........######..........####.",
        ".###........###.###...........###.",
        ".###............###...........###.",
        ".###............###...........###.",
        "###.............###............###",
        "###.............###............###",
        "###.............###............###",
        "###.............###............###",
        ".###............###...........###.",
        ".###............###...........###.",
        ".###............###...........###.",
        ".####.......###########......####.",
        "..###.......###########......###..",
        "..####......................####..",
        "...###......................###...",
        "...####....................####...",
        "....####..................####....",
        ".....#####..............#####.....",
        "......######..........######......",
        ".......########....########.......",
        ".........################.........",
        "...........############...........",
        "...............####..............."
    ]
    func path(in r: CGRect) -> Path {
        let cell = min(r.width, r.height) / 34
        let ox = r.midX - cell * 17, oy = r.midY - cell * 17
        var p = Path()
        for (y, row) in Self.rows.enumerated() {
            var x = 0; let chars = Array(row)
            while x < chars.count {
                if chars[x] == "#" {
                    var e = x; while e < chars.count && chars[e] == "#" { e += 1 }
                    p.addRect(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell, width: CGFloat(e - x) * cell, height: cell))
                    x = e
                } else { x += 1 }
            }
        }
        return p
    }
}
/// 12-point dot grid used inside pixel panels (--dots).
struct DotGrid: View {
    var color: Color
    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: 12) {
                for y in stride(from: CGFloat(0), through: size.height, by: 12) { dots.addRect(CGRect(x: x, y: y, width: 1, height: 1)) }
            }
            context.fill(dots, with: .color(color))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
/// Octagon panel: 2-point outline clipped to the chamfer, panel fill with the dot grid.
struct PixelPanelBackground: View {
    var accent = false
    var cut: CGFloat = 10
    var body: some View {
        ZStack {
            ChamferShape(cut: cut).fill(Theme.panel)
            DotGrid(color: Theme.world ? .white.opacity(0.08) : Theme.mint.opacity(0.08)).clipShape(ChamferShape(cut: cut))
            ChamferShape(cut: cut).inset(by: 1).stroke(accent ? Theme.mint : Theme.line, lineWidth: 2)
        }
    }
}
struct Brand: View {
    @AppStorage(DisplayStyle.storageKey) private var style="system"
    @AppStorage(ParanoidLook.key) private var paranoid=false
    var masthead=false
    var body: some View {
        HStack(spacing: 10) {
            if Theme.world {
                Image("Brand").resizable().scaledToFit().frame(width: 30, height: 30).hueRotation(.degrees(paranoid ? -62 : 0)).shadow(color: Theme.mint.opacity(0.45), radius: 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    (Text("PARANO") + Text("1").foregroundColor(Theme.mint) + Text("D")).font(.system(size: 17, weight: .black)).tracking(1).foregroundStyle(Theme.text)
                    Text("WORLD").font(.system(size: 9, weight: .heavy)).tracking(3).foregroundStyle(Theme.mint)
                }
            } else if Theme.cyber {
                PixelEmblem().fill(Theme.mint).frame(width: 30, height: 30).shadow(color: Theme.glow, radius: 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parano1d").font(Theme.pixel(17)).foregroundStyle(Theme.mint).lineLimit(1)
                    Text(Theme.world ? "World" : "Wallet").font(Theme.pixel(11)).foregroundStyle(Theme.secondary)
                }
            } else {
                Image("Brand").resizable().scaledToFit().frame(width: 26, height: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Parano1d").font(Theme.editorial(21))
                    Text("WALLET").font(.system(size: 8, weight: .medium)).tracking(2.5).foregroundStyle(Theme.secondary)
                }.foregroundStyle(Theme.text)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Parano1d Wallet")
    }
}
struct AmbientBackground: View {
    @AppStorage(DisplayStyle.storageKey) private var style="system"
    @AppStorage(ParanoidLook.key) private var paranoid=false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background
            if !DisplayStyle.read(style).mono {
                Ellipse().fill(Theme.mint.opacity(0.055)).frame(width:260,height:300).blur(radius:85).offset(x:120,y:-85)
            } else if DisplayStyle.read(style) == .world {
                // The game's night sky: slate, a touch darker at the top, a low green haze at the bottom.
                LinearGradient(colors:[Color(hex:0x091015),Theme.background,Color(hex:0x0A1714)],startPoint:.top,endPoint:.bottom)
                RadialGradient(colors:[Theme.mint.opacity(0.07),.clear],center:.bottom,startRadius:10,endRadius:460)
            } else {
                // Faint scanlines (repeating-linear-gradient #ffffff05 every 3 px).
                Canvas { context,size in
                    var lines=Path()
                    for y in stride(from:CGFloat(0),through:size.height,by:3) { lines.addRect(CGRect(x:0,y:y,width:size.width,height:1)) }
                    context.fill(lines,with:.color(.white.opacity(0.02)))
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}
struct Panel<Content: View>: View {
    @AppStorage(DisplayStyle.storageKey) private var style="system"
    @AppStorage(ParanoidLook.key) private var paranoid=false
    /// Important panel: accent outline (.feature-panel).
    var accent=false
    @ViewBuilder var content: Content
    var body: some View {
        let stack=VStack(alignment: .leading, spacing: 14) { content }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        if DisplayStyle.read(style) == .world {
            stack.padding(.horizontal, 6).padding(.vertical, 8).background(WorldFrame(kind: .panel))
        } else if DisplayStyle.read(style).mono {
            stack.background(PixelPanelBackground(accent: accent))
        } else {
            stack.background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line,lineWidth:0.7))
        }
    }
}
/// Chamfered pixel button (.btn): 2-point accent outline, transparent; primary = accent fill, black text, glow.
struct PixelButtonShape: View {
    var primary: Bool
    var pressed = false
    var body: some View {
        ZStack {
            ChamferShape(cut: 7).fill(primary ? (pressed ? Theme.accent2 : Theme.mint) : (pressed ? Theme.soft : Theme.background))
            if !primary { ChamferShape(cut: 7).inset(by: 1).stroke(Theme.mint, lineWidth: 2) }
        }.shadow(color: primary ? Theme.glow : .clear, radius: 10)
    }
}
struct MintButtonStyle: ButtonStyle {
    @AppStorage(DisplayStyle.storageKey) private var style="system"
    @AppStorage(ParanoidLook.key) private var paranoid=false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let label=configuration.label.font(Theme.control).frame(maxWidth: .infinity).padding(.vertical, 15)
        return Group {
            if DisplayStyle.read(style) == .world {
                label.textCase(.uppercase).tracking(1.4).foregroundStyle(enabled ? Color(hex:0x0C191B) : Theme.secondary)
                    .padding(.vertical, 3).background(WorldButtonBackground(primary: enabled, pressed: configuration.isPressed))
            } else if DisplayStyle.read(style).mono {
                label.foregroundStyle(enabled ? Color.black : Theme.accentDim)
                    .background { if enabled { PixelButtonShape(primary: true, pressed: configuration.isPressed) } else { ChamferShape(cut: 7).inset(by: 1).stroke(Theme.line, lineWidth: 2) } }
                    // ignotus's hard pixel shadow (box-shadow 4px 4px 0 #378259) under Cyber's main button.
                    .background { if enabled { ChamferShape(cut: 7).fill(Color(hex: ParanoidLook.enabled ? 0x875218 : 0x378259)).offset(x: configuration.isPressed ? 1 : 4, y: configuration.isPressed ? 1 : 4) } }
                    .offset(x: configuration.isPressed ? 3 : 0, y: configuration.isPressed ? 3 : 0)
            } else {
                label.foregroundStyle(Color(hex: 0x03100A))
                    .background(Color(hex: ParanoidLook.enabled ? 0xFF9B36 : 0x30E374),in:Capsule())
                    .overlay(Capsule().stroke(Color(hex: ParanoidLook.enabled ? 0xFFC37D : 0x88F5AE).opacity(0.45),lineWidth:0.7))
                    .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
            }
        }
    }
}
/// Outlined pixel button for secondary actions.
/// Compact button in the current look, replacing the stock grey iOS bordered buttons:
/// the game's bar frame in Parano1d World, a chamfered outline in Cyber, and a panel capsule
/// (or the accent, when prominent) in the standard looks. Orange in Parano1d mode.
/// Top-bar Parano1d mode switch, next to Lock and Settings (same circle style). One tap turns Parano1d mode on or off:
/// on = wallet traffic straight to mainnet peers and the orange look. The same setting as the switch at the top of Settings.
struct ParanoidModeButton: View {
    @AppStorage(ParanoidLook.key) private var paranoid = false
    var body: some View {
        Button {
            paranoid.toggle()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Image(systemName: paranoid ? "checkmark.shield.fill" : "shield")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(paranoid ? Theme.mint : Theme.text)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [Theme.soft, Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().stroke(paranoid ? Theme.mint : Theme.line, lineWidth: paranoid ? 1.2 : 0.7))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Parano1d mode")
        .accessibilityValue(paranoid ? "On, wallet uses mainnet peers only" : "Off")
        .accessibilityHint("Turns Parano1d mode on or off")
    }
}
struct ThemedButtonStyle: ButtonStyle {
    var prominent = false
    @AppStorage(DisplayStyle.storageKey) private var style = "system"
    @AppStorage(ParanoidLook.key) private var paranoid = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label.font(Theme.control).lineLimit(1).minimumScaleFactor(0.8)
        return Group {
            if DisplayStyle.read(style) == .world {
                label.textCase(.uppercase).tracking(1.2).padding(.horizontal, 18).padding(.vertical, 11)
                    .foregroundStyle(enabled ? (prominent ? Color(hex: 0x0C191B) : Theme.text) : Theme.secondary.opacity(0.6))
                    .background(WorldButtonBackground(primary: prominent && enabled, pressed: configuration.isPressed))
            } else if DisplayStyle.read(style).mono {
                label.padding(.horizontal, 16).padding(.vertical, 10)
                    .foregroundStyle(enabled ? (prominent ? Color.black : Theme.mint) : Theme.accentDim)
                    .background {
                        ZStack {
                            ChamferShape(cut: 6).fill(prominent && enabled ? Theme.mint : (configuration.isPressed ? Theme.soft : Theme.background))
                            ChamferShape(cut: 6).inset(by: 1).stroke(enabled ? Theme.mint : Theme.line, lineWidth: 2)
                        }
                    }
            } else {
                label.padding(.horizontal, 16).padding(.vertical, 10)
                    .foregroundStyle(prominent ? Color(hex: 0x03100A) : Theme.mint)
                    .background(prominent ? AnyShapeStyle(Theme.mint) : AnyShapeStyle(configuration.isPressed ? Theme.soft : Theme.panel), in: Capsule())
                    .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.line, lineWidth: 1))
                    .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            }
        }
    }
}
struct PixelOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        if Theme.world {
            configuration.label.font(Theme.control).textCase(.uppercase).tracking(1.4).frame(maxWidth: .infinity).padding(.vertical, 17)
                .foregroundStyle(enabled ? Theme.text : Theme.secondary.opacity(0.6))
                .background(WorldButtonBackground(primary: false, pressed: configuration.isPressed))
        } else {
        configuration.label.font(Theme.control).frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(enabled ? Theme.mint : Theme.accentDim)
            .background {
                ZStack {
                    ChamferShape(cut: 7).fill(configuration.isPressed ? Theme.soft : Theme.background)
                    ChamferShape(cut: 7).inset(by: 1).stroke(enabled ? Theme.mint : Theme.line, lineWidth: 2)
                }
            }
        }
    }
}
struct SectionHeading: View {
    let title: String
    var body: some View {
        if Theme.world { Text(title.uppercased()).font(.system(size: 17, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.text) }
        else { Text(title).font(Theme.editorial(22)).foregroundStyle(Theme.cyber ? Theme.mint : Theme.text) }
    }
}
struct EmptyCollection: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Theme.mint).frame(width: 64, height: 64)
                .background(Theme.mint.opacity(0.05), in: Circle()).overlay(Circle().stroke(Theme.line))
            Text(title).font(Theme.editorial(25)).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.vertical, 26).padding(.horizontal, 12)
    }
}
struct AppTabBar: View {
    @AppStorage("websiteTabRevision") private var websiteRevision = 0
    @AppStorage(DisplayStyle.storageKey) private var style="system"
    @AppStorage(ParanoidLook.key) private var paranoid=false
    @Binding var selected: Int
    @AppStorage(TabLayout.storageKey) private var rawTabs = TabLayout.encoded(TabLayout.defaults)
    var body: some View {
        let _ = websiteRevision
        Group {
            if DisplayStyle.read(style) == .world {worldBar}
            else if DisplayStyle.read(style).mono {pixelBar}
            else {classicBar}
        }
    }
    /// Game command bar: the game's glowing metal bar frame, game icons, selected tab lit in lime.
    private var worldBar:some View {
        HStack(spacing:2) {
            ForEach(0..<4) { index in
                Button {selected=index} label: {
                    VStack(spacing:3) {
                        WorldIcon(tab: index == 0 ? "home" : TabLayout.read(rawTabs)[index-1].icon, size: 30)
                            .opacity(selected == index ? 1 : 0.72)
                        Text((index == 0 ? "Home" : TabLayout.read(rawTabs)[index-1].title).uppercased()).font(.system(size:9.5,weight:.heavy)).tracking(0.8).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(selected == index ? Theme.accent2 : Theme.secondary)
                    }.frame(maxWidth:.infinity).padding(.vertical,5)
                        .background {
                            if selected == index {
                                ZStack(alignment:.bottom) {
                                    RoundedRectangle(cornerRadius:6).fill(LinearGradient(colors:[Theme.soft,Theme.soft.opacity(0.4)],startPoint:.bottom,endPoint:.top))
                                    Capsule().fill(Theme.accent2).frame(width:28,height:3).shadow(color:Theme.mint,radius:4).padding(.bottom,1)
                                }
                            }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(selected == index ? .isSelected : [])
            }
        }.padding(.horizontal,22).padding(.vertical,11)
            .background(WorldFrame(kind: .tab))
            .padding(.horizontal,6).padding(.bottom,2)
            .background(Theme.background.ignoresSafeArea(edges:.bottom))
    }
    /// Pixel bottom bar (.bottom-nav): background colour, 2-point outline on top, accent icons and labels,
    /// selected tab on the accent fill.
    private var pixelBar:some View {
        HStack(spacing:4) {
            ForEach(0..<4) { index in
                Button {selected=index} label: {
                    VStack(spacing:5) {
                        TabSymbol(name:index == 0 ? "house" : TabLayout.read(rawTabs)[index-1].icon,size:19,weight:.regular).frame(height:22)
                        Text(index == 0 ? "Home" : TabLayout.read(rawTabs)[index-1].title).font(Theme.pixel(11)).lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth:.infinity).padding(.vertical,8)
                        .foregroundStyle(Theme.mint)
                        .background(selected == index ? Theme.soft : .clear,in:RoundedRectangle(cornerRadius:10))
                }.buttonStyle(.plain).accessibilityAddTraits(selected == index ? .isSelected : [])
            }
        }.padding(.horizontal,8).padding(.top,6).padding(.bottom,2)
            .background(Theme.background.ignoresSafeArea(edges:.bottom))
            .overlay(alignment:.top) { Rectangle().fill(Theme.line).frame(height:2) }
    }
    private var classicBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<4) { index in
                Button { selected = index } label: {
                    VStack(spacing: 5) {
                        TabSymbol(name: index == 0 ? "house" : TabLayout.read(rawTabs)[index - 1].icon, size: 19, weight: .light).frame(height: 23)
                        Text(index == 0 ? "Home" : TabLayout.read(rawTabs)[index - 1].title).font(.caption2.weight(.medium))
                        Circle().fill(selected == index ? Theme.mint : .clear).frame(width: 3, height: 3)
                    }.foregroundStyle(selected == index ? Theme.mint : Theme.secondary).frame(maxWidth: .infinity).padding(.top, 13).padding(.bottom, 5)
                }.buttonStyle(.plain).accessibilityAddTraits(selected == index ? .isSelected : [])
            }
        }.background(Theme.background.ignoresSafeArea(edges: .bottom)).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}


/// Octagon with cut corners: the pixel looks' panels (10 pt) and buttons (7 pt).
struct ChamferShape: InsettableShape {
    var cut: CGFloat
    var insetAmount: CGFloat = 0
    func inset(by amount: CGFloat) -> ChamferShape { var c = self; c.insetAmount += amount; return c }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(max(cut - insetAmount * 0.41, 0), r.width / 4, r.height / 4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c)); p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c)); p.closeSubpath()
        return p
    }
}
/// Small pixel ticker for "Live State": moves while the device node is verifying.
struct LiveStateDots: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: active && !reduceMotion ? 0.25 : 3600)) { timeline in
            Canvas { context, size in
                let step = Int(timeline.date.timeIntervalSinceReferenceDate * 4)
                var seed = UInt64(truncatingIfNeeded: active ? step : 7) &* 6364136223846793005 &+ 1442695040888963407
                for x in stride(from: CGFloat(0), to: size.width, by: 5) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let y = CGFloat(seed >> 61) * (size.height / 8)
                    context.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Theme.mint.opacity(active ? 0.9 : 0.45)))
                }
            }
        }.accessibilityHidden(true)
    }
}

/// Gives list and form rows the look of the current style: the game's metal bar frames in Parano1d World,
/// chamfered pixel panels in Cyber, and in the standard looks the Home card: a deep panel with a thin outline.
struct ThemedRow: ViewModifier {
    /// Kept for older call sites; the standard look always uses the panel card.
    var standard: Color? = nil
    func body(content: Content) -> some View {
        if Theme.world { content.listRowBackground(WorldFrame(kind: .auto)).listRowInsets(EdgeInsets(top: 13, leading: 28, bottom: 13, trailing: 28)) }
        else if Theme.cyber { content.listRowBackground(PixelPanelBackground(cut: 7)) }
        else { content.listRowBackground(StandardRowBackground()).listRowSeparator(.hidden) }
    }
}
/// A standard-look list row: the same panel and outline as the Home cards.
struct StandardRowBackground: View {
    @AppStorage(ParanoidLook.key) private var paranoid = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}
extension View {
    func themedRow() -> some View { modifier(ThemedRow()) }
    func themedRow(standard: Color) -> some View { modifier(ThemedRow(standard: standard)) }
}
/// Corner bracket around the pixel Home hero (.cy-corner): an L drawn on the top and left edges.
struct PixelCorner: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); return p
    }
}
/// Registers Departure Mono for this process as well as through Info.plist, so the pixel looks never fall
/// back to the system font if the plist entry is missed by a build.
enum PixelFont {
    static func register() {
        guard UIFont(name: "DepartureMono-Regular", size: 12) == nil,
              let url = Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

// MARK: - Parano1d World game art

/// The game's art (App/World-*.png, cut from the Parano1d World game's art sheets), loaded once at a fixed scale.
enum WorldArt {
    private static var cache: [String: UIImage] = [:]
    static func image(_ name: String, scale: CGFloat = 3) -> UIImage? {
        let key = name + "@" + String(describing: scale)
        if let hit = cache[key] { return hit }
        guard let url = Bundle.main.url(forResource: "World-" + name, withExtension: "png"),
              let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: scale) else { return nil }
        cache[key] = image
        return image
    }
}
/// The game's metal HUD frames as stretchable backgrounds. Only the plain middle of each edge stretches, so
/// corners, rivets and lit trims keep their shape.
struct WorldFrame: View {
    enum Kind { case panel, card, button, chip, tab, auto }
    var kind: Kind
    var body: some View {
        if kind == .auto {
            // Cards and rows of any size: the big frame when there is room for its corners, the bar frame otherwise.
            GeometryReader { geo in
                // Big riveted frame for tall cards, the bar frame for medium ones, the thin bar for short rows.
                if geo.size.height >= 96 && geo.size.width >= 120 { WorldFrame(kind: .card) }
                else if geo.size.height >= 52 && geo.size.width >= 80 { WorldFrame(kind: .button) }
                else if geo.size.height >= 35 && geo.size.width >= 70 { WorldFrame(kind: .chip) }
                else { RoundedRectangle(cornerRadius: 6).fill(Theme.panel).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1)) }
            }
        } else {
            framed
        }
    }
    @ViewBuilder private var framed: some View {
        let spec: (String, CGFloat, EdgeInsets) = {
            switch kind {
            case .card, .auto: return ("frameA", 5, EdgeInsets(top: 24, leading: 40, bottom: 22, trailing: 40))
            case .panel: return ("frameA", 4, EdgeInsets(top: 30, leading: 50, bottom: 27.5, trailing: 50))
            case .button: return ("frameB", 4, EdgeInsets(top: 25.75, leading: 30, bottom: 25.75, trailing: 30))
            case .chip: return ("frameC", 3, EdgeInsets(top: 17, leading: 33, bottom: 17, trailing: 33))
            case .tab: return ("frameTab", 3, EdgeInsets(top: 32.5, leading: 40, bottom: 32.5, trailing: 40))
            }
        }()
        if let ui = WorldArt.image(spec.0, scale: spec.1) {
            // Paranoid mode: the lit trims turn ignotus orange, like every other accent.
            Image(uiImage: ui).resizable(capInsets: spec.2, resizingMode: .stretch).hueRotation(.degrees(ParanoidLook.enabled ? -62 : 0))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(Theme.panel).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }
}
/// Game button: the metal bar frame; the main action is lit with the game's lime gradient inside it.
struct WorldButtonBackground: View {
    var primary: Bool
    var pressed = false
    var body: some View {
        ZStack {
            WorldFrame(kind: .button)
            ChamferShape(cut: 7).fill(primary ? AnyShapeStyle(LinearGradient(colors: ParanoidLook.enabled ? [Color(hex: 0xFFC37D), Color(hex: 0xFF9B36)] : [Color(hex: 0xC8F59E), Color(hex: 0x8FC97C)], startPoint: .top, endPoint: .bottom))
                                              : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x1F362D), Color(hex: 0x0C191B)], startPoint: .top, endPoint: .bottom)))
                .padding(.horizontal, 8).padding(.vertical, 9)
                .opacity(pressed ? 0.75 : 1)
                .shadow(color: primary ? Theme.mint.opacity(0.45) : .clear, radius: 8)
        }
    }
}
/// A game icon (App/World-icon-*.png, full-resolution cuts from the game's icon sheets).
/// `tab` accepts an SF Symbol name or a short key.
struct WorldIcon: View {
    var tab: String
    var size: CGFloat = 44
    /// The game icon that fits a symbol or key, or nil when none fits (the symbol is kept then).
    static func match(_ name: String) -> String? {
        let n = name.lowercased()
        // Game icons: home (HQ compound), comms (headset helmet), nfts (trophy), ecosystem (globe), alliance (banners),
        // games (crossed blades), receipts (map), network (radio), node (beacon), privacy (shield), dome (energy dome),
        // squad (helmet), more (wrench drone), receive (holo beacon), send (truck), sync (return arrow), build (crane),
        // support (medkit), nearby (drone), mining (drill).
        let keys = ["home","comms","nfts","ecosystem","alliance","games","receipts","network","node","privacy","dome","squad","more","receive","send","sync","build","support","nearby","mining"]
        if keys.contains(n) { return n }
        switch n {
        case "chat": return "comms"
        case "trade": return "alliance"
        case "contacts": return "squad"
        case "security": return "dome"
        default: break
        }
        if n == "house" || n.hasPrefix("house") || n.hasPrefix("wallet") || n.hasPrefix("building") { return "home" }
        if n.contains("bubble") || n.hasPrefix("message") { return n.contains("exclamation") ? nil : "comms" }
        if n.contains("square.stack") || n.contains("layers") || n.hasPrefix("photo") || n.hasPrefix("trophy") { return "nfts" }
        if n.hasPrefix("globe") || n.hasPrefix("safari") || n.hasPrefix("compass") { return "ecosystem" }
        if n.hasPrefix("gamecontroller") || n.hasPrefix("flag") { return "games" }
        if n.hasPrefix("chart") || n.contains("arrow.left.arrow.right") || n.contains("arrow.up.arrow.down") || n.hasPrefix("handshake") { return "alliance" }
        if n.hasPrefix("book") { return "receipts" }
        if n.hasPrefix("flask") || n.hasPrefix("testtube") { return "build" }
        if n.hasPrefix("clock.arrow") || n.hasPrefix("doc.text") || n.hasPrefix("list.bullet") || n.hasPrefix("archivebox") || n.hasPrefix("map") { return "receipts" }
        if n.hasPrefix("network") || n.hasPrefix("antenna") || n.hasPrefix("wifi") { return "network" }
        if n.hasPrefix("cpu") || n.hasPrefix("server") || n.hasPrefix("gauge") { return "node" }
        if n.contains("shield") { return "privacy" }
        if n.hasPrefix("lock") || n.hasPrefix("key") || n.hasPrefix("faceid") || n.hasPrefix("touchid") || n.hasPrefix("hand.raised") { return "dome" }
        if n.hasPrefix("gearshape") || n.hasPrefix("slider") || n.hasPrefix("ellipsis") { return "more" }
        if n.hasPrefix("person") { return "squad" }
        if n.hasPrefix("qrcode") || n.hasPrefix("arrow.down") || n.hasPrefix("tray") { return "receive" }
        if n.hasPrefix("arrow.up.right") || n.hasPrefix("paperplane") { return "send" }
        if n.hasPrefix("bell") || n.hasPrefix("arrow.clockwise") || n.hasPrefix("arrow.triangle") { return "sync" }
        if n.hasPrefix("paintpalette") || n.hasPrefix("paintbrush") || n.hasPrefix("hammer") || n.hasPrefix("wrench") { return "build" }
        if n.hasPrefix("info") || n.hasPrefix("envelope") || n.hasPrefix("questionmark") || n.hasPrefix("lifepreserver") || n.hasPrefix("cross") { return "support" }
        if n.contains("radiowaves") || n.hasPrefix("point.3") { return "nearby" }
        if n == "pickaxe" || n.hasPrefix("bolt") || n.hasPrefix("cube") { return "mining" }
        return nil
    }
    static func key(_ name: String) -> String { match(name) ?? "more" }
    var body: some View {
        if tab == "pickaxe" {
            // Mining's menu icon is the pickaxes from the Parano1d World Mining emblem, lit like the game icons.
            Image("MiningGlyph").renderingMode(.template).resizable().scaledToFit()
                .frame(width: size * 0.78, height: size * 0.78).frame(width: size, height: size)
                .foregroundStyle(Theme.mint).shadow(color: Theme.mint.opacity(0.45), radius: 3)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1).accessibilityHidden(true)
        } else if let ui = WorldArt.image("icon-" + Self.key(tab), scale: 3) {
            Image(uiImage: ui).resizable().interpolation(.high).antialiased(true).scaledToFit().frame(width: size, height: size)
                .hueRotation(.degrees(ParanoidLook.enabled ? -62 : 0))
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1).accessibilityHidden(true)
        } else {
            Image(systemName: tab).font(.system(size: size * 0.55)).frame(width: size, height: size).foregroundStyle(Theme.mint)
        }
    }
}
/// A list or button label whose icon becomes the matching game icon in Parano1d World
/// (other looks, and symbols with no fitting game icon, keep the SF Symbol).
struct ThemedLabel: View {
    var title: String
    var systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        if Theme.world, WorldIcon.match(systemImage) != nil {
            Label { Text(title) } icon: { WorldIcon(tab: systemImage, size: 30) }
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}
/// The icon half of a themed label, for custom Label { } icon: { } layouts.
struct ThemedIcon: View {
    var systemName: String
    var size: CGFloat = 32
    var body: some View {
        if Theme.world, WorldIcon.match(systemName) != nil { WorldIcon(tab: systemName, size: size) }
        else { Image(systemName: systemName).foregroundStyle(Theme.mint) }
    }
}

// MARK: - App-wide styling for Cyber and Parano1d World

extension View {
    /// A card background in the current style: game frame (World), pixel panel (Cyber), rounded panel (standard).
    func themedCard(_ radius: CGFloat) -> some View { modifier(ThemedCard(radius: radius)) }
    /// A rounded outline that only the standard look draws (the framed styles carry their own edges).
    func themedOutline(_ radius: CGFloat, _ color: Color, _ width: CGFloat) -> some View { modifier(ThemedOutline(radius: radius, color: color, width: width)) }
}
struct ThemedCard: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        // World: extra inner padding keeps text clear of the frame's metal edge.
        if Theme.world { content.padding(.horizontal, 8).padding(.vertical, 6).background(WorldFrame(kind: .auto)) }
        else if Theme.cyber { content.background(PixelPanelBackground(cut: radius >= 16 ? 10 : 7)) }
        else { content.background(Theme.panel, in: RoundedRectangle(cornerRadius: radius)) }
    }
}
struct ThemedOutline: ViewModifier {
    var radius: CGFloat; var color: Color; var width: CGFloat
    func body(content: Content) -> some View {
        if Theme.cyber { content } else { content.overlay(RoundedRectangle(cornerRadius: radius).stroke(color, lineWidth: width)) }
    }
}
/// UIKit pieces SwiftUI can't restyle directly: navigation titles and segmented pickers.
enum ThemeChrome {
    static func apply() {
        configure()
        refreshVisibleBars()
    }
    /// UIAppearance only reaches bars created afterwards, so bars already on screen
    /// (an open settings sheet) keep the old look's title colour unless updated here.
    private static func refreshVisibleBars() {
        let proxy = UINavigationBar.appearance()
        let title = proxy.titleTextAttributes ?? [:], large = proxy.largeTitleTextAttributes ?? [:]
        func visit(_ view: UIView) {
            if let bar = view as? UINavigationBar {
                bar.titleTextAttributes = title; bar.largeTitleTextAttributes = large
                for appearance in [bar.standardAppearance, bar.scrollEdgeAppearance, bar.compactAppearance].compactMap({ $0 }) {
                    appearance.titleTextAttributes = title.isEmpty ? [.foregroundColor: UIColor.label] : title
                    appearance.largeTitleTextAttributes = large.isEmpty ? [.foregroundColor: UIColor.label] : large
                }
                bar.setNeedsLayout()
            }
            view.subviews.forEach(visit)
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windows = (scene as? UIWindowScene)?.windows else { continue }
            for window in windows { visit(window) }
        }
    }
    private static func configure() {
        let nav = UINavigationBar.appearance()
        let seg = UISegmentedControl.appearance()
        guard Theme.cyber else {
            // Standard looks: system type, with segmented controls in the panel and accent of the Home cards.
            nav.titleTextAttributes = [:]; nav.largeTitleTextAttributes = [:]
            seg.backgroundColor = UIColor(Theme.panel)
            seg.selectedSegmentTintColor = UIColor(Theme.soft)
            // Scales with the iPhone's text size, like the rest of the app.
            let metrics = UIFontMetrics(forTextStyle: .subheadline)
            seg.setTitleTextAttributes([.foregroundColor: UIColor(Theme.secondary), .font: metrics.scaledFont(for: .systemFont(ofSize: 13, weight: .medium))], for: .normal)
            seg.setTitleTextAttributes([.foregroundColor: UIColor(Theme.mint), .font: metrics.scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))], for: .selected)
            return
        }
        let text = UIColor(Theme.text), accent = UIColor(Theme.mint)
        let title: UIFont, large: UIFont, segFont: UIFont
        if Theme.world {
            title = .systemFont(ofSize: 16, weight: .black); large = .systemFont(ofSize: 30, weight: .black); segFont = .systemFont(ofSize: 12, weight: .heavy)
        } else {
            title = UIFont(name: "DepartureMono-Regular", size: 17) ?? .monospacedSystemFont(ofSize: 17, weight: .regular)
            large = UIFont(name: "DepartureMono-Regular", size: 30) ?? .monospacedSystemFont(ofSize: 30, weight: .regular)
            segFont = UIFont(name: "DepartureMono-Regular", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        nav.titleTextAttributes = [.font: title, .foregroundColor: Theme.world ? text : accent, .kern: Theme.world ? 1.5 : 0]
        nav.largeTitleTextAttributes = [.font: large, .foregroundColor: Theme.world ? text : accent, .kern: Theme.world ? 1.2 : 0]
        seg.backgroundColor = UIColor(Theme.panel)
        seg.selectedSegmentTintColor = UIColor(Theme.world ? Color(hex: 0x355842) : Theme.soft)
        seg.setTitleTextAttributes([.font: segFont, .foregroundColor: UIColor(Theme.secondary)], for: .normal)
        seg.setTitleTextAttributes([.font: segFont, .foregroundColor: Theme.world ? text : accent], for: .selected)
    }
}

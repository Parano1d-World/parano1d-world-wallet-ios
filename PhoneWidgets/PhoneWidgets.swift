import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets. They read only the small summary the app saves (see PhoneWidgetData);
/// they never contact the network or a mining computer. Amounts are marked privacy-sensitive, so iOS hides
/// them on a locked phone, and the balance shows "Hidden" while Hide balances is on.
private let mint = Color(red: 0x30 / 255, green: 0xE3 / 255, blue: 0x74 / 255)
private let ink = Color(red: 0x05 / 255, green: 0x0B / 255, blue: 0x09 / 255)

struct PhoneEntry: TimelineEntry {
    let date: Date
    let balance: PhoneWidgetData.Balance
    let mining: PhoneWidgetData.Mining?
    static func load() -> PhoneEntry { PhoneEntry(date: Date(), balance: PhoneWidgetData.balance(), mining: PhoneWidgetData.mining()) }
    static let sample = PhoneEntry(date: Date(),
        balance: .init(amount: "88.282987", hidden: false, verifiedAt: Date().addingTimeInterval(-240), height: 322_099),
        mining: .init(rigs: [.init(name: "Garage rig", online: true, running: true, hashrate: "1.2 MH/s", hottestC: 76, alert: nil),
                             .init(name: "Office PC", online: true, running: true, hashrate: "18.4 kH/s", hottestC: nil, alert: nil)], updated: Date()))
}

struct PhoneProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhoneEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (PhoneEntry) -> Void) { completion(context.isPreview ? .sample : .load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneEntry>) -> Void) {
        // The app reloads these after each check; this is only a fallback so "updated … ago" stays right.
        completion(Timeline(entries: [.load()], policy: .after(Date().addingTimeInterval(900))))
    }
}

// MARK: Balance

struct BalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PhoneEntry
    private var b: PhoneWidgetData.Balance { entry.balance }
    private var amount: String { b.hidden ? "Hidden" : (b.amount ?? "—") }
    private var stale: Bool { b.verifiedAt.map { Date().timeIntervalSince($0) > 3600 } ?? true }
    var body: some View {
        switch family {
        case .accessoryInline:
            Text(b.hidden ? "NOID hidden" : "NOID \(b.amount ?? "—")").privacySensitive()
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text("NOID").font(.system(size: 9, weight: .bold))
                Text(b.hidden ? "•••" : short(b.amount)).font(.system(size: 14, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5).privacySensitive()
            }.widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Parano1d").font(.caption2.weight(.semibold)).widgetAccentable()
                Text(amount + (b.hidden ? "" : " NOID")).font(.headline).minimumScaleFactor(0.6).lineLimit(1).privacySensitive()
                checked
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label("NOID", systemImage: "checkmark.shield").font(.caption.weight(.semibold)).foregroundStyle(mint)
                Spacer(minLength: 0)
                Text(amount).font(.system(.title2, design: .rounded).weight(.semibold)).minimumScaleFactor(0.4).lineLimit(1)
                    .foregroundStyle(.white).privacySensitive()
                checked.foregroundStyle(stale ? .orange : .white.opacity(0.7))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var checked: some View {
        if let at = b.verifiedAt {
            if stale { Text("Saved \(at, style: .relative) ago").font(.caption2).lineLimit(1) }
            else { Text("Verified \(at, style: .relative) ago").font(.caption2).lineLimit(1) }
        } else { Text("Open the app to verify").font(.caption2) }
    }
}

struct BalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetData.balanceKind, provider: PhoneProvider()) { entry in
            BalanceWidgetView(entry: entry).containerBackground(ink, for: .widget).widgetURL(URL(string: "paramo1d://wallet"))
        }
        .configurationDisplayName("NOID balance")
        .description("Your balance as last verified by this iPhone's own node. Hidden when Hide balances is on.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: Mining

struct MiningWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PhoneEntry
    var body: some View {
        if let m = entry.mining, !m.rigs.isEmpty {
            switch family {
            case .accessoryInline:
                Text("\(m.mining)/\(m.rigs.count) mining" + (m.offline > 0 ? " · \(m.offline) offline" : ""))
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mining").font(.caption2.weight(.semibold)).widgetAccentable()
                    Text("\(m.mining) of \(m.rigs.count) mining").font(.headline).lineLimit(1)
                    Text(m.rigs.first(where: { $0.alert != nil })?.alert ?? hottest(m)).font(.caption2).lineLimit(1)
                }
            default:
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Image(systemName: "hammer.fill"); Text("Mining") }.font(.caption.weight(.semibold)).foregroundStyle(mint)
                    ForEach(Array(m.rigs.prefix(family == .systemMedium ? 3 : 2).enumerated()), id: \.offset) { _, rig in
                        HStack(spacing: 6) {
                            Circle().fill(!rig.online ? .orange : rig.running ? mint : .gray).frame(width: 7, height: 7)
                            Text(rig.name).font(.caption).lineLimit(1).foregroundStyle(.white)
                            Spacer(minLength: 2)
                            Text(rig.online ? (rig.hashrate ?? (rig.running ? "…" : "Idle")) : "Offline").font(.caption.monospacedDigit())
                                .foregroundStyle(rig.online ? .white : .orange).lineLimit(1)
                            if family == .systemMedium, let t = rig.hottestC {
                                Text("\(t)°").font(.caption.monospacedDigit()).foregroundStyle(t >= 80 ? .orange : .white.opacity(0.7))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if let alert = m.rigs.first(where: { $0.alert != nil })?.alert {
                        Text(alert).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    } else {
                        Text("Updated \(m.updated, style: .relative) ago").font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mining").font(.caption.weight(.semibold)).foregroundStyle(mint)
                Text("Pair a computer in the Mining tab.").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func hottest(_ m: PhoneWidgetData.Mining) -> String {
        if let t = m.rigs.compactMap(\.hottestC).max() { return "Hottest GPU \(t) °C" }
        return "Updated \(m.updated.formatted(date: .omitted, time: .shortened))"
    }
}

struct MiningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PhoneWidgetData.miningKind, provider: PhoneProvider()) { entry in
            MiningWidgetView(entry: entry).containerBackground(ink, for: .widget).widgetURL(URL(string: "paramo1d://mining"))
        }
        .configurationDisplayName("Mining")
        .description("Your paired computers: mining or offline, hashrate and GPU temperature, from their last signed status.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private func short(_ value: String?) -> String {
    guard let value, let number = Double(value.replacingOccurrences(of: ",", with: "")) else { return "—" }
    if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
    if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
    return String(format: number >= 100 ? "%.0f" : "%.1f", number)
}

@main
struct Parano1dPhoneWidgets: WidgetBundle {
    var body: some Widget { BalanceWidget(); MiningWidget() }
}

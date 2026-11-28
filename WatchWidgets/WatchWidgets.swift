import SwiftUI
import WidgetKit

/// Complications and Smart Stack widgets. They read the small summary the
/// watch app saves after each iPhone snapshot; they never contact the iPhone
/// or the network, and show "Hidden" when Hide balances is on.
struct GlanceEntry: TimelineEntry {
    let date: Date
    let balance: String?
    let hidden: Bool
    let status: String
    let price: String?
    let updated: Date?
    let pending: Int

    static func load() -> GlanceEntry {
        let defaults = UserDefaults(suiteName: WatchEdition.appGroup)
        let updated = defaults?.object(forKey: "glance.updated") as? Double
        return GlanceEntry(date: Date(), balance: defaults?.string(forKey: "glance.balance"),
                           hidden: defaults?.bool(forKey: "glance.hidden") ?? false,
                           status: defaults?.string(forKey: "glance.status") ?? "",
                           price: defaults?.string(forKey: "glance.price"),
                           updated: updated.map { Date(timeIntervalSince1970: $0) },
                           pending: defaults?.integer(forKey: "glance.pending") ?? 0)
    }
    static let sample = GlanceEntry(date: Date(), balance: "88.28", hidden: false, status: "Verified", price: nil, updated: Date(), pending: 0)
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) { completion(context.isPreview ? .sample : .load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        // The watch app reloads timelines on each snapshot; this is only a fallback refresh.
        completion(Timeline(entries: [.load()], policy: .after(Date().addingTimeInterval(1800))))
    }
}

private let mint = Color(red: 0x30 / 255, green: 0xE3 / 255, blue: 0x74 / 255)

struct BalanceGlanceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry
    private var amount: String { entry.hidden ? "Hidden" : (entry.balance ?? "—") }
    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text("NOID").font(.system(size: 9, weight: .bold)).foregroundStyle(mint)
                Text(entry.hidden ? "•••" : short(entry.balance)).font(.system(size: 14, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5)
            }.widgetAccentable()
        case .accessoryInline:
            Text(entry.hidden ? "NOID hidden" : "NOID \(entry.balance ?? "—")")
        case .accessoryCorner:
            Text(entry.hidden ? "•••" : short(entry.balance)).widgetLabel { Text("NOID") }
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text("Parano1d").font(.caption2.weight(.semibold)).foregroundStyle(mint).widgetAccentable()
                Text(amount + (entry.hidden ? "" : " NOID")).font(.headline).minimumScaleFactor(0.6).lineLimit(1)
                if let price = entry.price { Text("NOID \(price) est.").font(.caption2) }
                else if let updated = entry.updated { Text("Saved \(updated, style: .relative) ago").font(.caption2) }
                if entry.pending > 0 { Text("\(entry.pending) pending").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }
    private func short(_ value: String?) -> String {
        guard let value, let number = Double(value.replacingOccurrences(of: ",", with: "")) else { return "—" }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return String(format: number >= 100 ? "%.0f" : "%.1f", number)
    }
}

struct BalanceGlance: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Parano1dBalance", provider: GlanceProvider()) { entry in
            BalanceGlanceView(entry: entry).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("NOID balance")
        .description("Your last verified balance from the iPhone. Hidden when Hide balances is on.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct Parano1dWatchWidgets: WidgetBundle {
    var body: some Widget { BalanceGlance() }
}

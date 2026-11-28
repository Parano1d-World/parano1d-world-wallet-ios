import SwiftUI
#if canImport(MetricKit)
import MetricKit
#endif

/// Crash reports collected by iOS (MetricKit). After a crash, iOS hands the report to
/// the app on a later launch; it is saved on this phone only (excluded from backups)
/// until the person shares or deletes it. Reports hold stack traces and device
/// details — never keys, addresses, balances or messages.
final class CrashReports: NSObject {
    static let shared = CrashReports()
    static let changed = Notification.Name("CrashReports.changed")
    private static let limit = 20
    struct Report: Identifiable, Hashable {
        let id: String
        let date: Date
        let summary: String
        let url: URL
    }
    func start() {
        #if canImport(MetricKit) && !os(watchOS)
        MXMetricManager.shared.add(self)
        if #available(iOS 14.0, *) { save(MXMetricManager.shared.pastDiagnosticPayloads) }
        #endif
    }
    static func folder() throws -> URL {
        var url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CrashReports", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
        return url
    }
    static func list() -> [Report] {
        guard let folder = try? folder(),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let date = (object["saved"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            return Report(id: url.lastPathComponent, date: date, summary: object["summary"] as? String ?? "Crash", url: url)
        }.sorted { $0.date > $1.date }
    }
    static func delete(_ report: Report) { try? FileManager.default.removeItem(at: report.url); NotificationCenter.default.post(name: changed, object: nil) }
    static func deleteAll() { for report in list() { try? FileManager.default.removeItem(at: report.url) }; NotificationCenter.default.post(name: changed, object: nil) }
    #if canImport(MetricKit) && !os(watchOS)
    private func save(_ payloads: [MXDiagnosticPayload]) {
        guard let folder = try? Self.folder() else { return }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        for payload in payloads {
            guard let crashes = payload.crashDiagnostics, !crashes.isEmpty else { continue }
            for crash in crashes {
                var parts: [String] = []
                if let type = crash.exceptionType { parts.append("exception \(type)") }
                if let signal = crash.signal { parts.append("signal \(signal)") }
                if let reason = crash.terminationReason, !reason.isEmpty { parts.append(reason) }
                let report = crash.jsonRepresentation()
                let name = String(report.hashValue, radix: 16).replacingOccurrences(of: "-", with: "n")
                let record: [String: Any] = [
                    "saved": payload.timeStampEnd.timeIntervalSince1970,
                    "app_version": crash.applicationVersion,
                    "installed_version": version,
                    "summary": parts.isEmpty ? "Crash" : parts.joined(separator: " · "),
                    "diagnostic": (try? JSONSerialization.jsonObject(with: report)) ?? [:],
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { continue }
                try? data.write(to: folder.appendingPathComponent("crash-\(Int(payload.timeStampEnd.timeIntervalSince1970))-\(name).json"),
                                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        for old in Self.list().dropFirst(Self.limit) { try? FileManager.default.removeItem(at: old.url) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    #endif
}
#if canImport(MetricKit) && !os(watchOS)
extension CrashReports: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }
}
#endif

struct CrashReportsView: View {
    @State private var reports = CrashReports.list()
    @State private var confirmDeleteAll = false
    var body: some View {
        List {
            Section {
                Text("If Parano1d crashes, iOS delivers a crash report the next time the app opens (sometimes up to a day later). Reports stay on this phone until you share or delete them. They contain technical details only — no keys, addresses, balances or messages.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }.themedRow()
            if reports.isEmpty {
                Text("No crash reports on this phone.").foregroundStyle(Theme.secondary)
            } else {
                Section("Reports") {
                    ForEach(reports) { report in
                        NavigationLink { CrashReportDetail(report: report) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(report.date.formatted(date: .abbreviated, time: .standard)).font(Theme.subheadline)
                                Text(report.summary).font(Theme.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                            }
                        }
                    }.onDelete { offsets in for index in offsets { CrashReports.delete(reports[index]) }; reports = CrashReports.list() }
                }.themedRow()
                Section { Button("Delete all crash reports", role: .destructive) { confirmDeleteAll = true } }.themedRow()
            }
        }
        .navigationTitle("Crash reports").navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: CrashReports.changed).receive(on: RunLoop.main)) { _ in reports = CrashReports.list() }
        .confirmationDialog("Delete all crash reports?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { CrashReports.deleteAll(); reports = [] }
        }
    }
}

struct CrashReportDetail: View {
    let report: CrashReports.Report
    @State private var text = ""
    @State private var copied = false
    var body: some View {
        ScrollView {
            Text(text).font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(report.summary).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "Copied" : "Copy") { UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]); copied = true }
                ShareLink(item: report.url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share crash report")
            }
        }
        .task { text = (try? String(contentsOf: report.url, encoding: .utf8)) ?? "Report unreadable." }
    }
}

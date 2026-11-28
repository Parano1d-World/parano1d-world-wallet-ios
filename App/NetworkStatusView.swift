import SwiftUI

/// "Network check": a plain-language health check of everything the phone needs to
/// verify the chain and send NOID, tokens and NFTs on its own, with a fix for each problem.
struct NetworkStatusView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var data: LiveData
    @EnvironmentObject private var node: DeviceNode
    @ObservedObject private var moderation = PublicModerationStore.shared
    enum Level { case ok, warn, bad }
    private var parametersPresent: Bool { Bundle.main.url(forResource: "NodeParameters", withExtension: nil) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary
                Panel {
                    SectionHeading(title: "Checks")
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in line(row.0, row.1, row.2) }
                }
                Panel {
                    SectionHeading(title: "Details")
                    if let height = node.verifiedHeight { LabeledContent("Verified block", value: String(height)).font(Theme.subheadline) }
                    if let height = node.nativeStateHeight { LabeledContent("Token and NFT data block", value: String(height)).font(Theme.subheadline) }
                    if let height = data.holdingsHeight { LabeledContent("Holdings checked at block", value: String(height)).font(Theme.subheadline) }
                    LabeledContent("Wallet route", value: NodeEndpoints.paranoid ? "Peers only" : "Endpoint, then peers").font(Theme.subheadline)
                    if let issue = node.nativeStateIssue { Text(issue).font(Theme.caption).foregroundStyle(.orange) }
                    if let error = node.error { Text(error).font(Theme.caption).foregroundStyle(.orange) }
                    NavigationLink("Node controls") { DeviceNodeView() }.font(Theme.subheadline)
                }
                Text("Everything here runs on this phone. It checks the chain's proofs itself and talks to peers directly; no gateway or account is needed. Fees are read from the exact transaction you sign.")
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(AmbientBackground()).navigationTitle("Network check").navigationBarTitleDisplayMode(.inline)
        .refreshable { runCheck() }
    }

    private var summary: some View {
        let worst = rows.map(\.2)
        let bad = worst.contains(.bad), warn = worst.contains(.warn)
        return Panel {
            HStack(spacing: 12) {
                Image(systemName: bad ? "xmark.octagon.fill" : warn ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 30)).foregroundStyle(bad ? .red : warn ? .orange : Theme.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bad ? "Something needs attention" : warn ? "Working, with a note" : "Ready to send").font(Theme.headline)
                    Text(bad ? "See the red item below for what to do." : warn ? "Sending may wait until the orange item clears." : "NOID, tokens and NFTs can be sent from this phone.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }
            Button { runCheck() } label: {
                Label(node.running || data.refreshing ? "Checking…" : "Run check now", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }.buttonStyle(MintButtonStyle()).disabled(node.running || data.refreshing || wallet.offlineMode || wallet.locked)
        }
    }

    private var rows: [(String, String, Level)] {
        var out: [(String, String, Level)] = []
        if wallet.offlineMode { out.append(("Internet", "Offline mode is on. Turn it off in Settings to use the network.", .bad)) }
        else { out.append(("Internet", "Allowed", .ok)) }
        if let vpn = vpnRow { out.append(vpn) }
        if !DeviceNodeBridge.available || !parametersPresent { out.append(("On-device node", "Missing from this build.", .bad)) }
        else if !node.enabled { out.append(("On-device node", "Off. Turn it on in Node controls to verify and send.", .bad)) }
        else if node.running { out.append(("On-device node", node.syncStage.map { "Working: " + $0 } ?? "Checking the chain…", .ok)) }
        else if let retry = node.retryAt, retry > Date() {
            out.append(("On-device node", "Last try failed. Retrying \(retry.formatted(.relative(presentation: .named))). Peers may be busy; staying on a stable connection helps.", .warn))
        } else { out.append(("On-device node", "Ready", .ok)) }
        if let at = node.verifiedAt {
            let minutes = Int(Date().timeIntervalSince(at) / 60)
            out.append(("Peers and chain", minutes < 15 ? "Verified \(minutes == 0 ? "just now" : "\(minutes) min ago")" : "Last verified \(minutes / 60 > 0 ? "\(minutes / 60) h" : "\(minutes) min") ago. Run a check.", minutes < 15 ? .ok : .warn))
        } else { out.append(("Peers and chain", "Not verified yet. Keep the app open on a stable connection.", node.running ? .warn : .bad)) }
        if let chain = node.verifiedHash {
            if node.nativeStateHash == nil { out.append(("Tokens and NFTs", "Downloading their data. This happens once, then only small updates.", .warn)) }
            else if node.nativeStateHash != chain {
                let behind = (node.verifiedHeight ?? 0) &- (node.nativeStateHeight ?? 0)
                out.append(("Tokens and NFTs", "Catching up\(behind > 0 && behind < 10_000 ? " (\(behind) blocks behind)" : ""). Sending opens when it matches.", .warn))
            } else if !(data.holdingsVerifiedLocally && data.holdingsHash == chain) {
                out.append(("Tokens and NFTs", "Refreshing your holdings…", .warn))
            } else { out.append(("Tokens and NFTs", "Ready to send", .ok)) }
        }
        if moderation.status.lowercased().contains("unavailable") || moderation.status.lowercased().contains("rejected") {
            out.append(("Public chat safety list", "Couldn't load the latest list. Earlier decisions still apply.", .warn))
        }
        return out
    }

    private var vpnRow: (String, String, Level)? { nil }

    private func line(_ title: String, _ detail: String, _ level: Level) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level == .ok ? "checkmark.circle.fill" : level == .warn ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(level == .ok ? Theme.mint : level == .warn ? .orange : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.subheadline.weight(.medium))
                Text(detail).font(Theme.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }

    private func runCheck() {
        guard !wallet.offlineMode, !wallet.locked else { return }
        node.synchronize(unlocked: true, offline: false, force: true, owner: AddressValidator.valid(wallet.address) ? wallet.address : nil)
        if AddressValidator.valid(wallet.address) { data.refresh(owner: wallet.address, offline: false, force: true) }
    }
}

import SwiftUI

/// Optional extra node endpoints and direct peer submission (Settings → Network).
/// Order: the Parano1d World node (once live), the person's backups, the public node, then mainnet peers.
/// Parano1d mode uses peers only. Every endpoint only relays the
/// same signed bytes or serves data the phone checks itself; none can sign.
enum NodeEndpoints {
    static let storageKey = "node.extraEndpoints.v1"
    static let directPeersKey = "node.directPeerSubmission.v1"
    /// Paranoid mode: wallet balance, sending and receipts go directly through
    /// mainnet P2P with zero wallet RPC (upstream Paramo1d 1.0 behavior).
    static let paranoidKey = "node.paranoidMode.v1"
    static var paranoid: Bool { UserDefaults.standard.bool(forKey: paranoidKey) }
    /// Node operations that take the Paranoid route when it is on.
    static let paranoidOperations: Set<String> = ["wallet_balance", "payment_plan", "payment_epoch_check", "broadcast_send", "native_submit", "transaction_status"]
    static var extra: [String] {
        (UserDefaults.standard.stringArray(forKey: storageKey) ?? []).filter(valid).prefix(3).map { $0 }
    }
    static var directPeers: Bool { UserDefaults.standard.bool(forKey: directPeersKey) }
    static func valid(_ text: String) -> Bool {
        guard text.count <= 200, let url = URL(string: text), url.scheme == "https", let host = url.host, host.contains("."),
              url.user == nil, url.password == nil, url.query == nil else { return false }
        return true
    }
}

struct NodeEndpointsSettingsView: View {
    @AppStorage(NodeEndpoints.directPeersKey) private var directPeers = false
    @AppStorage(NodeEndpoints.paranoidKey) private var paranoid = false
    @State private var endpoints: [String] = NodeEndpoints.extra
    @State private var draft = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                // Same setting as before (Paranoid mode); only the wording changed.
                // Wallet route only. Public chat is a separate choice (chat privacy setting).
                Picker("Connection", selection: $paranoid) {
                    Text("Peers (Parano1d mode)").tag(true)
                    Text("Endpoint").tag(false)
                }.pickerStyle(.segmented).accessibilityLabel("Wallet connection")
            } header: { Text("Connection") } footer: {
                Text(paranoid
                    ? "Peers — most private, no single server. Your balance, payment preparation, sending (NOID, tokens and NFTs) and receipt checks go straight to mainnet peers, never to a node endpoint. Can take a little longer. Chat is unaffected; public chat has its own on/off in chat privacy."
                    : "Endpoint — the default, usually faster. Your balance, payments and receipt checks go through a node: your backups, then the public node, then mainnet peers if no node answers. Your phone verifies everything it returns, and the chain itself always syncs from peers.")
            }.themedRow()
            Section {
                LabeledContent("Public node", value: "chat.parano1d.org")
                ForEach(endpoints, id: \.self) { endpoint in Text(endpoint).font(.footnote.monospaced()) }
                    .onDelete { endpoints.remove(atOffsets: $0); save() }
                if endpoints.count < 3 {
                    TextField("https://node.example.org/chain", text: $draft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Add endpoint") {
                        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard NodeEndpoints.valid(value) else { error = "Enter a full https address."; return }
                        guard !endpoints.contains(value) else { error = "Already added."; return }
                        endpoints.append(value); draft = ""; error = nil; save()
                    }.disabled(draft.isEmpty)
                }
                if let error { Text(error).font(Theme.caption).foregroundStyle(.orange) }
            } header: { Text("Node endpoints") } footer: {
                Text("The app tries your backups in order, then the public node. If none answers, it uses mainnet peers. They only carry your already signed payment and public chain data; the phone checks what they return.")
            }.themedRow()
            if !paranoid { Section {
                Toggle("Always send directly to peers too", isOn: $directPeers)
            } footer: {
                Text("Your device node always sends to peers when no endpoint accepts a payment. Turn this on to also send to peers every time. A peer listing your payment is not a confirmation; the receipt check still decides.")
            }.themedRow() }
        }
        .modifier(WalletSettingsSurface()).navigationTitle("Connection")
    }
    private func save() { UserDefaults.standard.set(endpoints, forKey: NodeEndpoints.storageKey) }
}

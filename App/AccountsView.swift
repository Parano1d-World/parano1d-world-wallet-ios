import SwiftUI

struct AccountsView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var message: String?
    @State private var scanStart: UInt32 = 0
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var importing = false
    @State private var creatingSeparate = false
    @State private var showHidden = false
    @State private var showManagement = false
    @State private var showDiscovery = false
    @State private var removingRoot: WalletProfile?
    @State private var removingAccount: WalletAccount?
    @State private var editingRoot: WalletProfile?
    @State private var editingAccount: WalletAccount?
    @State private var nameDraft = ""
    @State private var orderTick = 0
    @State private var reorderingAccounts = false
    @State private var reorderingWallets = false
    @State private var walletOrderDraft: [WalletProfile] = []
    /// Display order of the accounts under the selected key, saved on this device (public addresses only).
    private var orderKey: String { "accounts.displayOrder.v1." + (wallet.accounts.first(where: { $0.index == 0 })?.address ?? "") }
    private var orderedAccounts: [WalletAccount] {
        _ = orderTick
        let saved = (UserDefaults.standard.string(forKey: orderKey) ?? "").split(separator: ",").compactMap { UInt32($0) }
        return wallet.accounts.enumerated().sorted { a, b in
            let ia = saved.firstIndex(of: a.element.index) ?? (saved.count + a.offset)
            let ib = saved.firstIndex(of: b.element.index) ?? (saved.count + b.offset)
            return ia < ib
        }.map(\.element)
    }
    private func saveAccountOrder(_ accounts: [WalletAccount]) {
        UserDefaults.standard.set(accounts.map { String($0.index) }.joined(separator: ","), forKey: orderKey)
        orderTick += 1
    }
    /// Applies a dragged wallet order with one authentication, one step at a time through the vault.
    private func applyWalletOrder(_ target: [String]) {
        perform { token in
            var current = wallet.localWallet?.profiles.map(\.address) ?? []
            guard current != target, Set(current) == Set(target) else { return }
            let context = try await wallet.requireAuthentication("Reorder wallets")
            guard valid(token) else { return }
            for (position, root) in target.enumerated() {
                while let at = current.firstIndex(of: root), at > position {
                    let summary = try await WalletVault.shared.moveWallet(root, by: -1, context: context)
                    current.swapAt(at, at - 1)
                    guard valid(token) else { return }; wallet.apply(summary)
                }
            }
        }
    }
    private func moveAccount(_ index: UInt32, by offset: Int) {
        var order = orderedAccounts.map(\.index)
        guard let at = order.firstIndex(of: index), order.indices.contains(at + offset) else { return }
        order.swapAt(at, at + offset)
        UserDefaults.standard.set(order.map(String.init).joined(separator: ","), forKey: orderKey)
        withAnimation { orderTick += 1 }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                UnavailableNotice(needs:[.backup])
                Text("Your wallets").font(Theme.editorial(34))
                Text("Choose a master key, then an account derived from it. Each separate key needs its own backup. Hidden wallets remain on this device.").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                SectionHeading(title: "Master keys")
                ForEach((wallet.localWallet?.profiles ?? []).filter { !$0.hidden }) { profile in walletRow(profile) }
                DisclosureGroup("Organize and manage wallets", isExpanded: $showManagement) {
                    let hiddenProfiles = (wallet.localWallet?.profiles ?? []).filter { $0.hidden }
                    if !hiddenProfiles.isEmpty {
                        Button(showHidden ? "Collapse hidden wallets" : "Show hidden wallets (\(hiddenProfiles.count))") { showHidden.toggle() }
                            .font(Theme.subheadline).foregroundStyle(Theme.secondary)
                        if showHidden { ForEach(hiddenProfiles) { profile in walletRow(profile) } }
                    }
                    if (wallet.localWallet?.profiles.count ?? 0) > 1 {
                        Button { walletOrderDraft = wallet.localWallet?.profiles ?? []; reorderingWallets = true } label: {
                            Label("Reorder wallets", systemImage: "line.3.horizontal").font(Theme.subheadline)
                        }.foregroundStyle(Theme.mint).disabled(working)
                    }
                    Text("Use each wallet's menu to rename, set a default, hide, or remove it. Reorder wallets lets you drag them into any order. Your default opens at the next unlock. Hiding changes only this list, not on-chain visibility.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }.tint(Theme.mint)
                Button("Import a separate master key") { importing = true }.buttonStyle(ThemedButtonStyle())
                    .disabled(working || wallet.localWallet?.recoveryVerified != true)
                Button("Create a separate wallet") { creatingSeparate = true }.buttonStyle(ThemedButtonStyle())
                    .disabled(working || wallet.localWallet?.recoveryVerified != true)
                SectionHeading(title: "Accounts under selected key")
                ForEach(orderedAccounts) { account in
                    Panel {
                        Button { select(account.index) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(account.name).font(Theme.headline); Spacer(); if account.index == wallet.selectedIndex { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) } }
                            Text(account.address).font(.caption.monospaced()).lineLimit(2).foregroundStyle(Theme.secondary)
                            Text(account.knownUsed ? "Use observed · explorer-reported" : "Usage not yet established").font(Theme.caption).foregroundStyle(Theme.secondary)
                            }
                        }.buttonStyle(.plain).disabled(working)
                        HStack(spacing: 22) {
                            Button("Rename") { nameDraft = account.name; editingAccount = account }
                                .font(Theme.caption).foregroundStyle(Theme.mint).disabled(working)
                            if account.index != 0 {
                                Button("Remove account") { removingAccount = account }.font(Theme.caption).foregroundStyle(.red).disabled(working)
                            }
                        }
                    }
                }
                if wallet.accounts.count > 1 {
                    Button { reorderingAccounts = true } label: { Label("Reorder accounts", systemImage: "line.3.horizontal").font(Theme.caption) }
                        .foregroundStyle(Theme.mint).disabled(working)
                }
                Button("Add account under this key") { add() }.buttonStyle(MintButtonStyle()).disabled(working || wallet.localWallet?.recoveryVerified != true)
                DisclosureGroup("Find previously used accounts", isExpanded: $showDiscovery) {
                    Text("Scanning sends 20 derived public addresses to NOID Scan, never your key. Explorer history is incomplete: an empty result does not prove an account is unused.").font(Theme.footnote).foregroundStyle(Theme.secondary)
                    Button("Scan wallets \(scanStart + 1)–\(scanStart + 20)") { scan() }.buttonStyle(ThemedButtonStyle()).disabled(working || wallet.offlineMode || wallet.localWallet?.recoveryVerified != true || scanStart > 99981)
                }.tint(Theme.mint)
                if working { ProgressView() }
                if let message { Text(message).font(Theme.footnote).foregroundStyle(Theme.secondary) }
            }.padding(24)
        }.background(AmbientBackground()).navigationTitle("Wallets").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $importing) { WalletSetupView(mode: .importAdditional) }
        .navigationDestination(isPresented: $creatingSeparate) { WalletSetupView(mode: .createAdditional) }
        .alert("Rename master-key wallet", isPresented: Binding(get: { editingRoot != nil }, set: { if !$0 { editingRoot = nil } })) {
            TextField("Wallet name", text: $nameDraft)
            Button("Cancel", role: .cancel) { editingRoot = nil }
            Button("Save") { if let profile = editingRoot { renameRoot(profile.address, name: nameDraft) }; editingRoot = nil }
        } message: { Text("The name is saved only on this device. Your master key and address stay the same.") }
        .alert("Rename account", isPresented: Binding(get: { editingAccount != nil }, set: { if !$0 { editingAccount = nil } })) {
            TextField("Account name", text: $nameDraft)
            Button("Cancel", role: .cancel) { editingAccount = nil }
            Button("Save") { if let account = editingAccount { renameAccount(account.index, name: nameDraft) }; editingAccount = nil }
        } message: { Text("The name is saved only on this device. Its account index and address stay the same.") }
        .sheet(isPresented: $reorderingAccounts) {
            NavigationStack {
                List {
                    ForEach(orderedAccounts) { account in
                        VStack(alignment: .leading, spacing: 2) { Text(account.name); Text(account.address).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.secondary) }
                    }.onMove { source, destination in
                        var order = orderedAccounts; order.move(fromOffsets: source, toOffset: destination); saveAccountOrder(order)
                    }
                }
                .environment(\.editMode, .constant(.active))
                .navigationTitle("Reorder accounts").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { reorderingAccounts = false } } }
            }
        }
        .sheet(isPresented: $reorderingWallets) {
            NavigationStack {
                List {
                    ForEach(walletOrderDraft) { profile in
                        VStack(alignment: .leading, spacing: 2) { Text(profile.name); Text(profile.address).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.secondary) }
                    }.onMove { walletOrderDraft.move(fromOffsets: $0, toOffset: $1) }
                }
                .environment(\.editMode, .constant(.active))
                .navigationTitle("Reorder wallets").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reorderingWallets = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { let order = walletOrderDraft.map(\.address); reorderingWallets = false; applyWalletOrder(order) } }
                }
            }
        }
        .confirmationDialog("Remove local master key?", isPresented: Binding(get: { removingRoot != nil }, set: { if !$0 { removingRoot = nil } }), titleVisibility: .visible) {
            if let profile = removingRoot {
                Button("Remove \(profile.name) from this device", role: .destructive) { removeRoot(profile.address) }
            }
        } message: { Text("This deletes its local secret and saved account list. It does not move or erase on-chain funds. Confirm you have its master key backup. Pending payments block removal.") }
        .confirmationDialog("Remove saved account?", isPresented: Binding(get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }), titleVisibility: .visible) {
            if let account = removingAccount {
                Button("Remove \(account.name) from this device", role: .destructive) { removeAccount(account.index) }
            }
        } message: { Text("This removes the account from the list, not its funds or master key. You can derive it again with its account index.") }
        .onChange(of: wallet.locked) { _, locked in if locked { cancel() } }
        .onChange(of: wallet.offlineMode) { _, offline in if offline { cancel() } }
        .onDisappear { cancel() }
    }
    private func walletRow(_ profile: WalletProfile) -> some View {
        Panel {
            HStack(alignment: .top, spacing: 12) {
                Button { selectRoot(profile.address) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(profile.name).font(Theme.headline)
                            if profile.address == wallet.localWallet?.selectedRoot { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
                        }
                        Text(profile.address).font(.caption.monospaced()).lineLimit(2).foregroundStyle(Theme.secondary)
                        if profile.address == wallet.localWallet?.defaultRoot { Text("DEFAULT").font(.caption2.weight(.semibold)).foregroundStyle(Theme.mint) }
                        if profile.hidden { Text("HIDDEN FROM MAIN LIST").font(Theme.caption2).foregroundStyle(Theme.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(working)
                if showManagement { Menu {
                    Button("Rename") { nameDraft = profile.name; editingRoot = profile }
                    if profile.address != wallet.localWallet?.defaultRoot && !profile.hidden {
                        Button("Set as default") { setDefault(profile.address) }
                    }
                    if (wallet.localWallet?.profiles.count ?? 0) > 1 {
                        Button("Reorder wallets") { walletOrderDraft = wallet.localWallet?.profiles ?? []; reorderingWallets = true }
                    }
                    Button(profile.hidden ? "Show wallet" : "Hide wallet") { setHidden(profile.address, hidden: !profile.hidden) }
                    Button("Remove from this device", role: .destructive) { removingRoot = profile }
                } label: { Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.mint) }
                    .accessibilityLabel("Manage \(profile.name)").disabled(working)
                }
            }
            if profile.address == wallet.localWallet?.selectedRoot {
                NavigationLink("View this wallet's master key") { WalletSetupView(mode: .manage) }
                    .font(Theme.caption).foregroundStyle(Theme.mint).disabled(working)
            }
        }
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; working = false }
    private func perform(_ operation: @escaping (UUID) async throws -> Void) {
        guard !working, !wallet.locked else { return }
        working = true; message = nil; generation = UUID(); let token = generation
        task = Task {
            defer { if token == generation { working = false; task = nil } }
            do { try await operation(token) } catch { if valid(token) { message = error.localizedDescription } }
        }
    }
    private func valid(_ token: UUID) -> Bool { token == generation && !wallet.locked && !Task.isCancelled }
    private func select(_ index: UInt32) {
        perform { token in
            let context = try await wallet.requireAuthentication("Switch wallet account")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.selectAccount(index, context: context)
            guard valid(token) else { return }; wallet.apply(summary); dismiss()
        }
    }
    private func renameRoot(_ root: String, name: String) {
        perform { token in
            let context = try await wallet.requireAuthentication("Rename this wallet")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.renameWallet(root, to: name, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
        }
    }
    private func setDefault(_ root: String) {
        perform { token in
            let context = try await wallet.requireAuthentication("Set default wallet")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.setDefaultWallet(root, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
        }
    }
    private func moveRoot(_ root: String, by offset: Int) {
        perform { token in
            let context = try await wallet.requireAuthentication("Reorder wallets")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.moveWallet(root, by: offset, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
        }
    }
    private func setHidden(_ root: String, hidden: Bool) {
        perform { token in
            let context = try await wallet.requireAuthentication(hidden ? "Hide a wallet from the list" : "Show a hidden wallet")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.setWalletHidden(root, hidden: hidden, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
        }
    }
    private func renameAccount(_ index: UInt32, name: String) {
        perform { token in
            let context = try await wallet.requireAuthentication("Rename this account")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.renameAccount(index, to: name, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
        }
    }
    private func selectRoot(_ root: String) {
        perform { token in
            let context = try await wallet.requireAuthentication("Switch master key")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.selectWallet(root, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
        }
    }
    private func removeRoot(_ root: String) {
        perform { token in
            let context = try await wallet.requireAuthentication("Remove this wallet from this device",fresh:true)
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.removeWallet(root, context: context)
            guard valid(token) else { return }
            if let summary { wallet.apply(summary) } else { wallet.clearLocalWallet(); dismiss() }
        }
    }
    private func removeAccount(_ index: UInt32) {
        perform { token in
            let context = try await wallet.requireAuthentication("Remove this saved account",fresh:true)
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.removeAccount(index, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
        }
    }
    private func add() {
        perform { token in
            let context = try await wallet.requireAuthentication("Add a wallet under this master key")
            guard valid(token) else { return }
            let summary = try await WalletVault.shared.addAccount(context: context)
            guard valid(token) else { return }; wallet.apply(summary)
            message = "Wallet added. Your existing master key restores this account at index \(summary.selectedIndex)."
        }
    }
    private func scan() {
        perform { token in
            let context = try await wallet.requireAuthentication("Discover accounts from your master key")
            guard valid(token), !wallet.offlineMode else { return }
            let candidates = try await WalletVault.shared.candidates(start: scanStart, context: context)
            var used: [WalletAccount] = []
            for account in candidates {
                guard valid(token), !wallet.offlineMode else { return }
                let result = try await ExplorerClient.shared.address(account.address)
                let activity = result["activity"] as? [String: Any]
                let archive = result["archive"] as? [String: Any]
                let balance = UInt64(result["balance_micronoid"] as? String ?? "") ?? 0
                if balance > 0 || (activity?["total"] as? Int ?? 0) > 0 || (archive?["tx_count"] as? Int ?? 0) > 0 || (result["blocks_mined"] as? Int ?? 0) > 0 { used.append(account) }
            }
            guard valid(token), !wallet.offlineMode else { return }
            let summary = try await WalletVault.shared.rememberUsed(used, context: context)
            guard valid(token) else { return }; wallet.apply(summary)
            scanStart += 20
            message = "Found \(used.count) used accounts in this range. Continue scanning to check more. Historical coverage is incomplete; recovery discovery is not guaranteed exhaustive."
        }
    }
}

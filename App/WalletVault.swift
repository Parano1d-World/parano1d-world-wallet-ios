import Foundation
import Security
import LocalAuthentication

struct WalletAccount: Codable, Identifiable, Equatable {
    let index: UInt32
    let address: String
    var name: String
    var knownUsed: Bool
    var id: UInt32 { index }
}
struct StoredWallet: Codable {
    var version: Int
    let scheme: String
    let master: Data
    let address: String
    let created: Date
    var recoveryVerified: Bool
    var accounts: [WalletAccount]? = nil
    var selectedIndex: UInt32? = nil
    var displayName: String? = nil
    func validate() throws {
        guard (version == 1 || version == 2), scheme == "parano1d-master-entropy-v1", master.count == 32,
              AddressValidator.valid(address) else { throw AppFailure("Unsupported or damaged local wallet. Do not overwrite it.") }
        if version == 2 { guard accounts != nil, selectedIndex != nil else { throw AppFailure("The account registry is missing. Do not overwrite it.") } }
        if let displayName { guard Self.validName(displayName) else { throw AppFailure("Wallet name is invalid. Existing data was not replaced.") } }
    }
    static func validName(_ name: String) -> Bool {
        name == name.trimmingCharacters(in: .whitespacesAndNewlines) && !name.isEmpty && name.count <= 40 &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
struct WalletSummary {
    let address: String
    let recoveryVerified: Bool
    var accounts: [WalletAccount] = []
    var selectedIndex: UInt32 = 0
    var profiles: [WalletProfile] = []
    var selectedRoot: String = ""
    var defaultRoot: String = ""
}
struct WalletProfile: Identifiable, Equatable {
    let address: String
    let name: String
    var hidden: Bool = false
    var id: String { address }
}
private struct WalletPortfolio: Codable {
    let version: Int
    let originAddress: String
    var selectedRoot: String
    var wallets: [StoredWallet]
    var displayOrder: [String]? = nil
    var hiddenRoots: [String]? = nil
    var defaultRoot: String? = nil
    func validate() throws {
        guard version == 1, wallets.count > 0, wallets.count <= 16,
              wallets.first?.address == originAddress,
              Set(wallets.map(\.address)).count == wallets.count,
              wallets.contains(where: { $0.address == selectedRoot }) else {
            throw AppFailure("Wallet list is damaged. Existing data was not replaced.")
        }
        for wallet in wallets { try wallet.validate() }
        let roots = Set(wallets.map(\.address))
        if let displayOrder {
            guard displayOrder.count == wallets.count, Set(displayOrder) == roots else { throw AppFailure("Wallet display order is damaged. Existing data was not replaced.") }
        }
        if let hiddenRoots {
            guard Set(hiddenRoots).count == hiddenRoots.count, Set(hiddenRoots).isSubset(of: roots), hiddenRoots.count < wallets.count else { throw AppFailure("Hidden wallet list is damaged. Existing data was not replaced.") }
        }
        if let defaultRoot { guard roots.contains(defaultRoot) else { throw AppFailure("Default wallet is missing. Existing data was not replaced.") } }
    }
    var orderedRoots: [String] { displayOrder ?? wallets.map(\.address) }
    var effectiveDefault: String { defaultRoot ?? selectedRoot }
}
protocol WalletRecordStorage {
    func read(context: LAContext) throws -> Data?
    func insert(_ bytes: Data, context: LAContext) throws
    func update(_ bytes: Data, context: LAContext) throws
    func delete() throws
}
struct KeychainWalletStorage: WalletRecordStorage {
    private var identity: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.koajent.parano1d.wallet.v1", kSecAttrAccount as String: "primary", kSecAttrSynchronizable as String: false] }
    func read(context: LAContext) throws -> Data? {
        if let record = try AlternateWalletProtection.envelope() { return try AlternateWalletProtection.open(record,context:context) }
        return try readLegacy(context:context)
    }
    func readLegacy(context: LAContext) throws -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        // A PIN attempt must never silently fall through to the legacy
        // device-presence item and open a second Face ID prompt.
        if context.isCredentialSet(.applicationPassword) {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw AppFailure("Wallet storage could not be opened (\(status)). Existing data was not replaced.") }
        return bytes
    }
    func insert(_ bytes: Data, context: LAContext) throws {
        guard try AlternateWalletProtection.envelope() == nil else { throw AppFailure("A wallet already exists. Unlock it instead of replacing it.") }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else { throw AppFailure("Enable a device passcode to protect the wallet.") }
        var query = identity
        query[kSecAttrAccessControl as String] = access
        query[kSecValueData as String] = bytes
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppFailure(status == errSecDuplicateItem ? "A wallet already exists. Unlock it instead of creating another." : "Wallet could not be saved (\(status)).") }
    }
    func update(_ bytes: Data, context: LAContext) throws {
        if try AlternateWalletProtection.envelope() != nil { try AlternateWalletProtection.update(bytes,context:context); return }
        var query = identity; query[kSecUseAuthenticationContext as String] = context
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        guard status == errSecSuccess else { throw AppFailure("Wallet update failed (\(status)).") }
    }
    func delete() throws {
        try deleteLegacy()
        try AlternateWalletProtection.delete()
    }
    func deleteLegacy() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppFailure("Local wallet key deletion failed (\(status)). Keep the app locked and retry.")
        }
    }
}
/// A non-secret tombstone survives loss of the passcode-bound Keychain record.
/// It prevents a missing secret from silently becoming a new wallet.
protocol WalletIdentityStorage {
    var expectedAddress: String? { get }
    func remember(_ address: String) throws
    func forget() throws
}
struct PersistentWalletIdentity: WalletIdentityStorage {
    private let key = "localWalletExpectedAddress.v1"
    var expectedAddress: String? { UserDefaults.standard.string(forKey: key) }
    func remember(_ address: String) throws {
        if let existing = expectedAddress, existing != address {
            throw AppFailure("Recovery address does not match this device's original wallet.")
        }
        UserDefaults.standard.set(address, forKey: key)
        guard expectedAddress == address else { throw AppFailure("Wallet identity could not be saved. Do not deposit funds.") }
    }
    func forget() throws {
        UserDefaults.standard.removeObject(forKey: key)
        guard expectedAddress == nil else { throw AppFailure("Wallet identity could not be removed.") }
    }
}
/// Serializes creation/recovery; Keychain's unique primary record is authoritative.
/// No destructive replace/reset API is exposed. No iCloud Keychain synchronization.
actor WalletVault {
    static let shared = WalletVault()
    private let storage: WalletRecordStorage
    private let identity: WalletIdentityStorage
    private let core = NativeCore.shared
    private var busy = false
    init(storage: WalletRecordStorage = KeychainWalletStorage(), identity: WalletIdentityStorage = PersistentWalletIdentity()) { self.storage = storage; self.identity = identity }
    var hasRecordedIdentity: Bool { identity.expectedAddress != nil }
    func hasPINAccess() throws -> Bool { try AlternateWalletProtection.hasPIN() }
    func enablePINAccess(code: String, context: LAContext) throws {
        try enter(); defer { busy = false }
        guard let keychain = storage as? KeychainWalletStorage else { throw AppFailure("App-code access is unavailable for this wallet storage.") }
        let pin = LAContext()
        defer { pin.setCredential(nil,type:.applicationPassword); pin.invalidate() }
        guard pin.setCredential(Data(code.utf8),type:.applicationPassword) else { throw AppFailure("App-code protection is unavailable.") }
        if try AlternateWalletProtection.envelope() != nil {
            try AlternateWalletProtection.changePIN(context:context,newPINContext:pin)
        } else if let bytes = try keychain.readLegacy(context:context) {
            // Validate existing wallet structure before migrating its exact bytes.
            _ = try readPortfolio(context)
            try AlternateWalletProtection.create(bytes,deviceContext:context,pinContext:pin)
            try keychain.deleteLegacy()
        }
    }
    func finishPINAccess(context: LAContext) throws {
        try enter(); defer { busy = false }
        try AlternateWalletProtection.finishPINChange(context:context)
    }
    func revokePINAccess(context: LAContext) throws {
        try enter(); defer { busy = false }
        try AlternateWalletProtection.revokePIN(context:context)
    }

    /// Allows an explicit, authenticated restart only when the protected item
    /// really is missing. It never deletes an existing wallet or pending payment.
    func forgetMissingIdentity(context: LAContext) async throws {
        try enter(); defer { busy = false }
        guard let expected = identity.expectedAddress else { throw AppFailure("No missing wallet identity to reset.") }
        guard try storage.read(context: context) == nil else { throw AppFailure("A wallet is stored on this device. Open it or import another key instead.") }
        try await ensureNoUnresolvedPayment(root: expected)
        try identity.forget()
        guard identity.expectedAddress == nil else { throw AppFailure("The old identity could not be cleared.") }
    }
    /// Called only by the persisted app-code lockout policy. The identity
    /// marker remains, so a new wallet cannot silently replace this one.
    func eraseLocalSecretAfterLockout() throws {
        try enter(); defer { busy = false }
        try storage.delete()
    }
    func message(_ request:[String:Any],context:LAContext) async throws -> [String:Any] {
        try enter();defer { busy=false }
        guard let op=request["op"] as? String,["chat_profile","chat_group_seal","chat_seal","chat_seal_invoice","chat_seal_payment","chat_seal_receipt","chat_open","chat_open_archived","chat_open_saved","chat_inbox_auth","chat_push_auth"].contains(op) else {throw AppFailure("Unsupported messaging operation.")}
        guard let record=try read(context),record.recoveryVerified else {throw AppFailure("Unlock your wallet and verify its recovery backup first.")}
        var checked=request
        if op=="chat_seal_payment" {checked["journal_directory"]=try PaymentStorage.directory(root:record.address).path}
        return try await core.call(checked,master:record.master)
    }
    private func enter() throws { guard !busy else { throw AppFailure("A wallet operation is already in progress.") }; busy = true }
    private func readPortfolio(_ context: LAContext) throws -> WalletPortfolio? {
        guard var bytes = try storage.read(context: context) else { return nil }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let decoder = JSONDecoder()
        let portfolio: WalletPortfolio
        if let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["wallets"] != nil {
            portfolio = try decoder.decode(WalletPortfolio.self, from: bytes)
        } else {
            let legacy = try decoder.decode(StoredWallet.self, from: bytes)
            try legacy.validate()
            portfolio = WalletPortfolio(version: 1, originAddress: legacy.address, selectedRoot: legacy.address, wallets: [legacy])
        }
        try portfolio.validate()
        try identity.remember(portfolio.originAddress)
        return portfolio
    }
    private func read(_ context: LAContext) throws -> StoredWallet? {
        guard let portfolio = try readPortfolio(context) else { return nil }
        return portfolio.wallets.first(where: { $0.address == portfolio.selectedRoot })
    }
    private func writePortfolio(_ portfolio: WalletPortfolio, context: LAContext) throws {
        try portfolio.validate()
        var data = try JSONEncoder().encode(portfolio)
        defer { data.resetBytes(in: 0..<data.count) }
        try storage.update(data, context: context)
    }
    private func persist(_ wallet: StoredWallet, context: LAContext, insert: Bool) throws {
        if !insert, var portfolio = try readPortfolio(context) {
            guard let index = portfolio.wallets.firstIndex(where: { $0.address == portfolio.selectedRoot }), wallet.address == portfolio.selectedRoot else {
                throw AppFailure("Selected wallet changed. No changes were saved.")
            }
            portfolio.wallets[index] = wallet
            try writePortfolio(portfolio, context: context)
            return
        }
        var data = try JSONEncoder().encode(wallet)
        defer { data.resetBytes(in: 0..<data.count) }
        if insert { try storage.insert(data, context: context) } else { try storage.update(data, context: context) }
    }
    /// Where the person approved a payment. The wallet core refuses to sign without one,
    /// and a Watch approval must carry exactly what the Watch showed.
    enum ApprovalSource: String { case phone, watch }
    func authorizePayment(_ request:[String:Any],source:ApprovalSource,context:LAContext) async throws -> [String:Any] {
        try enter();defer{busy=false}
        guard let record=try read(context),record.recoveryVerified else{throw AppFailure("Complete recovery verification first.")}
        let selected=try await accountSummary(record)
        guard request["owner"] as? String==selected.address else{throw AppFailure("Selected account changed; review again.")}
        var input=request;input["op"]="payment_authorize";input["approval_source"]=source.rawValue;input["account_index"]=selected.selectedIndex
        input["journal_directory"]=try PaymentStorage.directory(root:record.address).path
        return try await core.call(input,master:record.master)
    }
    func authorizeNative(_ request:[String:Any],context:LAContext) async throws -> [String:Any] {
        try enter();defer{busy=false}
        guard let record=try read(context),record.recoveryVerified else{throw AppFailure("Complete recovery verification first.")}
        let selected=try await accountSummary(record)
        guard let operation=request["operation"] as? [String:Any],let plan=operation["native_plan"] as? [String:Any],plan["owner"] as? String==selected.address else{throw AppFailure("Selected wallet changed; review again.")}
        var input=request;input["op"]="authorize";input["account_index"]=selected.selectedIndex
        input["journal_directory"]=try PaymentStorage.directory(root:record.address).path
        return try await core.call(input,master:record.master)
    }
    private func accountSummary(_ record: StoredWallet) async throws -> WalletSummary {
        let accounts = record.accounts ?? [.init(index: 0, address: record.address, name: "Wallet 1", knownUsed: false)]
        guard !accounts.isEmpty, accounts.count <= 128, Set(accounts.map(\.index)).count == accounts.count,
              accounts.contains(where: { $0.index == 0 && $0.address == record.address }) else { throw AppFailure("Wallet account registry is damaged. Do not overwrite it.") }
        for account in accounts {
            guard account.index <= 100000, StoredWallet.validName(account.name),
                  try await core.address(master: record.master, index: account.index) == account.address else { throw AppFailure("An account does not match this master key.") }
        }
        let selected = record.selectedIndex ?? 0
        guard let active = accounts.first(where: { $0.index == selected }) else { throw AppFailure("Selected account is missing.") }
        return .init(address: active.address, recoveryVerified: record.recoveryVerified,
                     accounts: accounts.sorted { $0.knownUsed == $1.knownUsed ? $0.index < $1.index : $0.knownUsed }, selectedIndex: selected)
    }
    private func decoratedSummary(_ record: StoredWallet, context: LAContext) async throws -> WalletSummary {
        let portfolio = try readPortfolio(context)
        var result = try await accountSummary(record)
        if let portfolio {
            result.profiles = portfolio.orderedRoots.compactMap { root in
                guard let index = portfolio.wallets.firstIndex(where: { $0.address == root }) else { return nil }
                let wallet = portfolio.wallets[index]
                return WalletProfile(address: root, name: wallet.displayName ?? "Wallet \(index + 1)", hidden: portfolio.hiddenRoots?.contains(root) == true)
            }
            result.defaultRoot = portfolio.effectiveDefault
        }
        result.selectedRoot = portfolio?.selectedRoot ?? record.address
        return result
    }
    private func saveAccounts(_ input: StoredWallet, context: LAContext) async throws -> WalletSummary {
        var record = input
        record.version = 2
        record.selectedIndex = record.selectedIndex ?? 0
        _ = try await accountSummary(record)
        try persist(record, context: context, insert: false)
        guard let saved = try read(context), saved.selectedIndex == record.selectedIndex,
              saved.accounts == record.accounts else { throw AppFailure("Account changes could not be verified in storage.") }
        return try await decoratedSummary(saved, context: context)
    }
    func addAccount(context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var record = try read(context), record.recoveryVerified else { throw AppFailure("Verify your recovery backup first.") }
        let current = try await accountSummary(record)
        guard current.accounts.count < 128 else { throw AppFailure("This build supports up to 128 saved accounts.") }
        let next = (current.accounts.map(\.index).max() ?? 0) + 1
        guard next <= 100000 else { throw AppFailure("Account derivation limit reached.") }
        let address = try await core.address(master: record.master, index: next)
        record.accounts = current.accounts + [.init(index: next, address: address, name: "Wallet \(next + 1)", knownUsed: false)]
        record.selectedIndex = next
        return try await saveAccounts(record, context: context)
    }
    func selectAccount(_ index: UInt32, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var record = try read(context), record.recoveryVerified else { throw AppFailure("Verify your recovery backup first.") }
        record.accounts = try await accountSummary(record).accounts
        guard record.accounts!.contains(where: { $0.index == index }) else { throw AppFailure("Unknown account.") }
        record.selectedIndex = index
        return try await saveAccounts(record, context: context)
    }
    func renameAccount(_ index: UInt32, to name: String, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StoredWallet.validName(clean) else { throw AppFailure("Enter a wallet name of 1–40 characters without control characters.") }
        guard var record = try read(context), record.recoveryVerified else { throw AppFailure("Verify your recovery backup first.") }
        var accounts = try await accountSummary(record).accounts
        guard let position = accounts.firstIndex(where: { $0.index == index }) else { throw AppFailure("Unknown account.") }
        accounts[position].name = clean
        record.accounts = accounts
        return try await saveAccounts(record, context: context)
    }
    func renameWallet(_ root: String, to name: String, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StoredWallet.validName(clean) else { throw AppFailure("Enter a wallet name of 1–40 characters without control characters.") }
        guard var portfolio = try readPortfolio(context),
              let position = portfolio.wallets.firstIndex(where: { $0.address == root }),
              portfolio.wallets[position].recoveryVerified else { throw AppFailure("Unlock and verify that wallet's recovery backup first.") }
        portfolio.wallets[position].displayName = clean
        try writePortfolio(portfolio, context: context)
        guard let saved = try readPortfolio(context),
              saved.wallets.first(where: { $0.address == root })?.displayName == clean,
              let selected = saved.wallets.first(where: { $0.address == saved.selectedRoot }) else {
            throw AppFailure("Wallet name could not be verified in protected storage.")
        }
        return try await decoratedSummary(selected, context: context)
    }
    func setDefaultWallet(_ root: String, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var portfolio = try readPortfolio(context),
              let record = portfolio.wallets.first(where: { $0.address == root && $0.recoveryVerified }),
              portfolio.hiddenRoots?.contains(root) != true else { throw AppFailure("Select a visible wallet with a verified backup as your default.") }
        portfolio.defaultRoot = root
        portfolio.selectedRoot = root
        try writePortfolio(portfolio, context: context)
        guard let saved = try readPortfolio(context), saved.defaultRoot == root, saved.selectedRoot == root else { throw AppFailure("Default wallet change was not saved.") }
        return try await decoratedSummary(record, context: context)
    }
    func moveWallet(_ root: String, by offset: Int, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var portfolio = try readPortfolio(context), let selected = portfolio.wallets.first(where: { $0.address == portfolio.selectedRoot }) else { throw AppFailure("No saved wallet.") }
        var order = portfolio.orderedRoots
        guard let index = order.firstIndex(of: root), (index + offset) >= 0, (index + offset) < order.count else { throw AppFailure("Wallet cannot move in that direction.") }
        order.swapAt(index, index + offset)
        portfolio.displayOrder = order
        try writePortfolio(portfolio, context: context)
        guard try readPortfolio(context)?.orderedRoots == order else { throw AppFailure("Wallet order was not saved.") }
        return try await decoratedSummary(selected, context: context)
    }
    func setWalletHidden(_ root: String, hidden: Bool, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var portfolio = try readPortfolio(context), portfolio.wallets.contains(where: { $0.address == root }) else { throw AppFailure("This wallet is not stored on this device.") }
        var hiddenRoots = portfolio.hiddenRoots ?? []
        if hidden {
            guard root != portfolio.effectiveDefault else { throw AppFailure("Choose a different default before hiding this wallet.") }
            guard root != portfolio.selectedRoot else { throw AppFailure("Switch to another wallet before hiding this one.") }
            if !hiddenRoots.contains(root) { hiddenRoots.append(root) }
        } else { hiddenRoots.removeAll { $0 == root } }
        guard hiddenRoots.count < portfolio.wallets.count else { throw AppFailure("At least one wallet must remain visible.") }
        portfolio.hiddenRoots = hiddenRoots
        try writePortfolio(portfolio, context: context)
        guard let saved = try readPortfolio(context), saved.hiddenRoots?.contains(root) == hidden,
              let selected = saved.wallets.first(where: { $0.address == saved.selectedRoot }) else { throw AppFailure("Wallet visibility was not saved.") }
        return try await decoratedSummary(selected, context: context)
    }
    func candidates(start: UInt32, context: LAContext) async throws -> [WalletAccount] {
        try enter(); defer { busy = false }
        guard let record = try read(context), record.recoveryVerified, start <= 99981 else { throw AppFailure("Unlock a verified wallet and choose a supported scan range.") }
        _ = try await accountSummary(record)
        var result: [WalletAccount] = []
        for index in start..<(start + 20) {
            let address = try await core.address(master: record.master, index: index)
            result.append(.init(index: index, address: address, name: "Wallet \(index + 1)", knownUsed: false))
        }
        return result
    }
    func rememberUsed(_ found: [WalletAccount], context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var record = try read(context), record.recoveryVerified else { throw AppFailure("Verify recovery first.") }
        var saved = try await accountSummary(record).accounts
        for account in found {
            guard account.index <= 100000, try await core.address(master: record.master, index: account.index) == account.address else { throw AppFailure("Discovered account identity mismatch.") }
            if let i = saved.firstIndex(where: { $0.index == account.index }) { saved[i].knownUsed = true }
            else { var used = account; used.knownUsed = true; saved.append(used) }
        }
        record.accounts = saved
        // On recovery, open the first discovered used account if the current account is unused.
        if !(saved.first(where: { $0.index == (record.selectedIndex ?? 0) })?.knownUsed ?? false), let first = saved.filter({ $0.knownUsed }).min(by: { $0.index < $1.index }) { record.selectedIndex = first.index }
        return try await saveAccounts(record, context: context)
    }
    func summary(context: LAContext) async throws -> WalletSummary? {
        try enter(); defer { busy = false }
        guard var portfolio = try readPortfolio(context) else { return nil }
        if let preferred = portfolio.defaultRoot, preferred != portfolio.selectedRoot {
            portfolio.selectedRoot = preferred
            try writePortfolio(portfolio, context: context)
        }
        guard let record = portfolio.wallets.first(where: { $0.address == portfolio.selectedRoot }) else { throw AppFailure("Selected wallet is missing.") }
        let derived = try await core.address(master: record.master)
        guard derived == record.address else { throw AppFailure("Stored address does not match wallet secret. Wallet remains locked.") }
        return try await decoratedSummary(record, context: context)
    }
    func create(context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        // Idempotent: repeated taps/restarts resume the existing wallet.
        if let existing = try read(context) {
            guard try await core.address(master: existing.master) == existing.address else { throw AppFailure("Stored wallet identity is damaged. Do not overwrite it.") }
            return try await decoratedSummary(existing, context: context)
        }
        guard identity.expectedAddress == nil else { throw AppFailure("An existing wallet's protected secret is missing. Recover its original master key; creating a replacement is blocked.") }
        var master = Data(count: 32)
        defer { master.resetBytes(in: 0..<master.count) }
        let status = master.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AppFailure("Secure random generation failed.") }
        let address = try await core.address(master: master)
        let record = StoredWallet(version: 1, scheme: "parano1d-master-entropy-v1", master: master, address: address, created: Date(), recoveryVerified: false)
        try record.validate()
        try persist(record, context: context, insert: true)
        guard let saved = try read(context), saved.master == master, saved.address == address else { throw AppFailure("Saved wallet could not be verified. Do not deposit funds.") }
        return try await decoratedSummary(saved, context: context)
    }
    func createAdditional(context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var portfolio = try readPortfolio(context),
              portfolio.wallets.first(where: { $0.address == portfolio.selectedRoot })?.recoveryVerified == true else {
            throw AppFailure("Verify the selected wallet's backup before creating another wallet.")
        }
        guard portfolio.wallets.count < 16 else { throw AppFailure("This device supports up to 16 separate master keys.") }
        var master = Data(count: 32)
        defer { master.resetBytes(in: 0..<master.count) }
        let status = master.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AppFailure("Secure random generation failed.") }
        let address = try await core.address(master: master)
        guard !portfolio.wallets.contains(where: { $0.master == master || $0.address == address }) else { throw AppFailure("Wallet identity collision. Nothing was saved.") }
        let record = StoredWallet(version: 1, scheme: "parano1d-master-entropy-v1", master: master,
                                  address: address, created: Date(), recoveryVerified: false,
                                  displayName: "Wallet \(portfolio.wallets.count + 1)")
        try record.validate()
        if portfolio.defaultRoot == nil { portfolio.defaultRoot = portfolio.selectedRoot }
        portfolio.wallets.append(record)
        if portfolio.displayOrder != nil { portfolio.displayOrder?.append(address) }
        portfolio.selectedRoot = address
        try writePortfolio(portfolio, context: context)
        guard let saved = try readPortfolio(context), saved.selectedRoot == address,
              let selected = saved.wallets.first(where: { $0.address == address && $0.master == master && !$0.recoveryVerified }) else {
            throw AppFailure("The new wallet could not be verified in protected storage. Do not deposit funds.")
        }
        return try await decoratedSummary(selected, context: context)
    }
    func revealKey(context: LAContext) async throws -> String {
        try enter(); defer { busy = false }
        guard let record = try read(context) else { throw AppFailure("No local wallet.") }
        guard try await core.address(master: record.master) == record.address else { throw AppFailure("Stored wallet identity does not match its secret. Recovery display is blocked.") }
        return record.master.map { String(format: "%02x", $0) }.joined()
    }
    func verify(keyHex: String, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var record = try read(context) else { throw AppFailure("No local wallet.") }
        _ = try await core.call(["op": "check_key", "key_hex": keyHex], master: record.master)
        guard try await core.address(master: record.master) == record.address else { throw AppFailure("Stored wallet identity does not match its secret.") }
        record.recoveryVerified = true
        try persist(record, context: context, insert: false)
        guard let saved = try read(context), saved.recoveryVerified, saved.master == record.master, saved.address == record.address else { throw AppFailure("Backup verification could not be saved. Please try again; your wallet has not been replaced.") }
        return try await decoratedSummary(saved, context: context)
    }
    func recover(keyHex: String, name: String? = nil, context: LAContext) async throws -> WalletSummary {
        try await recover(request: ["op": "recover_key", "key_hex": keyHex], name: name, context: context)
    }
    private func recover(request: [String: Any], name: String?, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedName.isEmpty || StoredWallet.validName(trimmedName) else { throw AppFailure("Enter a wallet name of 1–40 characters without control characters.") }
        let recovered = try await core.call(request)
        guard let encoded = recovered["master_hex"] as? String, var master = Data(hex: encoded), let address = recovered["address"] as? String else { throw AppFailure("Recovery failed.") }
        defer { master.resetBytes(in: 0..<master.count) }
        guard try await core.address(master: master) == address else { throw AppFailure("Recovered key address mismatch.") }
        if var portfolio = try readPortfolio(context) {
            if portfolio.defaultRoot == nil {
                let currentVerified = portfolio.wallets.first(where: { $0.address == portfolio.selectedRoot })?.recoveryVerified == true
                portfolio.defaultRoot = currentVerified ? portfolio.selectedRoot : address
            }
            if let index = portfolio.wallets.firstIndex(where: { $0.address == address && $0.master == master }) {
                // A correct key completes an interrupted backup and selects its wallet.
                portfolio.wallets[index].recoveryVerified = true
            } else {
                guard portfolio.wallets.count < 16 else { throw AppFailure("This device supports up to 16 separate master keys.") }
                guard !portfolio.wallets.contains(where: { $0.address == address || $0.master == master }) else { throw AppFailure("Wallet identity collision. Nothing was imported.") }
                let added = StoredWallet(version: 1, scheme: "parano1d-master-entropy-v1", master: master,
                                         address: address, created: Date(), recoveryVerified: true,
                                         displayName: trimmedName.isEmpty ? nil : trimmedName)
                try added.validate()
                portfolio.wallets.append(added)
                if portfolio.displayOrder != nil { portfolio.displayOrder?.append(address) }
            }
            portfolio.selectedRoot = address
            portfolio.hiddenRoots?.removeAll { $0 == address }
            try writePortfolio(portfolio, context: context)
            guard let saved = try readPortfolio(context), saved.selectedRoot == address,
                  let selected = saved.wallets.first(where: { $0.address == address && $0.master == master && $0.recoveryVerified }) else {
                throw AppFailure("Imported wallet could not be verified in protected storage.")
            }
            return try await decoratedSummary(selected, context: context)
        }
        if let expected = identity.expectedAddress, expected != address {
            throw AppFailure("The saved wallet key is missing. Recover the original wallet, or explicitly reset its device marker before adding a different wallet.")
        }
        let record = StoredWallet(version: 1, scheme: "parano1d-master-entropy-v1", master: master, address: address, created: Date(), recoveryVerified: true,
                                  displayName: trimmedName.isEmpty ? nil : trimmedName)
        try record.validate(); try persist(record, context: context, insert: true)
        guard let saved = try read(context), saved.master == master else { throw AppFailure("Recovered wallet failed storage verification.") }
        return try await decoratedSummary(saved, context: context)
    }
    func importAdditional(keyHex: String, name: String? = nil, context: LAContext) async throws -> WalletSummary {
        try await recover(keyHex: keyHex, name: name, context: context)
    }
    func selectWallet(_ root: String, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard var portfolio = try readPortfolio(context), let record = portfolio.wallets.first(where: { $0.address == root }) else {
            throw AppFailure("This wallet is not stored on this device.")
        }
        guard try await core.address(master: record.master) == record.address else { throw AppFailure("Wallet identity mismatch.") }
        if portfolio.defaultRoot == nil { portfolio.defaultRoot = portfolio.selectedRoot }
        portfolio.selectedRoot = root
        portfolio.hiddenRoots?.removeAll { $0 == root }
        try writePortfolio(portfolio, context: context)
        guard try readPortfolio(context)?.selectedRoot == root else { throw AppFailure("Wallet selection was not saved.") }
        return try await decoratedSummary(record, context: context)
    }
    private func ensureNoUnresolvedPayment(root: String) async throws {
        let directory = try PaymentStorage.directory(root: root)
        let response = try await core.call(["op": "payment_pending", "journal_directory": directory.path])
        if let pending = response["pending"] as? [String: Any],
           !["cancelled", "finalized", "expired"].contains(pending["state"] as? String ?? "") {
            throw AppFailure("Resolve this wallet's pending payment before removing it.")
        }
    }
    /// Removes a locally stored imported key. The original key is retained
    /// while any other profile exists so identity recovery remains possible.
    func removeWallet(_ root: String, context: LAContext) async throws -> WalletSummary? {
        try enter(); defer { busy = false }
        guard var portfolio = try readPortfolio(context), portfolio.wallets.contains(where: { $0.address == root }) else {
            throw AppFailure("This wallet is not stored on this device.")
        }
        guard root != portfolio.originAddress || portfolio.wallets.count == 1 else {
            throw AppFailure("Remove imported wallets first. The original recovery identity must remain until this is the last wallet.")
        }
        try await ensureNoUnresolvedPayment(root: root)
        if portfolio.wallets.count == 1 {
            try storage.delete()
            try identity.forget()
            guard try storage.read(context: context) == nil else { throw AppFailure("Local wallet deletion could not be verified.") }
            return nil
        }
        portfolio.wallets.removeAll { $0.address == root }
        portfolio.displayOrder?.removeAll { $0 == root }
        portfolio.hiddenRoots?.removeAll { $0 == root }
        if portfolio.defaultRoot == root {
            portfolio.defaultRoot = portfolio.originAddress
            portfolio.hiddenRoots?.removeAll { $0 == portfolio.originAddress }
        }
        if portfolio.selectedRoot == root { portfolio.selectedRoot = portfolio.originAddress }
        try writePortfolio(portfolio, context: context)
        guard let saved = try readPortfolio(context), saved.wallets.count == portfolio.wallets.count,
              !saved.wallets.contains(where: { $0.address == root }),
              let selected = saved.wallets.first(where: { $0.address == saved.selectedRoot }) else {
            throw AppFailure("Wallet removal could not be verified in protected storage.")
        }
        return try await decoratedSummary(selected, context: context)
    }
    func removeAccount(_ index: UInt32, context: LAContext) async throws -> WalletSummary {
        try enter(); defer { busy = false }
        guard index != 0, var record = try read(context), record.recoveryVerified else {
            throw AppFailure("Only additional accounts can be removed here.")
        }
        let accounts = try await accountSummary(record).accounts
        guard accounts.contains(where: { $0.index == index }) else { throw AppFailure("Unknown account.") }
        try await ensureNoUnresolvedPayment(root: record.address)
        record.accounts = accounts.filter { $0.index != index }
        if record.selectedIndex == index { record.selectedIndex = 0 }
        return try await saveAccounts(record, context: context)
    }
}

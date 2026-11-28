import Foundation
import CryptoKit

/// Display-only snapshot from an earlier successful device-node verification.
/// It is never an input to payment planning or authorization.
struct LastBalanceSnapshot: Codable {
    let owner: String
    let micronoid: String
    let height: UInt64
    let blockHash: String
    let verifiedAt: Date
    func valid(for address: String) -> Bool {
        owner == address && AddressValidator.valid(owner) && Amounts.format(micronoid) != nil &&
        blockHash.count == 64 && Data(hex: blockHash)?.count == 32 &&
        verifiedAt <= Date() && height > 0
    }
}

actor LastBalanceStore {
    static let shared = LastBalanceStore()
    private func path(for owner: String) throws -> URL {
        guard AddressValidator.valid(owner) else { throw AppFailure("Invalid balance owner.") }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LastVerifiedBalances", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var directory=base;var values=URLResourceValues();values.isExcludedFromBackup=true
        try directory.setResourceValues(values)
        let digest=SHA256.hash(data:Data(owner.utf8)).map {String(format:"%02x",$0)}.joined()
        return base.appendingPathComponent(digest+".json")
    }
    func load(for owner: String) throws -> LastBalanceSnapshot? {
        let url=try path(for:owner)
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<4096 else{throw AppFailure("Stored balance is invalid.")}
        let snapshot=try JSONDecoder().decode(LastBalanceSnapshot.self,from:Data(contentsOf:url))
        guard snapshot.valid(for:owner) else{throw AppFailure("Stored balance identity is invalid.")}
        return snapshot
    }
    /// The wallet shown in the app, for the "Check balance" shortcut. Stored with the snapshots (complete
    /// file protection, not backed up), so it can only be read while the iPhone is unlocked.
    private func currentPath() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LastVerifiedBalances", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        return base.appendingPathComponent("current-wallet")
    }
    func setCurrent(_ owner: String?) throws {
        let url = try currentPath()
        guard let owner, AddressValidator.valid(owner) else { try? FileManager.default.removeItem(at: url); return }
        try Data(owner.utf8).write(to: url, options: [.atomic, .completeFileProtection])
    }
    func current() throws -> String? {
        let url = try currentPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let owner = String(decoding: try Data(contentsOf: url).prefix(80), as: UTF8.self)
        return AddressValidator.valid(owner) ? owner : nil
    }
    func save(_ snapshot:LastBalanceSnapshot) throws {
        guard snapshot.valid(for:snapshot.owner) else{throw AppFailure("Refusing to save an invalid balance snapshot.")}
        let url=try path(for:snapshot.owner)
        if let prior=try load(for:snapshot.owner),prior.verifiedAt>snapshot.verifiedAt{return}
        try JSONEncoder().encode(snapshot).write(to:url,options:[.atomic,.completeFileProtection])
    }
}

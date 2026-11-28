import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// One authoritative encrypted portfolio, with independent device-authentication
/// and application-password wrappers for its random encryption key.
/// No PIN, PIN verifier, or unencrypted portfolio is stored in this service.
struct AlternateWalletProtection {
    private static let service = "com.koajent.parano1d.wallet.protection.v2"
    struct Envelope: Codable {
        let version: Int
        let deviceKey: String
        let pinKey: String?
        let sealed: Data
        var previousPinKey: String? = nil
        var aad: Data { Data(("parano1d.wallet.v2|\(deviceKey)|\(pinKey ?? "none")" + (previousPinKey.map { "|previous:" + $0 } ?? "")).utf8) }
        func decrypt(using key: SymmetricKey) throws -> Data {
            try validate()
            return try AES.GCM.open(AES.GCM.SealedBox(combined:sealed),using:key,authenticating:aad)
        }
        func validate() throws {
            guard version == 2, UUID(uuidString: deviceKey) != nil,
                  (pinKey.map { UUID(uuidString: $0) != nil } ?? true),
                  (previousPinKey.map { UUID(uuidString:$0) != nil && $0 != pinKey } ?? true),
                  previousPinKey == nil || pinKey != nil,
                  sealed.count >= 28, sealed.count <= 1_048_576 else { throw AppFailure("Wallet protection record is damaged. Existing keys were not replaced.") }
        }
    }
    private static func query(_ account: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false]
    }
    private static func data(_ account: String, context: LAContext? = nil) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { q[kSecUseAuthenticationContext as String] = context }
        // An app-code credential must never fall through to a second Face ID prompt.
        if context?.isCredentialSet(.applicationPassword) == true { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw AppFailure("Wallet protection could not be opened (\(status)). Use device authentication to recover access; your wallet was not replaced.") }
        return bytes
    }
    static func envelope() throws -> Envelope? {
        guard let bytes = try data("portfolio") else { return nil }
        guard bytes.count <= 1_500_000 else { throw AppFailure("Wallet record exceeds its size limit.") }
        let record = try JSONDecoder().decode(Envelope.self,from:bytes); try record.validate(); return record
    }
    static func hasPIN() throws -> Bool { try envelope()?.pinKey != nil }
    private static func pinKey(_ record: Envelope, context: LAContext) throws -> (SymmetricKey,String) {
        for account in [record.pinKey,record.previousPinKey].compactMap({$0}) {
            if let bytes = try? data(account,context:context), bytes.count == 32 {
                let key = SymmetricKey(data:bytes)
                // Bind the wrapper to this exact portfolio before returning it.
                if (try? record.decrypt(using:key)) != nil { return (key,account) }
            }
        }
        throw AppFailure("App-code wallet protection could not be opened. Use device authentication to recover access.")
    }
    private static func key(_ record: Envelope, context: LAContext) throws -> SymmetricKey {
        if context.isCredentialSet(.applicationPassword) { return try pinKey(record,context:context).0 }
        guard let bytes = try data(record.deviceKey,context:context), bytes.count == 32 else { throw AppFailure("Wallet protection key is unavailable. Restore access using device authentication or your recovery backup.") }
        return SymmetricKey(data:bytes)
    }
    static func open(_ record: Envelope, context: LAContext) throws -> Data {
        try record.validate()
        return try record.decrypt(using:key(record,context:context))
    }
    private static func save(_ record: Envelope, insert: Bool) throws {
        let bytes = try JSONEncoder().encode(record)
        var q = query("portfolio")
        let status: OSStatus
        if insert {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            q[kSecValueData as String] = bytes
            status = SecItemAdd(q as CFDictionary,nil)
        } else { status = SecItemUpdate(q as CFDictionary,[kSecValueData as String:bytes] as CFDictionary) }
        guard status == errSecSuccess, try data("portfolio") == bytes else { throw AppFailure("Wallet protection update failed. Do not remove your recovery backup.") }
    }
    static func seal(_ bytes: Data, key: SymmetricKey, deviceKey: String, pinKey: String?, previousPinKey: String? = nil) throws -> Envelope {
        guard bytes.count <= 1_000_000 else { throw AppFailure("Wallet exceeds its storage limit.") }
        let header = Envelope(version:2,deviceKey:deviceKey,pinKey:pinKey,sealed:Data(),previousPinKey:previousPinKey)
        guard let encrypted = try AES.GCM.seal(bytes,using:key,authenticating:header.aad).combined else { throw AppFailure("Wallet encryption failed.") }
        return Envelope(version:2,deviceKey:deviceKey,pinKey:pinKey,sealed:encrypted,previousPinKey:previousPinKey)
    }
    private static func addKey(_ key: SymmetricKey, account: String, pin: Bool, context: LAContext) throws {
        var error: Unmanaged<CFError>?
        let flags: SecAccessControlCreateFlags = pin ? .applicationPassword : .userPresence
        guard let access = SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,flags,&error) else { throw AppFailure("Wallet access protection is unavailable.") }
        var q = query(account); q[kSecAttrAccessControl as String] = access
        q[kSecUseAuthenticationContext as String] = context
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw AppFailure("Could not save wallet access protection.") }
    }
    private static func removeKey(_ id: String) throws {
        let result = SecItemDelete(query(id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw AppFailure("Could not remove obsolete wallet access protection.") }
    }
    /// Commit the portfolio only after both wrappers are independently readable.
    static func create(_ bytes: Data, deviceContext: LAContext, pinContext: LAContext) throws {
        guard try envelope() == nil else { throw AppFailure("Wallet protection already exists.") }
        let key = SymmetricKey(size:.bits256), device = UUID().uuidString, pin = UUID().uuidString
        try addKey(key,account:device,pin:false,context:deviceContext)
        do {
            try addKey(key,account:pin,pin:true,context:pinContext)
            let record = try seal(bytes,key:key,deviceKey:device,pinKey:pin)
            guard try open(record,context:pinContext) == bytes, try open(record,context:deviceContext) == bytes else { throw AppFailure("Wallet access verification failed.") }
            try save(record,insert:true)
        } catch {
            // Preserve every wrapper on an ambiguous failure. A committed portfolio
            // must remain recoverable; erasure removes all service entries later.
            throw error
        }
    }

    static func update(_ bytes: Data, context: LAContext) throws {
        guard let record = try envelope() else { throw AppFailure("Wallet protection record is missing.") }
        try save(seal(bytes,key:key(record,context:context),deviceKey:record.deviceKey,pinKey:record.pinKey,previousPinKey:record.previousPinKey),insert:false)
    }
    static func changePIN(context: LAContext, newPINContext: LAContext) throws {
        guard let old = try envelope() else { throw AppFailure("Wallet protection record is missing.") }
        guard old.previousPinKey == nil else { throw AppFailure("Unlock once with your current app code to finish the interrupted code change, then try again. Device authentication still works.") }
        let key = try key(old,context:context), bytes = try open(old,context:context), pin = UUID().uuidString
        try addKey(key,account:pin,pin:true,context:newPINContext)
        let next = try seal(bytes,key:key,deviceKey:old.deviceKey,pinKey:pin,previousPinKey:old.pinKey)
        guard try open(next,context:newPINContext) == bytes else { throw AppFailure("New app-code access could not be verified.") }
        try save(next,insert:false)
        // Keep the former wrapper until the app-code verifier is committed.
        // If interrupted, the current verifier still opens one of the two wrappers.
    }
    static func finishPINChange(context: LAContext) throws {
        guard context.isCredentialSet(.applicationPassword), let old = try envelope(), old.previousPinKey != nil else { return }
        let (key,accepted) = try pinKey(old,context:context)
        let bytes = try old.decrypt(using:key)
        try save(seal(bytes,key:key,deviceKey:old.deviceKey,pinKey:accepted),insert:false)
        for obsolete in [old.pinKey,old.previousPinKey].compactMap({$0}) where obsolete != accepted { try removeKey(obsolete) }
    }
    static func revokePIN(context: LAContext) throws {
        guard let old = try envelope(), let pin = old.pinKey else { return }
        let key = try key(old,context:context), bytes = try open(old,context:context)
        try save(seal(bytes,key:key,deviceKey:old.deviceKey,pinKey:nil),insert:false)
        try removeKey(pin)
        if let previous = old.previousPinKey { try removeKey(previous) }
    }
    static func delete() throws {
        // Delete the portfolio first, then all its key wrappers. The legacy record
        // must already have been removed by KeychainWalletStorage.delete().
        let result = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw AppFailure("Wallet access keys could not be erased. Keep the app locked and retry.") }
    }
}

import Foundation
import Security
import LocalAuthentication

/// Optional alternate app unlock. The capability is a device-only Keychain item
/// bound to the current biometric enrollment, never a seed or a PIN verifier.
enum BiometricUnlock {
    private static let service="com.koajent.parano1d.biometric-unlock.v1"
    private static var query:[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"enabled"] }
    static func configure(enabled:Bool) throws {
        if !enabled {
            let result=SecItemDelete(query as CFDictionary)
            guard result==errSecSuccess || result==errSecItemNotFound else{throw AppFailure("Could not disable biometric unlock.")}
            return
        }
        var error:Unmanaged<CFError>?
        guard let access=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,.biometryCurrentSet,&error) else{throw AppFailure("Biometric protection is unavailable.")}
        var bytes=Data(count:32)
        let generated=bytes.withUnsafeMutableBytes {SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!)}
        guard generated==errSecSuccess else{throw AppFailure("Secure random generation failed.")}
        let removed=SecItemDelete(query as CFDictionary)
        guard removed==errSecSuccess || removed==errSecItemNotFound else{throw AppFailure("Could not update biometric unlock.")}
        var attributes=query;attributes[kSecAttrAccessControl as String]=access;attributes[kSecValueData as String]=bytes
        guard SecItemAdd(attributes as CFDictionary,nil)==errSecSuccess else{throw AppFailure("Could not save biometric unlock.")}
    }
    static func verify(context:LAContext) throws {
        var attributes=query;attributes[kSecReturnData as String]=true;attributes[kSecUseAuthenticationContext as String]=context
        var result:CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary,&result)==errSecSuccess,let bytes=result as? Data,bytes.count==32 else{throw AppFailure("Biometric unlock is unavailable or enrollment changed. Use your app code and enable it again in Settings.")}
    }
}

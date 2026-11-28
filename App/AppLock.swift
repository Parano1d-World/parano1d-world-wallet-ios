import Foundation
import Security

enum AppCodeKind:String,Codable,CaseIterable,Identifiable,Hashable {
    case six,four,password
    var id:String {rawValue}
    var label:String {switch self {case .six:return "6-digit PIN";case .four:return "4-digit PIN";case .password:return "Password"}}
    var digits:Int? {switch self {case .six:return 6;case .four:return 4;case .password:return nil}}
    func validate(_ value:String) throws {
        if let digits {
            guard value.utf8.count==digits,value.utf8.allSatisfy({(48...57).contains($0)}) else{throw AppFailure("Enter exactly \(digits) digits.")}
            guard Set(value).count>1,!["1234","4321","0123","9876","123456","654321","012345","987654","1212","121212"].contains(value) else{throw AppFailure("Choose a less predictable PIN.")}
        } else {
            guard value.count>=12,value.count<=128,value.utf8.count<=512,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw AppFailure("Use a password of 12–128 characters.")}
        }
    }
}
struct AppCodeRecord:Codable {
    let version:Int
    let kind:AppCodeKind
    let salt:String
    let digest:String
    var attempts:Int
    var nextAttempt:Date
    var eraseOnTenFailures:Bool = false
    var erasePending:Bool = false
    var eraseCompleted:Bool = false
    enum CodingKeys:String,CodingKey {case version,kind,salt,digest,attempts,nextAttempt,eraseOnTenFailures,erasePending,eraseCompleted}
    init(version:Int,kind:AppCodeKind,salt:String,digest:String,attempts:Int,nextAttempt:Date,eraseOnTenFailures:Bool=false,erasePending:Bool=false,eraseCompleted:Bool=false) {
        self.version=version;self.kind=kind;self.salt=salt;self.digest=digest;self.attempts=attempts;self.nextAttempt=nextAttempt
        self.eraseOnTenFailures=eraseOnTenFailures;self.erasePending=erasePending;self.eraseCompleted=eraseCompleted
    }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version);kind=try c.decode(AppCodeKind.self,forKey:.kind)
        salt=try c.decode(String.self,forKey:.salt);digest=try c.decode(String.self,forKey:.digest)
        attempts=try c.decode(Int.self,forKey:.attempts);nextAttempt=try c.decode(Date.self,forKey:.nextAttempt)
        eraseOnTenFailures=try c.decodeIfPresent(Bool.self,forKey:.eraseOnTenFailures) ?? false
        erasePending=try c.decodeIfPresent(Bool.self,forKey:.erasePending) ?? false
        eraseCompleted=try c.decodeIfPresent(Bool.self,forKey:.eraseCompleted) ?? false
    }
}
protocol AppCodeStorage {func read() throws -> Data?;func save(_ data:Data) throws;func remove() throws}
struct KeychainAppCode:AppCodeStorage {
    private var query:[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.koajent.parano1d.applock.v1",kSecAttrAccount as String:"local",kSecAttrSynchronizable as String:false]}
    func read() throws -> Data? {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=result as? Data else{throw AppFailure("App-lock Keychain is unavailable (OSStatus \(status)). Check simulator signing or device Keychain access.")};return data
    }
    func save(_ data:Data) throws {
        var status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly;status=SecItemAdd(q as CFDictionary,nil)}
        guard status==errSecSuccess else{throw AppFailure("Cannot save app lock. A device passcode is required.")}
    }
    func remove() throws {let status=SecItemDelete(query as CFDictionary);guard status==errSecSuccess || status==errSecItemNotFound else{throw AppFailure("Cannot reset app lock.")}}
}
actor AppLockStore {
    static let shared=AppLockStore()
    private let storage:AppCodeStorage
    private let eraseLocalSecret:() async throws -> Void
    private var busy=false
    init(storage:AppCodeStorage=KeychainAppCode(),eraseLocalSecret:@escaping () async throws -> Void = {try await WalletVault.shared.eraseLocalSecretAfterLockout();await LockoutErase.clearCompanions()}) {
        self.storage=storage;self.eraseLocalSecret=eraseLocalSecret
    }
    private func record() throws -> AppCodeRecord? {
        guard let bytes=try storage.read() else{return nil}
        let record=try JSONDecoder().decode(AppCodeRecord.self,from:bytes)
        guard record.version==1,Data(hex:record.salt)?.count==32,Data(hex:record.digest)?.count==32,(0...10).contains(record.attempts),record.nextAttempt.timeIntervalSince1970.isFinite,
              !record.erasePending || (record.eraseOnTenFailures && record.attempts==10),
              !record.eraseCompleted || (record.eraseOnTenFailures && record.attempts==10 && !record.erasePending) else {throw AppFailure("App-lock record is damaged. Authenticate with your device to reset only the app code.")}
        return record
    }
    func kind() throws -> AppCodeKind? {try record()?.kind}
    func erasureEnabled() throws -> Bool {try record()?.eraseOnTenFailures ?? false}
    func erasureCompleted() throws -> Bool {try record()?.eraseCompleted ?? false}
    func setErasureEnabled(_ enabled:Bool) throws {
        guard !busy else{throw AppFailure("App lock is busy.")}
        guard var saved=try record(),saved.attempts<10,!saved.erasePending,!saved.eraseCompleted else{throw AppFailure("Set an app code and unlock it before changing this setting.")}
        saved.eraseOnTenFailures=enabled
        try storage.save(JSONEncoder().encode(saved))
    }
    /// Retry a committed erase after a crash. Never infer failure from an
    /// interrupted PIN check; erasePending is set only after a wrong hash.
    func completePendingErasure() async throws {
        guard !busy else{throw AppFailure("App lock is busy.")};busy=true;defer{busy=false}
        guard var saved=try record(),saved.erasePending else{return}
        try await eraseLocalSecret()
        saved.erasePending=false;saved.eraseCompleted=true
        try storage.save(JSONEncoder().encode(saved))
    }
    func configure(_ code:String,kind:AppCodeKind) async throws {
        guard !busy else{throw AppFailure("App lock is busy.")};busy=true;defer{busy=false}
        try kind.validate(code)
        var salt=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,salt.count,&salt)==errSecSuccess else{throw AppFailure("Secure random generation failed.")}
        let encoded=salt.map{String(format:"%02x",$0)}.joined()
        let result=try await NativeCore.shared.call(["op":"app_lock_hash","code":code,"salt":encoded])
        guard let digest=result["digest"] as? String,Data(hex:digest)?.count==32 else{throw AppFailure("Invalid app-lock verifier.")}
        let prior=try record()
        guard prior?.erasePending != true else{throw AppFailure("Finish the pending local-key erase before changing the app code.")}
        let record=AppCodeRecord(version:1,kind:kind,salt:encoded,digest:digest,attempts:0,nextAttempt:.distantPast,eraseOnTenFailures:prior?.eraseCompleted == true ? false : prior?.eraseOnTenFailures ?? false)
        let bytes=try JSONEncoder().encode(record);try storage.save(bytes)
        guard try storage.read()==bytes else{throw AppFailure("App-lock storage verification failed.")}
    }
    func verify(_ code:String,now:Date=Date()) async throws {
        guard !busy else{throw AppFailure("App lock is busy.")};busy=true;defer{busy=false}
        guard var saved=try record() else{return}
        guard !saved.erasePending else{throw AppFailure("Local wallet erase is pending. Restart the app to complete it.")}
        guard saved.attempts<10 else{throw AppFailure(saved.eraseCompleted ? "The local wallet key was erased. Reset the app code with device authentication, then restore your original master key." : "Too many attempts. Use device authentication to reset the app code. Your wallet has not been erased.")}
        guard now>=saved.nextAttempt else{throw AppFailure("Try again in \(max(1,Int(ceil(saved.nextAttempt.timeIntervalSince(now))))) seconds.")}
        // Persist the attempt before checking, so force-quitting cannot reset it.
        saved.attempts+=1
        saved.nextAttempt=saved.attempts>=5 ? now.addingTimeInterval(60*pow(2,Double(saved.attempts-5))) : .distantPast
        try storage.save(JSONEncoder().encode(saved))
        let response=try await NativeCore.shared.call(["op":"app_lock_check","code":code,"salt":saved.salt,"digest":saved.digest])
        guard response["matches"] as? Bool==true else {
            if saved.attempts==10 && saved.eraseOnTenFailures {
                saved.erasePending=true;try storage.save(JSONEncoder().encode(saved))
                try await eraseLocalSecret()
                saved.erasePending=false;saved.eraseCompleted=true;try storage.save(JSONEncoder().encode(saved))
                throw AppFailure("Ten wrong app-code entries erased the local wallet key. Restore only with your original master key.")
            }
            throw AppFailure("Incorrect \(saved.kind == .password ? "password" : "PIN").")
        }
        saved.attempts=0;saved.nextAttempt = .distantPast;try storage.save(JSONEncoder().encode(saved))
    }
    // Only called after WalletState completes fresh device authentication.
    func resetAfterDeviceAuthentication() throws {guard !busy else{throw AppFailure("App lock is busy.")};try storage.remove()}
}

/// After 10 wrong app codes the wallet is erased; anything else that acts for the owner goes with it,
/// so whoever holds the phone can't set up a new wallet and control the owner's computers.
/// The computers keep mining; the owner pairs them again.
@MainActor enum LockoutErase {
    static func clearCompanions() {
        for rig in RigStore.shared.rigs { RigStore.shared.remove(rig.id) }
        PhoneWidgetData.saveMining(nil)
        let voice = SiriVoiceStore.shared
        voice.miningStatus = false; voice.miningControl = "off"; voice.faceIDOff = false
        voice.chatRead = false; voice.chatSend = false; voice.roomRead = false
        }
}

import SwiftUI
import LocalAuthentication

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
@MainActor final class WalletState: ObservableObject {
    @Published var address = ""
    @Published var localWallet: WalletSummary?
    @Published var accounts: [WalletAccount] = []
    @Published var selectedIndex: UInt32 = 0
    @Published var recoveryRequired = false
    @Published var hideBalances = UserDefaults.standard.bool(forKey: "hideBalances") {
        didSet { UserDefaults.standard.set(hideBalances, forKey: "hideBalances"); PhoneWidgetData.setHidden(hideBalances) }
    }
    @Published var offlineMode = UserDefaults.standard.bool(forKey: "offlineMode") {
        didSet { UserDefaults.standard.set(offlineMode, forKey: "offlineMode") }
    }
    @Published var autoLockSeconds: Int = {
        guard let saved = UserDefaults.standard.object(forKey: "autoLockSeconds") as? Int else { return 60 }
        return [0, 30, 60, 300, 900].contains(saved) ? saved : 60
    }() {
        didSet { UserDefaults.standard.set(autoLockSeconds, forKey: "autoLockSeconds") }
    }
    @Published var authenticating = false
    @Published var appCodeKind:AppCodeKind?
    @Published var appCodeLoaded=false
    @Published private(set) var eraseOnTenFailures=false
    @Published private(set) var biometricEnabled=UserDefaults.standard.bool(forKey:"biometricUnlock")
    var biometricsAvailable:Bool {LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,error:nil)}
    var biometricName:String {
        let context=LAContext();_ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,error:nil)
        return context.biometryType == .faceID ? "Face ID" : context.biometryType == .touchID ? "Touch ID" : "Biometrics"
    }
    func setBiometricUnlock(_ enabled:Bool) async {
        do {
            guard !locked else{throw AppFailure("Unlock before changing biometric settings.")}
            let token=generation
            _=try await requireAuthentication(enabled ? "Enable biometric wallet unlock" : "Disable biometric wallet unlock",biometricsOnly:enabled,fresh:true)
            guard token==generation,!locked else{return}
            try BiometricUnlock.configure(enabled:enabled)
            biometricEnabled=enabled;UserDefaults.standard.set(enabled,forKey:"biometricUnlock");notice=nil
        }catch{notice=error.localizedDescription}
    }
    private var unlocking=false
    func loadAppCode() async {
        do {
            try await AppLockStore.shared.completePendingErasure()
            appCodeKind=try await AppLockStore.shared.kind()
            eraseOnTenFailures=try await AppLockStore.shared.erasureEnabled()
            if try await AppLockStore.shared.erasureCompleted() {notice="The local wallet key was erased after ten wrong app-code entries. Reset the app code with device authentication, then restore your original master key."}
            appCodeLoaded=true
        }
        catch {notice=error.localizedDescription;appCodeLoaded=true}
    }
    func setAppCode(_ code:String,kind:AppCodeKind) async throws {
        let token=generation
        try kind.validate(code)
        let existingPIN=try await WalletVault.shared.hasPINAccess()
        // First-time setup follows wallet creation and backup verification in
        // the same unlocked session. Reuse that authenticated Keychain context
        // instead of forcing another iPhone passcode prompt after PIN entry.
        // The protected wallet read below still enforces user presence.
        let context: LAContext
        if existingPIN {
            context = try await requireAuthentication("Change your Parano1d app code",fresh:true)
        } else if let authenticatedContext {
            context = authenticatedContext
        } else {
            context = try await requireAuthentication("Protect your wallet with an app code",deviceOnly:true)
        }
        guard token==generation,!locked else{throw AppFailure("Wallet locked before the change.")}
        try await WalletVault.shared.enablePINAccess(code:code,context:context)
        guard token==generation,!locked else{throw AppFailure("Wallet locked before the change.")}
        try await AppLockStore.shared.configure(code,kind:kind)
        let committed = LAContext()
        defer { committed.setCredential(nil,type:.applicationPassword); committed.invalidate() }
        guard committed.setCredential(Data(code.utf8),type:.applicationPassword) else { throw AppFailure("App code saved. Unlock once to finish the protection update.") }
        try await WalletVault.shared.finishPINAccess(context:committed)
        authenticatedContext?.setCredential(nil,type:.applicationPassword);authenticatedContext?.invalidate();authenticatedContext=nil;authenticatedAt = .distantPast
        guard token==generation else{return};appCodeKind=kind;eraseOnTenFailures=try await AppLockStore.shared.erasureEnabled()
    }
    func setErasureOnTenFailures(_ enabled:Bool) async {
        do {
            guard !locked,localWallet?.recoveryVerified==true,appCodeKind != nil else{throw AppFailure("Verify your recovery backup and set an app code first.")}
            let token=generation
            _=try await requireAuthentication(enabled ? "Enable local-key erase after ten wrong app-code entries" : "Disable local-key erase",fresh:true)
            guard token==generation,!locked else{return}
            try await AppLockStore.shared.setErasureEnabled(enabled)
            eraseOnTenFailures=enabled;notice=nil
        }catch{notice=error.localizedDescription}
    }
    func resetAppCode() async {
        do {
            let token=generation
            let context=try await requireAuthentication("Reset only your Parano1d app code; your wallet is not erased",fresh:true,deviceOnly:true)
            guard token==generation else{return}
            try await WalletVault.shared.revokePINAccess(context:context)
            try await AppLockStore.shared.resetAfterDeviceAuthentication()
            authenticatedContext?.setCredential(nil,type:.applicationPassword);authenticatedContext?.invalidate();authenticatedContext=nil;authenticatedAt = .distantPast
            guard token==generation else{return};appCodeKind=nil;eraseOnTenFailures=false;notice=nil
        }catch{notice=error.localizedDescription}
    }
    private var lastActivity = ContinuousClock().now
    // A newly revealed backup needs time to copy. This allowance exists only
    // while the recovery key is visible in the foreground; it is never saved.
    private var recoveryKeyVisible = false
    private var generation: UInt64 = 0
    private var authenticatedContext: LAContext?
    private var authenticatedAt = Date.distantPast
    // Passive inbox polling must never renew inactivity or show authentication UI.
    // The wallet's own lock boundary controls the session; an arbitrary 90-second
    // cutoff made new messages invisible until a manual refresh.
    var canRefreshMessages: Bool {
        !locked && !authenticating && authenticatedContext != nil
    }
    func messagingRefreshContext() throws -> LAContext {
        guard canRefreshMessages, let context = authenticatedContext else {
            throw AppFailure("Tap Refresh inbox to authenticate and resume private updates.")
        }
        return context
    }
    /// An explicit chat action may reuse the wallet's unlocked session. The
    /// context is invalidated by lock/background; passive polling stays bounded.
    func messagingSessionContext() throws -> LAContext {
        guard !locked, !authenticating, let context = authenticatedContext else {
            throw AppFailure("Unlock the wallet to use private chat.")
        }
        touch()
        return context
    }
    func touch(now:ContinuousClock.Instant = ContinuousClock().now) { lastActivity = now }
    func setRecoveryKeyVisible(_ visible: Bool) {
        recoveryKeyVisible = visible && !locked
        if recoveryKeyVisible { touch() }
    }
    func tick(now:ContinuousClock.Instant = ContinuousClock().now) {
        guard !locked, !authenticating else { return }
        if autoLockSeconds != 0 {
            let limit = recoveryKeyVisible ? max(autoLockSeconds, 1200) : autoLockSeconds
            if lastActivity.duration(to:now) >= .seconds(Int64(limit)) { lock(); return }
        }
    }
    func amount(_ text: String) -> String { hideBalances ? "••••••" : text }
    private var activeAuthenticationContext: LAContext?
    func cancelAuthentication() {
        if authenticating || unlocking { generation &+= 1 }
        AuthenticationChoice.cancel()
        activeAuthenticationContext?.setCredential(nil,type:.applicationPassword)
        activeAuthenticationContext?.invalidate()
        activeAuthenticationContext = nil
    }
    func requireAuthentication(_ reason: String,biometricsOnly:Bool=false,fresh:Bool=false,deviceOnly:Bool=false) async throws -> LAContext {
        guard !authenticating else { throw AppFailure("Authentication is already in progress.") }
        if !fresh && !biometricsOnly && !deviceOnly && !locked,
           let authenticatedContext, Date().timeIntervalSince(authenticatedAt) >= 0,
           Date().timeIntervalSince(authenticatedAt) < 90 {
            touch(); return authenticatedContext
        }
        let token = generation
        authenticating = true
        defer { authenticating = false; activeAuthenticationContext = nil }
        let context = LAContext()
        activeAuthenticationContext = context
        do {
            if !biometricsOnly && !deviceOnly, let kind = try await AppLockStore.shared.kind() {
                guard try await WalletVault.shared.hasPINAccess() else {
                    throw AppFailure("App PIN wallet access is not installed. Lock and unlock with your app PIN to complete the one-time upgrade, or choose device authentication explicitly for recovery.")
                }
                let choice = try await AuthenticationChoice.request(reason:reason,kind:kind,biometricName:biometricEnabled ? biometricName : nil)
                guard token == generation else { throw AppFailure("Authentication cancelled.") }
                switch choice {
                case .code(let code):
                    try await AppLockStore.shared.verify(code)
                    guard token == generation, context.setCredential(Data(code.utf8),type:.applicationPassword) else { throw AppFailure("App-code authentication cancelled.") }
                    // Keychain validates this credential when the protected wallet is read.
                case .biometric:
                    context.localizedFallbackTitle = ""
                    guard biometricEnabled, try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,localizedReason:reason) else { throw AppFailure("Authentication cancelled.") }
                    try BiometricUnlock.verify(context:context)
                case .device:
                    guard try await context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:reason) else { throw AppFailure("Authentication cancelled.") }
                }
            } else {
                if biometricsOnly { context.localizedFallbackTitle = "" }
                guard try await context.evaluatePolicy(biometricsOnly ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication,localizedReason:reason) else { throw AppFailure("Authentication cancelled.") }
            }
            guard token == generation else { throw AppFailure("Authentication cancelled.") }
            if !fresh && !biometricsOnly && !locked { authenticatedContext = context; authenticatedAt = Date() }
            touch(); return context
        } catch {
            context.setCredential(nil,type:.applicationPassword); context.invalidate()
            if (try? await AppLockStore.shared.erasureCompleted()) == true { lock() }
            throw error
        }
    }
    // Backup verification is part of the same unlocked setup that created the
    // wallet. Writing down the key can exceed the normal 90-second reuse window;
    // let the protected Keychain read validate the original session instead of
    // deliberately starting another iPhone passcode prompt.
    func backupVerificationContext() async throws -> LAContext {
        guard !locked,localWallet != nil else { throw AppFailure("Unlock your wallet before verifying its backup.") }
        if let authenticatedContext { touch(); return authenticatedContext }
        return try await requireAuthentication("Verify your wallet backup",deviceOnly:true)
    }
    func apply(_ summary: WalletSummary) {
        recoveryRequired = false; localWallet = summary; address = summary.address; accounts = summary.accounts; selectedIndex = summary.selectedIndex; touch()
    }
    func clearLocalWallet() {
        localWallet = nil; recoveryRequired = false; accounts = []; selectedIndex = 0
        address = UserDefaults.standard.string(forKey: "watchAddress") ?? ""
    }
    func resetMissingIdentity() async {
        do {
            guard !locked, recoveryRequired, localWallet == nil else { throw AppFailure("Only a missing local wallet can be reset here.") }
            let token = generation
            let context = try await requireAuthentication("Reset a missing wallet identity on this device", fresh: true)
            guard token == generation, !locked else { return }
            try await WalletVault.shared.forgetMissingIdentity(context: context)
            guard token == generation, !locked else { return }
            clearLocalWallet()
            notice = "Device record cleared. Your former wallet remains recoverable only with its own master key."
        } catch { notice = error.localizedDescription }
    }
    @Published var locked = true
    @Published var notice: String?
    init() { address = UserDefaults.standard.string(forKey: "watchAddress") ?? ""; PhoneWidgetData.setHidden(hideBalances) }
    func saveAddress(_ candidate: String) throws {
        guard !locked, localWallet == nil, !recoveryRequired else { throw AppFailure("A local wallet is active. Its address cannot be overwritten by a watch address.") }
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AddressValidator.valid(clean) else { throw AppFailure("Enter a valid Parano1d address, including its checksum.") }
        address = clean
        UserDefaults.standard.set(clean, forKey: "watchAddress")
    }
    func unlock(code:String?=nil,usingBiometrics:Bool=false,usingDevice:Bool=false) async {
        guard !unlocking else{return};unlocking=true;defer{unlocking=false}
        do {
            try await AppLockStore.shared.completePendingErasure()
            let start=generation
            let configured=try await AppLockStore.shared.kind()
            let context:LAContext
            if usingBiometrics {
                guard biometricEnabled else{throw AppFailure("Enable biometric unlock in Settings first.")}
                context=try await requireAuthentication("Unlock Parano1d Wallet",biometricsOnly:true)
                try BiometricUnlock.verify(context:context)
            } else if usingDevice {
                context=try await requireAuthentication("Unlock Parano1d Wallet",fresh:true,deviceOnly:true)
            } else if configured != nil {
                guard let code else { throw AppFailure("Enter your app PIN or password first.") }
                try await AppLockStore.shared.verify(code)
                guard start == generation else { return }
                let recorded = await WalletVault.shared.hasRecordedIdentity
                let pinAccess = try await WalletVault.shared.hasPINAccess()
                if recorded && !pinAccess {
                    notice = "One-time upgrade: authenticate with your device to let your app code unlock the protected wallet directly."
                    let device = try await requireAuthentication("Enable app-code OR biometric wallet access (one-time upgrade)",fresh:true,deviceOnly:true)
                    guard start == generation else { return }
                    try await WalletVault.shared.enablePINAccess(code:code,context:device)
                    guard try await WalletVault.shared.hasPINAccess() else {
                        throw AppFailure("PIN-only wallet access could not be installed. Your existing wallet remains protected; use device authentication and try the upgrade again.")
                    }
                }
                context=LAContext()
                guard start == generation, context.setCredential(Data(code.utf8),type:.applicationPassword) else { throw AppFailure("App-code authentication cancelled.") }
            } else {
                let recordedIdentity = await WalletVault.shared.hasRecordedIdentity
                guard start == generation else { return }
                if !recordedIdentity { context=LAContext() }
                else { context=try await requireAuthentication("Open your wallet",deviceOnly:true) }
            }
            guard start==generation else{return}
            let token = generation
            if NativeCore.available {
                let summary = try await WalletVault.shared.summary(context: context)
                if context.isCredentialSet(.applicationPassword) { try await WalletVault.shared.finishPINAccess(context:context) }
                guard token == generation else { return }
                localWallet = summary
                let recorded = await WalletVault.shared.hasRecordedIdentity
                guard token == generation else { return }
                recoveryRequired = summary == nil && recorded
                if recoveryRequired { address = ""; accounts = []; selectedIndex = 0 }
                if let summary { address = summary.address; accounts = summary.accounts; selectedIndex = summary.selectedIndex }
                else if !recoveryRequired { address = UserDefaults.standard.string(forKey: "watchAddress") ?? ""; accounts = []; selectedIndex = 0 }
            }
            guard token == generation else { return }
            locked = false; notice = nil
            let hasIdentity = await WalletVault.shared.hasRecordedIdentity
            guard token == generation, !locked else { context.invalidate(); return }
            if configured != nil || usingBiometrics || usingDevice || hasIdentity {
                authenticatedContext = context; authenticatedAt = Date()
            }
            touch()
        } catch { notice = error.localizedDescription }
    }
    func lock() {
        recoveryKeyVisible = false
        generation &+= 1
        cancelAuthentication()
        authenticatedContext?.setCredential(nil,type:.applicationPassword)
        authenticatedContext?.invalidate(); authenticatedContext = nil; authenticatedAt = .distantPast
        locked = true; localWallet = nil; accounts = []
    }
}
// Bech32m address validation matches upstream's Bech32m encoding, with 32-byte payload.
enum AddressValidator {
    static func valid(_ s: String) -> Bool {
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        guard s == s.lowercased(), s.count == 60, s.hasPrefix("o1") else { return false }
        let values = s.dropFirst(2).compactMap { alphabet.firstIndex(of: $0).map(UInt32.init) }
        guard values.count == 58 else { return false }
        var chk: UInt32 = 1
        for v in [UInt32(3), 0, 15] + values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ v
            for (i,g) in [UInt32(0x3b6a57b2),0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].enumerated() where ((top >> i) & 1) != 0 { chk ^= g }
        }
        return chk == 0x2bc830a3 && (values[51] & 15) == 0
    }
}

/// One-time "Unlock with Face ID?" offer after a wallet's first app code is set.
enum BiometricOffer {
    private static let key="biometricOfferPending.v1"
    static var pending:Bool {
        get {UserDefaults.standard.bool(forKey:key)}
        set {if newValue {UserDefaults.standard.set(true,forKey:key)} else {UserDefaults.standard.removeObject(forKey:key)}}
    }
}

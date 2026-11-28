import UIKit
import LocalAuthentication
import CryptoKit

/// Instant private-message alerts through the Parano1d World push service
/// (parano1dworld.com/push, run by KoAjent on Cloudflare).
///
/// - This phone registers its Apple push token, signed by its chat identity.
/// - After you send a private message, your app asks the service to alert the
///   recipient's identity, signed by your chat identity.
/// - The alert says only "New private message". Message text never leaves your
///   device unencrypted, and the service never sees it. The service does see which
///   chat identities message each other, and when (the chat relay sees the same).
@MainActor enum InstantAlerts {
    static let enabledKey = "notifyInstantMessages"
    private static let origin = "https://parano1dworld.com"
    private static let tokenKey = "push.deviceToken.v1"
    private static let registeredKey = "push.registration.v1"
    private static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    /// Off by default. Needs both this setting and private-message alerts.
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
            && UserDefaults.standard.bool(forKey: WalletActivityNotifications.messageKey) && blockedByConnection == false
    }
    private static var app: String { Bundle.main.bundleIdentifier == "com.koajent.parano1d.wallet" ? "wallet" : "testflight" }
    private static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
    /// Asks iOS for this device's push token when alerts are wanted.
    static func refreshToken() {
        if enabled { UIApplication.shared.registerForRemoteNotifications() }
    }
    /// Turning alerts off: iOS invalidates the token, so the service drops it on the next alert.
    static func turnOff() {
        UIApplication.shared.unregisterForRemoteNotifications()
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: registeredKey)
    }
    static func received(token: Data) {
        UserDefaults.standard.set(token.map { String(format: "%02x", $0) }.joined(), forKey: tokenKey)
    }

    /// Registers (or re-registers weekly) using a context the wallet already unlocked for chat.
    static func registerIfNeeded(context: LAContext) async {
        guard enabled, let token = UserDefaults.standard.string(forKey: tokenKey), (64...200).contains(token.count) else { return }
        let tokenHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let saved = UserDefaults.standard.dictionary(forKey: registeredKey), saved["token"] as? String == tokenHash,
           saved["app"] as? String == app, let at = saved["at"] as? Double, Date().timeIntervalSince1970 - at < 7 * 86400 { return }
        guard let auth = try? await WalletVault.shared.message(["op": "chat_push_auth", "purpose": "register", "target": tokenHash,
                                                                 "now_ms": UInt64(Date().timeIntervalSince1970 * 1000)], context: context),
              let id = auth["id"] as? String, let time = auth["time_ms"] as? String, let signature = auth["signature"] as? String else { return }
        let body: [String: Any] = ["id": id, "token": token, "app": app, "env": apnsEnvironment, "time_ms": time, "signature": signature]
        let app = self.app
        Task.detached {
            guard await post("/push/v1/register", body) else { return }
            await MainActor.run { UserDefaults.standard.set(["token": tokenHash, "app": app, "at": Date().timeIntervalSince1970], forKey: registeredKey) }
        }
    }

    /// After a private message is delivered: alert the recipient's device, if they registered one.
    static func ping(recipient: String, context: LAContext) async {
        guard UserDefaults.standard.bool(forKey: enabledKey), blockedByConnection == false,
              recipient.count == 64, !PrivateChatBlocks.contains(recipient),
              let auth = try? await WalletVault.shared.message(["op": "chat_push_auth", "purpose": "ping", "target": recipient,
                                                                 "now_ms": UInt64(Date().timeIntervalSince1970 * 1000)], context: context),
              let id = auth["id"] as? String, let time = auth["time_ms"] as? String, let signature = auth["signature"] as? String else { return }
        let body: [String: Any] = ["sender": id, "recipient": recipient, "time_ms": time, "signature": signature]
        Task.detached { _ = await post("/push/v1/ping", body) }
    }

    private nonisolated static func post(_ path: String, _ body: [String: Any]) async -> Bool {
        guard let url = URL(string: origin + path), let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    /// Offline mode never contacts the service.
    private static var blockedByConnection: Bool {
        UserDefaults.standard.bool(forKey: "offlineMode")
    }
}

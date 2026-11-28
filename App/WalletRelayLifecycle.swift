import UIKit
import UserNotifications

/// Relay startup does not access WalletVault or decrypt a message. The only
/// persistent enrollment data is a boolean plus the user's relay preference.
@MainActor final class WalletRelayLifecycle:NSObject,UIApplicationDelegate,@preconcurrency UNUserNotificationCenterDelegate {
    static let transport=NearbyTransport()
    static var pendingChatContactID:String?
    static let notificationOpened=Notification.Name("Parano1dNotificationOpened")
    private static let relayIdentity=(UUID().uuidString+UUID().uuidString).replacingOccurrences(of:"-",with:"").lowercased()
    static func enrollWallet() {
        UserDefaults.standard.set(true,forKey:"meshRelayEnrolled")
        configure()
    }
    static func configure() {
        let enabled=(UserDefaults.standard.object(forKey:"meshRelayEnabled") as? Bool) ?? Edition.nearbyRelayDefault
        guard enabled,UserDefaults.standard.bool(forKey:"meshRelayEnrolled"),NativeCore.available else {
            if transport.enabled {transport.stop()}
            return
        }
        transport.start(identity:relayIdentity,carryOthers:true)
    }
    func application(_ application:UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool {
        Edition.registerDefaults()
        UNUserNotificationCenter.current().delegate=self
        // Recreate both managers with their stable restoration identifiers even
        // when Core Bluetooth launches us without a visible SwiftUI window.
        Self.configure()
        InstantAlerts.refreshToken()
        return true
    }
    func application(_ application:UIApplication,didRegisterForRemoteNotificationsWithDeviceToken deviceToken:Data) {
        InstantAlerts.received(token:deviceToken)
    }
    func applicationDidBecomeActive(_ application:UIApplication) {Self.configure()}
    func applicationProtectedDataDidBecomeAvailable(_ application:UIApplication) {
        Self.configure();Self.transport.reloadStoredPackets()
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) {
        completionHandler(UserDefaults.standard.object(forKey:"notifyWhileAppOpen") as? Bool == false ? [] : [.banner,.list,.sound])
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping ()->Void) {
        let info=response.notification.request.content.userInfo
        Task {@MainActor in
            if info["route"] as? String == "mining" {
                NotificationCenter.default.post(name:MiningAlerts.opened,object:nil)
            }
            if info["route"] as? String == "watch_pay" {
                NotificationCenter.default.post(name:WatchBridge.handoffOpened,object:nil)
            }
            if info["route"] as? String == "chat",let id=info["contactID"] as? String,id.count==64 {
                Self.pendingChatContactID=id
                NotificationCenter.default.post(name:Self.notificationOpened,object:nil)
            }
            completionHandler()
        }
    }
}

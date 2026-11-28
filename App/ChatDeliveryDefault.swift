import Foundation

/// Online delivery is turned on when chat is first set up, so a new user's first message
/// actually sends. A choice the user already made (on or off) is never overwritten, and
/// Parano1d mode (no servers) is left alone. Turn it off in Settings → Chat.
enum ChatDeliveryDefault {
    static let key = "chatOnlineDeliveryEnabled"
    static let setupNote = "Messages are delivered encrypted through chat.parano1d.org, which can't read them but sees which chat identities talk and when. You can switch to nearby-only in Settings → Chat."
    static func applyOnFirstSetup(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil, !NodeEndpoints.paranoid else { return }
        defaults.set(true, forKey: key)
    }
}

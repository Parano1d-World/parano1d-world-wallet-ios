import Foundation

#if DEBUG
/// Simulator-only sample content for App Store screenshots. Compiled out of every release
/// build (DEBUG only) and active only when the app is launched with -storeShots.
enum StoreShots {
    static let on = ProcessInfo.processInfo.arguments.contains("-storeShots")
    private static func hex(_ seed: String) -> String {
        var out = ""; var value: UInt64 = seed.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }
        while out.count < 64 { value = value &* 6364136223846793005 &+ 1442695040888963407; out += String(format: "%016llx", value) }
        return String(out.prefix(64))
    }
    static let ownID = hex("me")
    /// Payout address for the sample rigs, passed at launch (-storePayout <address>); shown shortened.
    static let payout: String = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-storePayout"), args.indices.contains(index + 1) else { return "" }
        return args[index + 1]
    }()
    static let contacts: [ConnectedContact] = [("Maya", 0.2), ("Jordan", 3.5), ("Alex", 26.0)].map { name, _ in
        ConnectedContact(id: hex(name), name: name, address: "o1" + String(hex(name + "a").prefix(58)), boxKey: hex(name + "k"), invitation: "", approvedAt: Date().addingTimeInterval(-86_400 * 20))
    }
    static let packets: [MessageArchive.Packet] = [("Maya", 0.2), ("Jordan", 3.5), ("Alex", 26.0)].map { name, hours in
        MessageArchive.Packet(id: hex(name + "m"), contactID: hex(name), received: true, date: Date().addingTimeInterval(-hours * 3600), envelope: Data())
    }
    static let unread: [String: Int] = [hex("Maya"): 2]
    static let publicPosts: [(name: String, text: String, minutes: Double)] = [
        ("Nova", "Just verified my balance on my own phone. No middleman. Love it.", 4),
        ("Kai", "Second rig is online tonight. Watching it from the Mining tab.", 11),
        ("Rin", "Welcome to everyone new here! Ask anything about NOID.", 23),
        ("Leo", "Parano1d mode is my default now. Clean and private.", 38),
        ("Sam", "New PARANOIDS art looks great in the gallery view.", 52)
    ]
    static func postID(_ index: Int) -> String { hex("post\(index)") }
    static func senderID(_ name: String) -> String { hex("sender" + name) }
    static let receipts: [(id: String, hours: Double, height: UInt64)] = [
        (hex("r1"), 2, 342_598), (hex("r2"), 27, 342_101), (hex("r3"), 75, 341_210), (hex("r4"), 170, 339_877)
    ]
    static let mining: [(label: String, mode: String, hashrate: String, accepted: Int, hours: Double)] = [
        ("Office PC", "cpu", "18.4 kH/s", 1_284, 26), ("Garage rig", "gpu", "1.2 MH/s", 9_731, 71)
    ]
}
#endif

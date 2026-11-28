import Foundation

#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
/// App Store edition: no extra watch requests (no public room).
@MainActor enum WatchBridgeEdition {
    static let community = false
    static func handle(_ type: String, _ request: [String: Any], bridge: WatchBridge) async throws -> [String: Any]? { nil }
}
#endif

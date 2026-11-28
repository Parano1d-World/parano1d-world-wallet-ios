import Foundation
import SwiftUI
import Security

private struct ModerationConfiguration: Decodable {
    let enabled: Bool
    let feedURL: String
    let publicKeyBase64: String
    static func bundled() throws -> (URL, Data)? {
        guard let file = Bundle.main.url(forResource: "ModerationConfiguration", withExtension: "json") else { return nil }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard config.enabled else { return nil }
        // Any owner-controlled https host works: decisions are trusted only if they
        // carry a valid signature from the public key bundled below.
        guard config.feedURL.count <= 300, let url = URL(string: config.feedURL), url.scheme == "https",
              let host = url.host, !host.isEmpty, !host.hasSuffix(".local"), host != "localhost", host.contains("."),
              url.path.hasSuffix(".json"), url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let key = Data(base64Encoded: config.publicKeyBase64), key.count == 32 else {
            throw ModerationFailure("Moderation configuration needs attention.")
        }
        return (url, key)
    }
}

/// High-water marker survives cached-file loss. Never silently reset an unreadable marker.
private enum ModerationMarker {
    struct Value: Codable { let sequence: UInt64; let digest: String }
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.koajent.parano1d.moderation.sequence.v1", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    static func read(_ account: String) throws -> Value {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return Value(sequence: 0, digest: "") }
        guard status == errSecSuccess, let data = result as? Data else { throw ModerationFailure("Could not read moderation sequence marker.") }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    static func save(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let q = query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ModerationFailure("Could not save moderation sequence marker.") }
        } else if status != errSecSuccess { throw ModerationFailure("Could not update moderation sequence marker.") }
    }
}

@MainActor final class PublicModerationStore: ObservableObject {
    static let shared = PublicModerationStore()
    @Published private(set) var decisions: [ModerationDecision] = []
    @Published private(set) var status = "Moderator updates are not configured. Local filtering and reporting remain available."
    @Published private(set) var loading = false
    private var configured: (URL, Data)?
    @Published private(set) var host = ""
    private var loaded = false
    private var lastAttempt: TimeInterval = -.infinity
    private var validUntil: Int64 = 0
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }()
    private var now: Int64 { Int64(Date().timeIntervalSince1970) }
    func restriction(messageID: String? = nil, identity: String) -> ModerationDecision? {
        decisions.first { $0.expiresAt > now && (($0.kind == "identity" && $0.target == identity) || ($0.kind == "message" && $0.target == messageID)) }
    }
    private func cacheURL(key: Data) throws -> URL {
        var folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PublicModeration", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        return folder.appendingPathComponent(ModerationProtocol.hash(key) + ".json")
    }
    func refresh(online: Bool, force: Bool = false) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            if !loaded {
                configured = try ModerationConfiguration.bundled()
                if let (configuredURL, _) = configured { host = configuredURL.host ?? "" }
                if let (_, key) = configured {
                    let file = try cacheURL(key: key)
                    let marker = try ModerationMarker.read(ModerationProtocol.hash(key))
                    do {
                    if FileManager.default.fileExists(atPath: file.path) {
                        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= ModerationProtocol.maxBytes else { throw ModerationFailure("Moderation cache is too large.") }
                        let verified = try ModerationProtocol.verify(Data(contentsOf: file), publicKey: key, now: now, allowExpiredSnapshot: true)
                        try ModerationProtocol.accept(verified, sequence: marker.sequence, digest: marker.digest)
                        try ModerationMarker.save(.init(sequence: verified.payload.sequence, digest: verified.digest), account: ModerationProtocol.hash(key))
                        decisions = verified.payload.decisions; validUntil = verified.payload.validUntil
                    }
                    } catch { status = "Cached moderator decisions could not be loaded. Fetching a verified replacement when online." }
                }
                loaded = true
            }
            guard let (url, key) = configured else { return }
            guard online else { status = "Offline. Cached moderator decisions apply until their expiration."; return }
            let uptime = ProcessInfo.processInfo.systemUptime
            guard force || uptime - lastAttempt >= 300 else {
                if validUntil > 0 && now >= validUntil { status = "Moderator updates are stale. Cached decisions apply until their expiration." }
                return
            }
            lastAttempt = uptime
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // No address, account, invitation, identity, cookie, or authorization is sent.
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url == url else { throw ModerationFailure("Moderator updates unavailable.") }
            var bytes = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard bytes.count < ModerationProtocol.maxBytes else { throw ModerationFailure("Moderator response exceeds size limit.") }
                bytes.append(byte)
            }
            let verified = try ModerationProtocol.verify(bytes, publicKey: key, now: now)
            let account = ModerationProtocol.hash(key)
            let marker = try ModerationMarker.read(account)
            try ModerationProtocol.accept(verified, sequence: marker.sequence, digest: marker.digest)
            try Task.checkCancellation()
            // Persist full signed snapshot before marker. On interruption, signature/sequence validation repairs forward, never backward.
            try bytes.write(to: cacheURL(key: key), options: [.atomic, .completeFileProtection])
            try ModerationMarker.save(.init(sequence: verified.payload.sequence, digest: verified.digest), account: account)
            decisions = verified.payload.decisions; validUntil = verified.payload.validUntil
            status = "Moderator updates verified. Decisions affect this app’s public chat only."
        } catch is CancellationError { }
        catch { status = "Moderator updates unavailable or rejected. Cached decisions retain their expiration. " + error.localizedDescription }
    }
}

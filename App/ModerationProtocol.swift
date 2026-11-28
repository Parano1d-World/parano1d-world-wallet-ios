import Foundation
import CryptoKit

struct ModerationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct ModerationDecision: Codable, Equatable, Identifiable {
    let id: String
    let kind: String // message or identity
    let target: String // exact verified public message ID or signing identity
    let reason: String // fixed public reason code, never reporter details
    let expiresAt: Int64
}
struct ModerationPayload: Codable {
    let version: Int
    let scope: String
    let sequence: UInt64
    let issuedAt: Int64
    let validUntil: Int64
    let decisions: [ModerationDecision]
}
struct ModerationEnvelope: Codable {
    let payload: String // signed exact UTF-8 JSON bytes, base64; no re-canonicalization
    let signature: String
}
struct VerifiedModeration {
    let payload: ModerationPayload
    let digest: String
}
enum ModerationProtocol {
    static let scope = "com.koajent.parano1d.mainnet.public-room.v1"
    static let maxBytes = 512_000
    static let reasons = ["harassment", "threats", "hateful-content", "sexual-content", "scam", "spam", "privacy"]
    static func reasonLabel(_ code: String) -> String {
        switch code {
        case "harassment": return "Harassment"
        case "threats": return "Threats"
        case "hateful-content": return "Hateful content"
        case "sexual-content": return "Sexually explicit content"
        case "scam": return "Scam or impersonation"
        case "spam": return "Spam"
        case "privacy": return "Exposure of private information"
        default: return "Community rules"
        }
    }
    static func isIdentifier(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ p: ModerationPayload) throws {
        guard p.version == 1, p.scope == scope, p.sequence > 0, p.issuedAt > 0,
              p.validUntil > p.issuedAt, p.validUntil - p.issuedAt <= 7 * 86400,
              p.decisions.count <= 1000 else { throw ModerationFailure("Invalid moderation snapshot.") }
        var ids = Set<String>(), targets = Set<String>()
        for d in p.decisions {
            guard UUID(uuidString: d.id) != nil, ids.insert(d.id).inserted,
                  ["message", "identity"].contains(d.kind), isIdentifier(d.target), reasons.contains(d.reason),
                  d.expiresAt > p.issuedAt, d.expiresAt - p.issuedAt <= 30 * 86400,
                  targets.insert(d.kind + ":" + d.target).inserted else {
                throw ModerationFailure("Invalid or duplicate moderation decision.")
            }
        }
    }
    static func verify(_ bytes: Data, publicKey: Data, now: Int64, allowExpiredSnapshot: Bool = false) throws -> VerifiedModeration {
        guard bytes.count <= maxBytes, publicKey.count == 32 else { throw ModerationFailure("Invalid moderation data size or key.") }
        let envelope = try JSONDecoder().decode(ModerationEnvelope.self, from: bytes)
        guard let payloadBytes = Data(base64Encoded: envelope.payload), payloadBytes.count <= 350_000,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64 else { throw ModerationFailure("Invalid moderation envelope.") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: payloadBytes) else { throw ModerationFailure("Moderation signature rejected.") }
        let p = try JSONDecoder().decode(ModerationPayload.self, from: payloadBytes)
        try validate(p)
        guard p.issuedAt <= now + 300, allowExpiredSnapshot || now < p.validUntil else { throw ModerationFailure("Moderation snapshot is expired or from the future.") }
        return VerifiedModeration(payload: p, digest: hash(payloadBytes))
    }
    static func accept(_ candidate: VerifiedModeration, sequence: UInt64, digest: String) throws {
        guard candidate.payload.sequence >= sequence else { throw ModerationFailure("Older moderation snapshot rejected.") }
        if candidate.payload.sequence == sequence && candidate.digest != digest { throw ModerationFailure("Conflicting moderation snapshot rejected.") }
    }
    static func sign(_ payload: ModerationPayload, key: Curve25519.Signing.PrivateKey) throws -> Data {
        try validate(payload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(payload)
        let envelope = ModerationEnvelope(payload: bytes.base64EncodedString(), signature: try key.signature(for: bytes).base64EncodedString())
        let result = try encoder.encode(envelope)
        guard bytes.count <= 350_000, result.count <= maxBytes else { throw ModerationFailure("Moderation snapshot exceeds size limit.") }
        return result
    }
}

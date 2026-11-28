import XCTest
import CryptoKit
@testable import Paranoid

final class MiningTests: XCTestCase {
    func testPairingCodeFormats() {
        XCTAssertEqual(RigPairCode.parse("https://parano1dworld.com/#Mining/pair/AB12-CD34-EF56"), "AB12CD34EF56")
        XCTAssertEqual(RigPairCode.parse("https://parano1dworld.com/mining/pair/ab12cd34ef56"), "AB12CD34EF56")
        XCTAssertEqual(RigPairCode.parse("paramo1d://mining/pair/AB12-CD34-EF56"), "AB12CD34EF56")
        XCTAssertEqual(RigPairCode.parse("  ab12-cd34-ef56 \n"), "AB12CD34EF56")
        XCTAssertEqual(RigPairCode.display("AB12CD34EF56"), "AB12-CD34-EF56")
    }
    func testRejectsOtherSitesAndShapes() {
        XCTAssertNil(RigPairCode.parse("https://evil.example/#Mining/pair/AB12-CD34-EF56"))
        XCTAssertNil(RigPairCode.parse("https://parano1dworld.com.evil.example/mining/pair/AB12CD34EF56"))
        XCTAssertNil(RigPairCode.parse("https://user@parano1dworld.com/mining/pair/AB12CD34EF56"))
        XCTAssertNil(RigPairCode.parse("https://parano1dworld.com/#Explorer"))
        XCTAssertNil(RigPairCode.parse("AB12-CD34"))
        XCTAssertNil(RigPairCode.parse("AB12-CD34-EF5!"))
    }
    func testCanonicalMatchesWebsite() {
        XCTAssertEqual(RigClient.canonical(deviceId: "d1", ts: 1700000000000, nonce: "n", cmd: "start", argsJSON: "{\"mode\":\"preferred\"}"),
                       "p1w-rig-v1\nd1\n1700000000000\nn\nstart\n{\"mode\":\"preferred\"}")
    }
    func testRawSignatureVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let message = Data(RigClient.canonical(deviceId: "d1", ts: 1, nonce: "n", cmd: "status", argsJSON: "{}").utf8)
        let raw = try key.signature(for: message).rawRepresentation
        XCTAssertEqual(raw.count, 64)   // r || s, the format WebCrypto ECDSA produces and the rig verifies
        XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: message))
        XCTAssertEqual(RigBase64URL.encode(Data([0xfb, 0xff])), "-_8")
    }
    func testStatusReadsRigFields() {
        let status = RigStatus(["running": true, "telemetry": ["hashrateText": "1.2 MH/s", "accepted": 5, "rejected": 1],
                                "settings": ["pool": "pool.example:3333", "worker": "rig1"], "launched": ["mode": "gpu-pool"]])
        XCTAssertTrue(status.running); XCTAssertEqual(status.hashrate, "1.2 MH/s"); XCTAssertEqual(status.accepted, 5)
        XCTAssertEqual(status.mode, "gpu-pool"); XCTAssertNil(status.payout)
    }
    func testPublicMiningTabLayout() {
        XCTAssertEqual(TabLayout.read("nfts,chat,mining"), [.nfts, .chat, .mining])
        XCTAssertEqual(TabLayout.read("mining,nfts,chat"), [.mining, .nfts, .chat])
        XCTAssertEqual(TabLayout.read("mining,mining,chat"), TabLayout.defaults)
        XCTAssertEqual(TabLayout.read("trade,chat,mining"), TabLayout.defaults)
    }
    func testMiningTabIsOffered() {
        XCTAssertTrue(WalletTab.allCases.contains(.mining))
        XCTAssertEqual(WalletTab.mining.icon, "pickaxe")
        XCTAssertEqual(WorldIcon.match(WalletTab.mining.icon), "mining")
    }
    func testPhoneControlOffIsNotOfflineOrRevoked() {
        XCTAssertTrue(RigClient.Failure(message: "x", status: 423, offline: false, code: "phone-control-off").phoneControlOff)
        XCTAssertFalse(RigClient.Failure(message: "x", status: 423, offline: false, code: "locked").phoneControlOff)
        XCTAssertFalse(RigClient.Failure(message: "x", status: 503, offline: true, code: "phone-control-off").phoneControlOff)
        XCTAssertFalse(RigClient.Failure(message: "x", status: 401, offline: false).phoneControlOff)
    }
    @MainActor func testPhoneControlOffKeepsPairing() {
        let store = RigStore.shared
        let id = UUID()
        store.markControlOff(id)
        XCTAssertTrue(store.controlOff.contains(id))
        XCTAssertNil(store.errors[id]); XCTAssertFalse(store.revoked.contains(id)); XCTAssertNil(store.statuses[id])
        store.controlOff.remove(id)
    }
}

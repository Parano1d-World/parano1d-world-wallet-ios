import XCTest
@testable import Paranoid

/// Erase after 10 wrong app codes also unpairs the mining computers and turns voice control off
/// (Android audit, approved by the owner 27 Nov).
@MainActor final class LockoutEraseTests: XCTestCase {
    func testLockoutEraseUnpairsComputersAndResetsVoice() {
        let store = RigStore.shared
        let id = UUID()
        store.add(RigPairing(id: id, label: "Test rig", deviceId: "dev-test", fingerprint: "fp", deviceName: "Rig",
                             rigId: nil, secureEnclave: false, pairedAt: Date()))
        let voice = SiriVoiceStore.shared
        voice.miningStatus = true; voice.miningControl = "startStop"; voice.faceIDOff = true
        voice.chatRead = true; voice.chatSend = true; voice.roomRead = true
        LockoutErase.clearCompanions()
        XCTAssertFalse(store.rigs.contains { $0.id == id })
        XCTAssertTrue(store.rigs.isEmpty)
        XCTAssertNil(PhoneWidgetData.mining())
        XCTAssertFalse(SiriVoice.miningStatus); XCTAssertEqual(SiriVoice.miningControl, "off")
        XCTAssertTrue(SiriVoice.startStopNeedsFaceID, "Face ID for Start and Stop goes back on")
        XCTAssertFalse(voice.chatRead); XCTAssertFalse(voice.chatSend); XCTAssertFalse(voice.roomRead)
    }
    func testExplorerSendsNoStatusRequestInParano1dMode() async {
        let key = NodeEndpoints.paranoidKey, before = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        let id = String(repeating: "c", count: 64)
        let url = await ExplorerPages.transaction(id)
        XCTAssertEqual(url, ExplorerPages.primaryTransaction(id))
    }
}

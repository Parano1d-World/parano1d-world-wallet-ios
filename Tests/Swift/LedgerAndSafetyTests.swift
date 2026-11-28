import XCTest
@testable import Paranoid

final class LedgerAndSafetyTests: XCTestCase {
    private let known = "o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
    func testLookalikeAddressIsCaught() {
        // Same start and end, different middle: the classic poisoning pattern.
        var poisoned = Array(known); poisoned[20] = poisoned[20] == "q" ? "p" : "q"
        XCTAssertEqual(AddressSafety.lookalike(of: String(poisoned), known: [known]), known)
    }
    func testExactAndUnrelatedAddressesPass() {
        XCTAssertNil(AddressSafety.lookalike(of: known, known: [known]))
        XCTAssertNil(AddressSafety.lookalike(of: "o1aaaaaaa" + String(known.dropFirst(9)), known: [known]))
    }
    @MainActor func testConfirmedLookalikeIsAllowedOnlyAfterConfirmation() async throws {
        var poisoned = Array(known); poisoned[20] = poisoned[20] == "q" ? "p" : "q"
        let recipient = String(poisoned)
        AddressSafety.confirmed.remove(recipient)
        XCTAssertNotNil(AddressSafety.lookalike(of: recipient, known: [known]))
        AddressSafety.confirmed.insert(recipient)
        let wallet = WalletState()
        try await AddressSafety.check(recipient, wallet: wallet) // confirmed: no throw
        AddressSafety.confirmed.remove(recipient)
    }
    func testLedgerReaderHandlesOldAndNewCores() {
        let one: [String: Any] = ["pending": ["txid": "a", "state": "authorized", "local_reserved_total": "1500"]]
        XCTAssertEqual(PendingLedger.unresolved(one).count, 1)
        XCTAssertEqual(PendingLedger.reservedMicronoid(one), 1500)
        let many: [String: Any] = ["entries": [
            ["txid": "a", "state": "authorized", "local_reserved_total": "1000"],
            ["txid": "b", "state": "preparing", "local_reserved_total": "250"],
            ["txid": "c", "state": "finalized", "local_reserved_total": "9999"],
            ["txid": "d", "state": "authorized", "operation_kind": "native",
             "local_native_request": ["action": "transfer_nft", "collection_id": "col", "serial": "7"], "local_fee": "40"]]]
        XCTAssertEqual(PendingLedger.unresolved(many).count, 3)
        XCTAssertEqual(PendingLedger.reservedMicronoid(many), 1290)
        XCTAssertEqual(PendingLedger.pendingNFTs(many), ["col#7"])
        XCTAssertEqual(PendingText.title(many["entries"].flatMap { ($0 as? [[String: Any]])?[3] } ?? [:]), "Transfer Nft · NFT #7")
    }
}

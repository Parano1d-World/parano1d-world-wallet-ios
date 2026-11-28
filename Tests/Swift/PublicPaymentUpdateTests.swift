import XCTest
@testable import Paranoid
final class PublicPaymentUpdateTests:XCTestCase {
    func testClaimDoesNotBecomeVerification() {
        let update=PublicPaymentUpdate(["txid":String(repeating:"a",count:64),"claimed_stage":"finalized","receipt_hex":"zz"])
        XCTAssertEqual(update?.claimedStage,"finalized")
        XCTAssertEqual(update?.receipt,"")
    }
    func testInvalidTransactionRejected() {
        XCTAssertNil(PublicPaymentUpdate(["txid":"bad","claimed_stage":"finalized"]))
    }
    func testReceiptNormalized() {
        let update=PublicPaymentUpdate(["txid":String(repeating:"b",count:64),"claimed_stage":"included","receipt_hex":"ab cd"])
        XCTAssertEqual(update?.receipt,"abcd")
    }
}

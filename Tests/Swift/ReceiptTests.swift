import XCTest
@testable import Paranoid

final class ReceiptTests:XCTestCase {
    private let id=String(repeating:"a",count:64)
    func testReceiptNormalizesWhitespaceWithoutChangingBytes() throws {
        let input=try ReceiptInput(hex:"01 ab\nCD\t23",transactionID:id.uppercased())
        XCTAssertEqual(input.hex,"01abCD23")
        XCTAssertEqual(input.transactionID,id)
    }
    func testReceiptRejectsMalformedAndOversizedInput() {
        for hex in ["", "0", "0x12", "zz", "１２",String(repeating:"aa",count:131073),String(repeating:" ",count:300001)] {
            XCTAssertThrowsError(try ReceiptInput(hex:hex,transactionID:id))
        }
        XCTAssertThrowsError(try ReceiptInput(hex:"01",transactionID:String(repeating:"g",count:64)))
    }
    func testResultMustMatchExpectedTransaction() throws {
        let result:[String:Any]=["verified":true,"txid":id,"height":NSNumber(value:100),"confirmations":NSNumber(value:7),"finalized":false]
        let verified=try VerifiedReceipt(result:result,expectedID:id)
        XCTAssertEqual(verified.height,100)
        XCTAssertEqual(verified.confirmations,7)
        XCTAssertFalse(verified.finalized)
        XCTAssertThrowsError(try VerifiedReceipt(result:result,expectedID:String(repeating:"b",count:64)))
    }
    func testResultRejectsUnverifiedOrInvalidCounters() {
        let original:[String:Any]=["verified":true,"txid":id,"height":NSNumber(value:100),"confirmations":NSNumber(value:7),"finalized":false]
        for (key,value) in [("verified",false as Any),("height",-1 as Any),("height",1.5 as Any),("confirmations",0 as Any)] {
            var result=original;result[key]=value
            XCTAssertThrowsError(try VerifiedReceipt(result:result,expectedID:id))
        }
    }
}

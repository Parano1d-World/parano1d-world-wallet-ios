import XCTest
@testable import Paranoid

final class QuickSendTests:XCTestCase {
    func testKeypadLimitsDecimalsAndSupportsCorrection() {
        var amount=""
        for key in [".","1","2","3","4","5","6","7"] {amount=QuickAmountInput.apply(key,to:amount)}
        XCTAssertEqual(amount,"0.123456")
        amount=QuickAmountInput.apply("delete",to:amount)
        XCTAssertEqual(QuickAmountInput.apply("7",to:amount),"0.123457")
        XCTAssertEqual(QuickAmountInput.apply(".",to:amount),amount)
        XCTAssertEqual(QuickAmountInput.apply("invalid",to:amount),amount)
    }
    func testRecentRecipientOrderAndDeduplication() {
        XCTAssertEqual(QuickRecipientOrder.unique(["a","b","a","c","b"]),["a","b","c"])
    }
}

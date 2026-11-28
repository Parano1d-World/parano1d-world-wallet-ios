import XCTest
@testable import Paranoid
final class ReviewDisplayTests:XCTestCase {
    func testMoneyUsesExactIntegerFormatting(){
        XCTAssertEqual(ReviewDisplay.value("1",key:"fee_micronoid"),"0.000001 NOID")
        XCTAssertEqual(ReviewDisplay.value("1234567",key:"noid_debit_micronoid"),"1.234567 NOID")
        XCTAssertEqual(ReviewDisplay.value("18446744073709551615",key:"noid_credit_micronoid"),"18446744073709.551615 NOID")
    }
    func testNonmoneyIdentifiersAndBaseUnitsAreNotRescaled(){
        XCTAssertEqual(ReviewDisplay.value("1000000",key:"serial"),"1000000")
        XCTAssertEqual(ReviewDisplay.value("1000000",key:"quoted_output"),"1000000")
        XCTAssertEqual(ReviewDisplay.title("valid_until"),"Valid through block")
    }
}

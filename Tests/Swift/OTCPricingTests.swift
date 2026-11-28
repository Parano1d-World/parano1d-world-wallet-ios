import XCTest
@testable import Paranoid

final class OTCPricingTests:XCTestCase {
    func testFixedTotalAndUnitPriceAgree() {
        XCTAssertEqual(OTCPricing.unitPrice(quantity:"50",total:"15.5"),"0.31")
        XCTAssertEqual(OTCPricing.total(quantity:"50",unitPrice:"0.31"),"15.5")
    }
    func testPremiumAndDiscount() {
        XCTAssertEqual(OTCPricing.adjusted(reference:"0.31",percent:10),"0.341")
        XCTAssertEqual(OTCPricing.adjusted(reference:"0.31",percent:-10),"0.279")
        XCTAssertNil(OTCPricing.adjusted(reference:"0.31",percent:-100))
    }
    func testSettlementPrecisionAndOverflow() {
        XCTAssertEqual(OTCPricing.total(quantity:"3",unitPrice:"0.333333333333"),"1")
        XCTAssertNil(OTCPricing.total(quantity:"0.000001",unitPrice:"0.000001"))
        XCTAssertNil(OTCPricing.total(quantity:"18446744073709551615",unitPrice:"2"))
        for invalid in ["0","-1","NaN","1e3","1.2.3","1junk"] {
            XCTAssertNil(OTCPricing.positive(invalid))
        }
    }
}

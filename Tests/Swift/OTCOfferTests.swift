import XCTest
@testable import Paranoid

final class OTCOfferTests:XCTestCase {
    private let owner="o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
    private let evm="0x1111111111111111111111111111111111111111"
    func testAmountsAreExactMicrounitsAndRejectInvalidAmounts() throws {
        XCTAssertEqual(try OTCOffer.amount("1.000001"),"1000001")
        for amount in ["0","-1","nan","1.0000001","18446744073709551616"] {XCTAssertThrowsError(try OTCOffer.amount(amount))}
    }
    func testEthereumDraftRejectsZeroWrongLengthAndUnverifiedMixedCase() {
        XCTAssertTrue(OTCOffer.validEthereumAddress(evm))
        for address in ["0x"+String(repeating:"0",count:40),"0x123","TExample","0xabcdefABCDEFabcdefABCDEFabcdefABCDEFabcd"] {XCTAssertFalse(OTCOffer.validEthereumAddress(address))}
    }
    func testExpiryAndCounterpartyCannotSilentlyChangeTerms() throws {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        func offer(_ interval:TimeInterval,_ peer:String="") throws -> OTCOffer {
            try OTCOffer.make(side:.buyNOID,noid:"100",usdt:"25",makerNOID:owner,makerUSDT:evm,counterpartyNOID:peer,counterpartyUSDT:"",expires:now.addingTimeInterval(interval),now:now)
        }
        let draft=try offer(3600)
        XCTAssertEqual(draft.noidUnits,"100000000")
        XCTAssertEqual(draft.usdtUnits,"25000000")
        XCTAssertEqual(draft.usdtNetwork,"Ethereum mainnet · ERC-20")
        XCTAssertThrowsError(try offer(299))
        XCTAssertThrowsError(try offer(31*86400))
        XCTAssertThrowsError(try offer(3600,owner))
        let reloaded=try JSONDecoder().decode(OTCOffer.self,from:JSONEncoder().encode(draft))
        XCTAssertEqual(reloaded.id,draft.id)
        XCTAssertEqual(reloaded.expires,draft.expires)
    }
}

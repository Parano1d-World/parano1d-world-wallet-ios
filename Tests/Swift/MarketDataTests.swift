import XCTest
@testable import Paranoid

final class MarketDataTests:XCTestCase {
    func testMarketKindsStaySeparateAndPricesRejectInvalidValues(){
        let dex=NativeItem(fields:["type":"dex","asset_id":"asset","price_numerator":"20","price_denominator":"4"])
        let curve=NativeItem(fields:["type":"curve","asset_id":"asset"])
        XCTAssertNotEqual(dex.marketKey,curve.marketKey)
        XCTAssertEqual(dex.price,5)
        for (n,d) in [("-1","1"),("0","1"),("1","0"),("nan","1"),("1e308","1e-308")] {
            XCTAssertNil(NativeItem(fields:["price_numerator":n,"price_denominator":d]).price)
        }
    }
    func testRepeatedSnapshotDoesNotCreateMovementAndRollbackDropsLaterSamples(){
        let first=PriceSample(time:Date(timeIntervalSince1970:1),price:1,block:"a")
        let later=PriceSample(time:Date(timeIntervalSince1970:2),price:2,block:"b")
        let history=PriceObservations.append(later,to:[first])
        let retry=PriceObservations.append(first,to:history)
        XCTAssertEqual(retry.count,1)
        XCTAssertEqual(retry.first?.id,first.id)
        XCTAssertEqual(PriceObservations.append(later,to:history).count,2)
    }
    func testObservationStorageIsBoundedAndRejectsNonfinitePrices(){
        var history:[PriceSample]=[]
        for index in 0..<200 {history=PriceObservations.append(.init(time:Date(),price:1,block:String(index)),to:history)}
        XCTAssertEqual(history.count,180);XCTAssertEqual(history.first?.block,"20")
        XCTAssertEqual(PriceObservations.append(.init(time:Date(),price:.infinity,block:"bad"),to:history).count,180)
    }
}

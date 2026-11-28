import XCTest
@testable import Paranoid
final class MarketHistoryTests:XCTestCase {
    func testCandlePreservesOHLCAndRejectsInvalidRanges() throws {
        let row:[String:Any]=["height":"123","open":2.0,"high":4.0,"low":1.0,"close":3.0]
        let candle=try MarketCandle(row)
        XCTAssertEqual(candle.height,123);XCTAssertEqual(candle.open,2);XCTAssertEqual(candle.close,3)
        for key in ["open","high","low","close"] {
            var bad=row;bad[key]=Double.infinity;XCTAssertThrowsError(try MarketCandle(bad))
        }
        var bad=row;bad["high"]=2.5;XCTAssertThrowsError(try MarketCandle(bad))
        bad=row;bad["low"]=2.5;XCTAssertThrowsError(try MarketCandle(bad))
    }
}

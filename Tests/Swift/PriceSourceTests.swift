import XCTest
@testable import Paranoid

/// SafeTrade is the first NOID price source. This is the exact response its public ticker
/// returned on 24 Nov 2026 (only "at" is moved to now so the freshness rule applies).
final class PriceSourceTests: XCTestCase {
    private func live(at: TimeInterval = Date().timeIntervalSince1970) throws -> [String: Any] {
        let text = #"{"at":"AT","ticker":{"buy":"0.094388","sell":"0.09042","at":"AT","avg_price":"0.0986632","high":"0.12539956","last":"0.094388","low":"0.08125242","open":"0.10746035","price_change_percent":"-12.16%","volume":"43343.14439821","amount":"452413.39","vol":"43343.14439821"}}"#
            .replacingOccurrences(of: "AT", with: String(Int(at)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testLiveSafeTradeResponseGivesAFreshPrice() throws {
        let quote = try PriceSources.safetradeQuote(live())
        XCTAssertEqual(quote.usd, Decimal(string: "0.094388"))
        XCTAssertTrue(PriceSources.isFresh(quote))
    }
    func testThinMissingOrOldSafeTradePricesAreRefused() throws {
        var thin = try live(); var ticker = thin["ticker"] as! [String: Any]
        ticker["volume"] = "12"; ticker["vol"] = "12"; thin["ticker"] = ticker
        XCTAssertThrowsError(try PriceSources.safetradeQuote(thin))
        var zero = try live(); var t2 = zero["ticker"] as! [String: Any]; t2["last"] = "0"; zero["ticker"] = t2
        XCTAssertThrowsError(try PriceSources.safetradeQuote(zero))
        XCTAssertThrowsError(try PriceSources.safetradeQuote(["error": "public.market.doesnt_exist"]))
        let old = try PriceSources.safetradeQuote(live(at: Date().timeIntervalSince1970 - 3600))
        XCTAssertFalse(PriceSources.isFresh(old))
    }
}

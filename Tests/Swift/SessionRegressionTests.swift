import XCTest
@testable import Paranoid

final class SessionRegressionTests:XCTestCase {
    func testBiometricOfferIsOneTime() {
        BiometricOffer.pending=true
        XCTAssertTrue(BiometricOffer.pending)
        BiometricOffer.pending=false
        XCTAssertFalse(BiometricOffer.pending)
        XCTAssertNil(UserDefaults.standard.object(forKey:"biometricOfferPending.v1"))
    }
    @MainActor func testBriefBackgroundIntervalDoesNotLockButDeadlineDoes() {
        let prior=UserDefaults.standard.object(forKey:"autoLockSeconds")
        defer { if let prior {UserDefaults.standard.set(prior,forKey:"autoLockSeconds")} else {UserDefaults.standard.removeObject(forKey:"autoLockSeconds")} }
        let wallet=WalletState()
        wallet.autoLockSeconds=60
        wallet.locked=false
        let start=ContinuousClock().now
        wallet.touch(now:start)
        wallet.tick(now:start.advanced(by:.seconds(5)))
        XCTAssertFalse(wallet.locked)
        wallet.tick(now:start.advanced(by:.seconds(59)))
        XCTAssertFalse(wallet.locked)
        wallet.tick(now:start.advanced(by:.seconds(60)))
        XCTAssertTrue(wallet.locked)
    }
    @MainActor func testActivityRenewsDeadline() {
        let prior=UserDefaults.standard.object(forKey:"autoLockSeconds")
        defer { if let prior {UserDefaults.standard.set(prior,forKey:"autoLockSeconds")} else {UserDefaults.standard.removeObject(forKey:"autoLockSeconds")} }
        let wallet=WalletState();wallet.autoLockSeconds=30;wallet.locked=false
        let start=ContinuousClock().now
        wallet.touch(now:start)
        wallet.touch(now:start.advanced(by:.seconds(25)))
        wallet.tick(now:start.advanced(by:.seconds(35)))
        XCTAssertFalse(wallet.locked)
        wallet.tick(now:start.advanced(by:.seconds(55)))
        XCTAssertTrue(wallet.locked)
    }
    func testPriceTimestampAllowsFractionalSeconds() {
        XCTAssertNotNil(PriceFeed.quoteDate("2026-11-15T00:00:00.123Z"))
        XCTAssertNotNil(PriceFeed.quoteDate("2026-11-15T00:00:00Z"))
        XCTAssertNil(PriceFeed.quoteDate("not a timestamp"))
    }
}

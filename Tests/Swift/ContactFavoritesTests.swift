import XCTest
@testable import Paranoid
final class ContactFavoritesTests:XCTestCase {
    func testFavoriteRoundTripAndRemoval() {
        let id=String(repeating:"a",count:64)
        let saved=ContactFavorites.toggled(id,in:"[]")
        XCTAssertTrue(ContactFavorites.read(saved).contains(id))
        XCTAssertTrue(ContactFavorites.read(ContactFavorites.toggled(id,in:saved)).isEmpty)
    }
    func testInvalidIdentityAndMalformedStorage() {
        XCTAssertEqual(ContactFavorites.toggled("invalid",in:"[]"),"[]")
        XCTAssertTrue(ContactFavorites.read("broken").isEmpty)
    }
}

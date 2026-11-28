import XCTest
@testable import Paranoid

final class PublicChatSafetyTests: XCTestCase {
    func testNarrowPhraseMatchingAndNormalization() {
        XCTAssertNotNil(PublicChatSafety.contentReason("I WILL—KILL YOU!"))
        XCTAssertNil(PublicChatSafety.contentReason("Please kill the stuck process, then restart the app."))
        XCTAssertNil(PublicChatSafety.contentReason("This marketplace is terrible. I disagree with you."))
        XCTAssertNotNil(PublicChatSafety.contentReason("ＳＥＮＤ ＮＵＤＥＳ"))
    }
    func testOutgoingRateWindowAndDuplicates() {
        let history = [(text: "Hello world!", time: 100.0)]
        XCTAssertNotNil(PublicChatSafety.outgoingReason(text: "hello WORLD", name: "Member", history: history, now: 159))
        XCTAssertNil(PublicChatSafety.outgoingReason(text: "hello WORLD", name: "Member", history: history, now: 160))
        let five = (0..<5).map { (text: "post \($0)", time: 100.0 + Double($0)) }
        XCTAssertNotNil(PublicChatSafety.outgoingReason(text: "different", name: "Member", history: five, now: 110))
    }
    func testIncomingDuplicatesAreScopedToSenderAndMinute() {
        var screening = PublicChatScreening()
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertNil(screening.reason(sender: "a", name: "Member", text: "Hello", date: date))
        XCTAssertNil(screening.reason(sender: "b", name: "Member", text: "Hello", date: date))
        XCTAssertNotNil(screening.reason(sender: "a", name: "Member", text: "HELLO!", date: date.addingTimeInterval(5)))
        XCTAssertNil(screening.reason(sender: "a", name: "Member", text: "Hello", date: date.addingTimeInterval(66)))
    }
    func testPaymentUpdatesAreNotTreatedAsDuplicateChat() {
        var screening = PublicChatScreening()
        for _ in 0..<10 {
            XCTAssertNil(screening.reason(sender: "a", name: "Member", text: "Payment update", date: Date(), screenSpam: false))
        }
    }
    func testDisplayNameIsScreened() {
        var screening = PublicChatScreening()
        XCTAssertNotNil(screening.reason(sender: "a", name: "kill yourself", text: "hello", date: Date()))
    }
}

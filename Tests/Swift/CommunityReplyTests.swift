import XCTest
@testable import Paranoid

final class CommunityReplyTests: XCTestCase {
    func testReplyCarriesEntireOriginalIncludingLineBreaks() {
        let original = String(repeating: "Complete original sentence. ", count: 12) + "\nSecond line."
        XCTAssertGreaterThan(original.count, 100)
        let quote = CommunityReply.quote(name: "pisa", message: original)
        let posted = CommunityReply.compose(quote: quote, draft: "iOS version?")
        XCTAssertTrue(posted.contains(original))
        XCTAssertTrue(posted.hasSuffix("iOS version?"))
        XCTAssertTrue(CommunityReply.fits(posted))
    }

    func testOversizedQuoteIsRejectedWithoutSilentTruncation() {
        let original = String(repeating: "x", count: 4090)
        let posted = CommunityReply.compose(quote: CommunityReply.quote(name: "Member", message: original), draft: "Reply")
        XCTAssertTrue(posted.contains(original))
        XCTAssertFalse(CommunityReply.fits(posted))
    }
}

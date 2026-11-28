import XCTest
@testable import Paranoid

@MainActor final class InboxPagingTests:XCTestCase {
    func testOversizedPagesRetrySmallerWithoutChangingCursor() async throws {
        var limits:[Int]=[]
        let page=try await InboxPaging.load {limit in
            limits.append(limit)
            if limit>2 {throw RelayResponseError.tooLarge}
            return ["cursor":7,"messages":[]]
        }
        XCTAssertEqual(limits,[30,8,2]);XCTAssertEqual(page["cursor"] as? Int,7)
    }
    func testOtherFailuresAreNotRetried() async {
        var attempts=0
        do {_ = try await InboxPaging.load {_ in attempts+=1;throw AppFailure("Invalid signature")};XCTFail("Expected rejection")}
        catch {XCTAssertEqual(attempts,1)}
    }
    func testSingleOversizedMessageFailsWithoutSkippingIt() async {
        var limits:[Int]=[]
        do {_ = try await InboxPaging.load {limit in limits.append(limit);throw RelayResponseError.tooLarge};XCTFail("Expected size error")}
        catch {XCTAssertEqual(limits,[30,8,2,1])}
    }
}

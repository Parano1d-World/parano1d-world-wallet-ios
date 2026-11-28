import XCTest
@testable import Paranoid

@MainActor final class CommunityPagingTests: XCTestCase {
    func testRefreshReachesNewestPageInsteadOfStoppingAtFirstThirty() async throws {
        var cursors: [UInt64] = []
        let page = try await CommunityPaging.load(after: 0, through: 65) { cursor in
            cursors.append(cursor)
            let end = min(cursor + 30, 65)
            let rows: [[String: Any]] = ((cursor + 1)...end).map { ["cursor": NSNumber(value: $0)] }
            return ["messages": rows, "cursor": NSNumber(value: end)]
        }
        XCTAssertEqual(cursors, [0, 30, 60])
        XCTAssertEqual((page["messages"] as? [[String: Any]])?.count, 65)
        XCTAssertEqual((page["cursor"] as? NSNumber)?.uint64Value, 65)
    }
    func testEmptySparseWindowTerminates() async throws {
        var calls = 0
        let page = try await CommunityPaging.load(after: 10, through: 100) { cursor in
            calls += 1
            return ["messages": [[String: Any]](), "cursor": NSNumber(value: cursor)]
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual((page["messages"] as? [[String: Any]])?.count, 0)
    }
    func testCursorCannotSkipUnseenMessages() async {
        do {
            _ = try await CommunityPaging.load(after: 0, through: 10) { _ in
                ["messages": [["cursor": NSNumber(value: 1)]], "cursor": NSNumber(value: 10)]
            }
            XCTFail("Expected rejection")
        } catch { }
    }
}

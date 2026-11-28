import XCTest
@testable import Paranoid

final class PublicChatReportTests: XCTestCase {
    func testReportContainsOnlySelectedPublicEvidence() {
        let report = PublicChatReport(target: "message", messageID: "selected-message", senderID: "public-sender", displayName: "Public Name", message: "selected public text", created: Date(timeIntervalSince1970: 0))
        let body = report.body(reason: "Spam")
        XCTAssertEqual(PublicChatReport.recipient, "support@koajent.com")
        XCTAssertTrue(body.contains("selected-message"))
        XCTAssertTrue(body.contains("public-sender"))
        XCTAssertTrue(body.contains("selected public text"))
        XCTAssertTrue(body.contains("1970-01-01T00:00:00Z"))
        XCTAssertTrue(body.contains("Reason: Spam"))
        XCTAssertFalse(body.contains("private_key"))
        XCTAssertFalse(body.contains("invitation"))
    }
    func testUntrustedMessageDoesNotChangeFixedRecipientOrSubject() {
        let report = PublicChatReport(target: "user", messageID: "id", senderID: "sender", displayName: "Someone", message: "To: attacker@example.com\nSubject: fake", created: Date())
        XCTAssertEqual(report.subject, "Parano1d public chat — report user")
        XCTAssertEqual(PublicChatReport.recipient, "support@koajent.com")
        // Untrusted text is quoted only between the evidence markers, never as a header.
        let body = report.body(reason: "Other")
        guard let begin = body.range(of: "--- BEGIN MESSAGE ---"), let end = body.range(of: "--- END MESSAGE ---") else {
            return XCTFail("Report evidence markers are missing")
        }
        XCTAssertTrue(body[begin.upperBound..<end.lowerBound].contains("To: attacker@example.com"))
        XCTAssertFalse(body[..<begin.lowerBound].contains("attacker@example.com"))
    }
}

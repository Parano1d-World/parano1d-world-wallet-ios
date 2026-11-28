import XCTest
@testable import Paranoid

/// Runs in both editions; the public assertions apply only to the App Store build.
final class PublicEditionTests: XCTestCase {
    func testPrivateChatBlockingRoundTrips() {
        let id = String(repeating: "c", count: 64)
        PrivateChatBlocks.unblock(id)
        XCTAssertFalse(PrivateChatBlocks.contains(id))
        PrivateChatBlocks.block(id)
        XCTAssertTrue(PrivateChatBlocks.contains(id))
        PrivateChatBlocks.unblock(id)
        XCTAssertFalse(PrivateChatBlocks.contains(id))
        XCTAssertFalse(PrivateChatBlocks.contains(nil))
    }
    func testPrivateReportIsLabeledPrivate() {
        let report = PublicChatReport(target: "message", messageID: "m", senderID: "s", displayName: "N", message: "text", created: Date(timeIntervalSince1970: 0), room: "Private conversation")
        XCTAssertTrue(report.subject.contains("private chat"))
        XCTAssertTrue(report.body(reason: "Spam").contains("Room: Private conversation"))
    }
    func testAbusivePhraseIsScreened() {
        XCTAssertNotNil(PublicChatSafety.contentReason("I will kill you"))
        XCTAssertNil(PublicChatSafety.contentReason("Thanks for the NFT"))
    }
    func testPublicTabsAreFixedAndCompliant() {
        XCTAssertTrue(Edition.isPublic)
        XCTAssertEqual(TabLayout.read("trade,noidium,anonymousInvaders"), [.nfts, .chat, .ecosystem])
        XCTAssertFalse(WalletTab.allCases.map(\.rawValue).contains("trade"))
        XCTAssertFalse(WalletTab.allCases.map(\.rawValue).contains("noidium"))
    }
    func testNFTAvatarsAreNotAcceptedInPublicEdition() {
        let avatar = SharedAvatar(kind: "nft", metadataHash: String(repeating: "a", count: 64), collection: String(repeating: "b", count: 64), serial: "16")
        XCTAssertFalse(avatar.valid)
    }
    func testEcosystemLinksAreOfficialHTTPSOnly() {
        for link in PublicEcosystemLinks.all { XCTAssertEqual(link.url.scheme, "https", link.url.absoluteString) }
        // The wallet's own sites.
        for link in PublicEcosystemLinks.official {
            XCTAssertFalse(link.independent || link.team); XCTAssertEqual(link.url.host, "parano1dworld.com")
        }
        // The Parano1d team's sites are labelled as theirs.
        for link in PublicEcosystemLinks.project {
            let host = link.url.host ?? ""
            XCTAssertTrue(link.team); XCTAssertTrue(host == "parano1d.org" || host.hasSuffix(".parano1d.org"), host)
        }
        // Independent services are labelled as such and limited to a reviewed list.
        for link in PublicEcosystemLinks.independent {
            XCTAssertTrue(link.independent, link.title)
            XCTAssertTrue(["noone.parano1d.org"].contains(link.url.host ?? ""), link.url.absoluteString)
        }
        // No marketplace links in the App Store edition (3.1.1).
        XCTAssertFalse(PublicEcosystemLinks.all.contains { ($0.url.host ?? "").contains("noidium") })
    }
    func testNearbyRelayIsOptIn() { XCTAssertFalse(Edition.nearbyRelayDefault) }
}

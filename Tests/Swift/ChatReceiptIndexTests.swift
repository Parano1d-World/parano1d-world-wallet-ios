import XCTest
@testable import Paranoid

final class ChatReceiptIndexTests:XCTestCase {
    func testChatReferencesPersistWithoutTrustingPeerStage() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let store=ChatReceiptIndex(directory:folder)
        let first="o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
        let transaction=String(repeating:"a",count:64)
        let claim=["relay_update":["txid":transaction,"claimed_stage":"finalized"]]
        let preview=try XCTUnwrap(ChatPaymentPreview(claim))
        let earlier=Date(timeIntervalSince1970:100)
        try await store.observe(root:first,preview:preview,date:earlier)
        let newer=String(repeating:"b",count:64)
        let otherPreview=try XCTUnwrap(ChatPaymentPreview(["payment":["txid":newer,"authorized":true]]))
        try await store.observe(root:first,preview:otherPreview,date:earlier.addingTimeInterval(60))
        let saved=try await ChatReceiptIndex(directory:folder).entries(root:first)
        XCTAssertEqual(saved.map(\.id),[newer,transaction])
        XCTAssertEqual(saved.map(\.source),["chat","chat"])
        XCTAssertNil(saved.last?.suppliedReceipt)
        let manual=String(repeating:"c",count:64)
        try await store.rememberVerified(root:first,transactionID:manual,hex:nil,date:earlier.addingTimeInterval(120))
        let mixed=try await store.entries(root:first)
        XCTAssertEqual(mixed.first?.source,"manual")
        XCTAssertEqual(mixed.filter{$0.source == "chat"}.count,2)
        do {try await store.entries(root:"not-a-wallet-address");XCTFail("Invalid wallet identity accepted")}
        catch {}
    }
}

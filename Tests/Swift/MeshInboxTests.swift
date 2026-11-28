import XCTest
@testable import Paranoid

final class MeshInboxTests:XCTestCase {
    func testMeshImportFiltersRecipientExpiryAndDuplicateWithoutAdvancingRelayCursor() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let identity=String(repeating:"a",count:64),other=String(repeating:"b",count:64)
        let store=MessageArchive(directory:directory,contacts:[other])
        let ciphertext=Data("opaque encrypted payload".utf8)
        let future=UInt64(Date().timeIntervalSince1970*1000)+60_000
        let own=ValidatedMessage(id:"own",senderID:other,recipientID:identity,expires:future,data:ciphertext)
        let transit=ValidatedMessage(id:"transit",senderID:identity,recipientID:other,expires:future,data:ciphertext)
        let expired=ValidatedMessage(id:"expired",senderID:other,recipientID:identity,expires:1,data:ciphertext)
        try await store.importNearby([own,own,transit,expired],identity:identity)
        try await store.importNearby([own],identity:identity)
        let saved=try await store.packets(identity:identity)
        XCTAssertEqual(saved.map(\.id),["own"])
        XCTAssertEqual(saved.first?.envelope,ciphertext)
        XCTAssertEqual(saved.first?.contactID,other)
        XCTAssertEqual(saved.first?.received,true)
        let cursor=try await store.cursor(identity:identity)
        XCTAssertEqual(cursor,0)
    }
    func testMeshAndOnlineReplayShareArchiveDeduplication() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let identity=String(repeating:"a",count:64)
        let store=MessageArchive(directory:directory,contacts:["peer"])
        let data=Data("ciphertext".utf8)
        try await store.commit([.init(id:"same",contactID:"peer",received:true,date:Date(),envelope:data)],identity:identity,after:0,cursor:7)
        try await store.importNearby([.init(id:"same",senderID:"peer",recipientID:identity,expires:UInt64(Date().timeIntervalSince1970*1000)+60_000,data:data)],identity:identity)
        let saved=try await store.packets(identity:identity)
        let cursor=try await store.cursor(identity:identity)
        XCTAssertEqual(saved.count,1)
        XCTAssertEqual(cursor,7)
    }
}

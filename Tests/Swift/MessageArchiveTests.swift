import XCTest
@testable import Paranoid

final class MessageArchiveTests:XCTestCase {
    func testCiphertextPersistsAndDuplicateImportIsRejected() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let identity=String(repeating:"a",count:64)
        let store=MessageArchive(directory:directory)
        let packet=MessageArchive.Packet(id:"message1",contactID:"peer",received:true,date:Date(),envelope:Data("ciphertext".utf8))
        try await store.append(packet,identity:identity)
        let reopened=MessageArchive(directory:directory)
        let stored=try await reopened.packets(identity:identity)
        XCTAssertEqual(stored.count,1)
        XCTAssertEqual(stored[0].envelope,packet.envelope)
        do {try await reopened.append(packet,identity:identity);XCTFail("Replay accepted")} catch {}
    }
    func testCorruptArchiveIsNotOverwritten() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let identity=String(repeating:"b",count:64)
        let store=MessageArchive(directory:directory)
        _=try await store.packets(identity:identity)
        let path=directory.appendingPathComponent(identity+".json")
        let damaged=Data("invalid".utf8);try damaged.write(to:path)
        let packet=MessageArchive.Packet(id:"message2",contactID:"peer",received:true,date:Date(),envelope:Data("ciphertext".utf8))
        do {try await store.append(packet,identity:identity);XCTFail("Corrupt archive replaced")} catch {}
        XCTAssertEqual(try Data(contentsOf:path),damaged)
    }
    func testLocalDeletionPersistsAndDoesNotRestoreFromNearbyOrRelay() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let identity=String(repeating:"c",count:64)
        let packet=MessageArchive.Packet(id:"deleted",contactID:"peer",received:true,date:Date(),envelope:Data("ciphertext".utf8))
        let store=MessageArchive(directory:directory)
        try await store.append(packet,identity:identity)
        try await store.delete(identity:identity,contactID:"peer",id:packet.id)
        let reopened=MessageArchive(directory:directory)
        let future=UInt64(Date().timeIntervalSince1970*1000)+60_000
        try await reopened.importNearby([.init(id:packet.id,senderID:"peer",recipientID:identity,expires:future,data:packet.envelope)],identity:identity)
        try await reopened.commit([packet],identity:identity,after:0,cursor:1)
        let saved=try await reopened.packets(identity:identity)
        let cursor=try await reopened.cursor(identity:identity)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(cursor,1)
    }
    func testConversationPreferencesAndDeletionPersistWithoutRemovingContact() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let identity=String(repeating:"d",count:64)
        let store=MessageArchive(directory:directory)
        let packet=MessageArchive.Packet(id:"request",contactID:"peer",received:true,date:Date(),envelope:Data("ciphertext".utf8))
        try await store.append(packet,identity:identity)
        try await store.setConversationOrder(identity:identity,order:["peer","other"])
        try await store.setArchived(identity:identity,contactID:"peer",archived:true)
        let reopened=MessageArchive(directory:directory)
        let preferences=try await reopened.conversationPreferences(identity:identity)
        XCTAssertEqual(preferences.order,["peer","other"])
        XCTAssertTrue(preferences.archived.contains("peer"))
        try await reopened.deleteConversation(identity:identity,contactID:"peer")
        let future=UInt64(Date().timeIntervalSince1970*1000)+60_000
        try await reopened.importNearby([.init(id:packet.id,senderID:"peer",recipientID:identity,expires:future,data:packet.envelope)],identity:identity)
        let saved=try await reopened.packets(identity:identity)
        let after=try await reopened.conversationPreferences(identity:identity)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(after.order,["peer","other"])
    }
}

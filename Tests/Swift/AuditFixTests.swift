import XCTest
@testable import Paranoid

/// Audit findings 177 and R1–R3: blocks before saving, message requests, history that never
/// jams, deletions that never fill up, and the upgrade from version 1 history.
final class AuditFixTests:XCTestCase {
    private let me=String(repeating:"e",count:64)
    private var directory:URL!
    override func setUp() {directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    override func tearDown() {try? FileManager.default.removeItem(at:directory);PrivateChatBlocks.unblock("blocked-sender")}
    private func packet(_ id:String,_ from:String,received:Bool=true,date:Date=Date()) -> MessageArchive.Packet {
        .init(id:id,contactID:from,received:received,date:date,envelope:Data("ciphertext-\(id)".utf8))
    }
    private func mesh(_ id:String,_ from:String) -> ValidatedMessage {
        .init(id:id,senderID:from,recipientID:me,expires:UInt64(Date().timeIntervalSince1970*1000)+60_000,data:Data("ciphertext-\(id)".utf8))
    }

    func testBlockedSenderIsDroppedOnBothPathsAndCursorStillAdvances() async throws {
        PrivateChatBlocks.block("blocked-sender")
        let store=MessageArchive(directory:directory,contacts:["blocked-sender"])
        try await store.importNearby([mesh("b1","blocked-sender")],identity:me)
        try await store.commit([packet("b2","blocked-sender")],identity:me,after:0,cursor:5)
        let saved=try await store.packets(identity:me),requests=try await store.requestPackets(identity:me),cursor=try await store.cursor(identity:me)
        XCTAssertTrue(saved.isEmpty);XCTAssertTrue(requests.isEmpty);XCTAssertEqual(cursor,5)
        // Unblocking does not bring dropped messages back, and resends stay ignored.
        PrivateChatBlocks.unblock("blocked-sender")
        try await store.importNearby([mesh("b1","blocked-sender")],identity:me)
        let again=try await store.packets(identity:me);XCTAssertTrue(again.isEmpty)
    }
    func testBlockingAContactKeepsExistingHistoryForUnblock() async throws {
        let store=MessageArchive(directory:directory,contacts:["blocked-sender"])
        try await store.commit([packet("x1","blocked-sender")],identity:me,after:0,cursor:1)
        PrivateChatBlocks.block("blocked-sender")
        try await store.refresh(identity:me)
        try await store.commit([packet("x2","blocked-sender")],identity:me,after:1,cursor:2)
        let saved=try await store.packets(identity:me)
        XCTAssertEqual(saved.map(\.id),["x1"]) // kept (the chat screen hides it); x2 dropped
    }
    func testBlockedStrangerRequestsAreDiscarded() async throws {
        let store=MessageArchive(directory:directory,contacts:[])
        try await store.importNearby([mesh("k1","blocked-sender")],identity:me)
        PrivateChatBlocks.block("blocked-sender")
        try await store.refresh(identity:me)
        let requests=try await store.requestPackets(identity:me);XCTAssertTrue(requests.isEmpty)
        PrivateChatBlocks.unblock("blocked-sender")
        let still=try await store.requestPackets(identity:me);XCTAssertTrue(still.isEmpty)
    }
    func testStrangerGoesToRequestsAndMovesToChatOnceAccepted() async throws {
        let store=MessageArchive(directory:directory,contacts:[])
        try await store.importNearby([mesh("s1","stranger")],identity:me)
        try await store.commit([packet("s2","stranger")],identity:me,after:0,cursor:2)
        var saved=try await store.packets(identity:me);var requests=try await store.requestPackets(identity:me)
        XCTAssertTrue(saved.isEmpty);XCTAssertEqual(Set(requests.map(\.id)),["s1","s2"])
        let unread=try await store.unreadCounts(identity:me);XCTAssertTrue(unread.isEmpty)
        // Adding them as a contact moves their messages into chat.
        let accepted=MessageArchive(directory:directory,contacts:["stranger"])
        try await accepted.refresh(identity:me)
        saved=try await accepted.packets(identity:me);requests=try await accepted.requestPackets(identity:me)
        XCTAssertEqual(Set(saved.map(\.id)),["s1","s2"]);XCTAssertTrue(requests.isEmpty)
    }
    func testReplyingAcceptsTheSender() async throws {
        let store=MessageArchive(directory:directory,contacts:[])
        try await store.commit([packet("r1","friend")],identity:me,after:0,cursor:1)
        try await store.append(packet("mine","friend",received:false),identity:me)
        try await store.refresh(identity:me)
        try await store.commit([packet("r2","friend")],identity:me,after:1,cursor:2)
        let saved=try await store.packets(identity:me)
        XCTAssertEqual(Set(saved.map(\.id)),["r1","mine","r2"])
    }
    func testDeleteAndBlockRequestsIgnoreResends() async throws {
        let store=MessageArchive(directory:directory,contacts:[])
        try await store.importNearby([mesh("d1","stranger")],identity:me)
        try await store.discardRequests(identity:me,senderID:"stranger")
        try await store.importNearby([mesh("d1","stranger")],identity:me)
        let requests=try await store.requestPackets(identity:me);XCTAssertTrue(requests.isEmpty)
    }
    func testStrangerFloodNeverBlocksContactsOrTheInbox() async throws {
        let store=MessageArchive(directory:directory,contacts:["friend"])
        var cursor:UInt64=0
        for page in 0..<20 {
            let batch=(0..<30).map{packet("flood-\(page)-\($0)","stranger")}
            try await store.commit(batch,identity:me,after:cursor,cursor:cursor+30);cursor+=30
        }
        try await store.commit([packet("hello","friend")],identity:me,after:cursor,cursor:cursor+1)
        let saved=try await store.packets(identity:me),requests=try await store.requestPackets(identity:me),end=try await store.cursor(identity:me)
        XCTAssertEqual(saved.map(\.id),["hello"])
        XCTAssertLessThanOrEqual(requests.count,MessageArchive.requestsPerSender)
        XCTAssertEqual(end,cursor+1)
    }
    func testLongConversationRollsOverAndChatKeepsWorking() async throws {
        let store=MessageArchive(directory:directory,contacts:["friend"])
        let start=Date().addingTimeInterval(-10_000)
        for i in 0..<600 {try await store.append(packet(String(format:"m%04d",i),"friend",received:i%2==0,date:start.addingTimeInterval(Double(i))),identity:me)}
        let saved=try await store.packets(identity:me)
        // Rolls in batches: at 501 it drops to 400, then grows again to 499.
        XCTAssertLessThanOrEqual(saved.count,MessageArchive.perConversation)
        XCTAssertEqual(Set(saved.map(\.id)).contains("m0599"),true)
        let older=try await store.olderPackets(identity:me,contactID:"friend")
        XCTAssertEqual(older.count+saved.count,600);XCTAssertEqual(older.last?.id,"m0000")
        let olderCount=try await store.olderCount(identity:me,contactID:"friend");XCTAssertEqual(olderCount,older.count)
        // Receiving and sending still work.
        try await store.commit([packet("new","friend")],identity:me,after:0,cursor:1)
        try await store.append(packet("reply","friend",received:false),identity:me)
        let after=try await store.packets(identity:me)
        XCTAssertTrue(after.contains{$0.id=="new"});XCTAssertTrue(after.contains{$0.id=="reply"})
        // Deleting an older message works too.
        try await store.delete(identity:me,contactID:"friend",id:"m0000")
        let olderAfter=try await store.olderPackets(identity:me,contactID:"friend");XCTAssertFalse(olderAfter.contains{$0.id=="m0000"})
    }
    func testVersionOneHistoryUpgradesWithoutLosingAnything() async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let enc=JSONEncoder()
        let friend=[packet("f1","friend"),packet("f2","friend",received:false)],stranger=[packet("u1","stranger")]
        let deleted=(0..<5000).map{"gone-\($0)"}
        let v1:[String:Any]=[
            "version":1,"cursor":9,"readIDs":["f1"],"deletedIDs":deleted,
            "conversationOrder":["friend"],"archivedContactIDs":["friend"],
            "packets":try (friend+stranger).map{try JSONSerialization.jsonObject(with:enc.encode($0))}]
        try JSONSerialization.data(withJSONObject:v1).write(to:directory.appendingPathComponent(me+".json"))
        let store=MessageArchive(directory:directory,contacts:["friend"])
        try await store.refresh(identity:me)
        try await store.refresh(identity:me) // second run is a no-op
        let saved=try await store.packets(identity:me),requests=try await store.requestPackets(identity:me)
        // Saved history is never moved or cut, including people who aren't contacts.
        XCTAssertEqual(Set(saved.map(\.id)),["f1","f2","u1"]);XCTAssertTrue(requests.isEmpty)
        let cursor=try await store.cursor(identity:me);XCTAssertEqual(cursor,9)
        let prefs=try await store.conversationPreferences(identity:me)
        XCTAssertEqual(prefs.order,["friend"]);XCTAssertTrue(prefs.archived.contains("friend"))
        let unread=try await store.unreadCounts(identity:me);XCTAssertNil(unread["friend"])
        // Old deletions are still honoured, and deleting no longer fails at 5,000.
        try await store.importNearby([mesh("gone-42","friend")],identity:me)
        try await store.delete(identity:me,contactID:"friend",id:"f2")
        let final=try await store.packets(identity:me);XCTAssertEqual(Set(final.map(\.id)),["f1","u1"])
    }
    func testDamagedSideFileIsKeptAsideAndChatContinues() async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data("damaged".utf8).write(to:directory.appendingPathComponent(me+".requests.json"))
        let store=MessageArchive(directory:directory,contacts:[])
        try await store.commit([packet("q1","stranger")],identity:me,after:0,cursor:1)
        let requests=try await store.requestPackets(identity:me);XCTAssertEqual(requests.map(\.id),["q1"])
        let kept=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.contains("damaged-")}
        XCTAssertEqual(kept.count,1)
    }

    // MARK: Fair Nearby carry queue
    private func carried(_ id:String,_ from:String,expires:UInt64=1,bytes:Int=10) -> ValidatedMessage {
        .init(id:id,senderID:from,recipientID:"r",expires:expires,data:Data(count:bytes))
    }
    func testOneSenderCannotFillTheCarryQueue() throws {
        var queue=(0..<16).map{carried("a\($0)","spammer",expires:UInt64($0+1))}
        let evict=try NearbyTransport.makeRoom(for:carried("a16","spammer",expires:99),in:queue,ownID:"me")
        XCTAssertEqual(evict,["a0"]) // its own oldest makes way; others untouched
        queue+=(0..<80).map{carried("b\($0)","other\($0)")}
        let next=try NearbyTransport.makeRoom(for:carried("c","newcomer"),in:queue,ownID:"me")
        XCTAssertEqual(next.count,1);XCTAssertTrue(next.first!.hasPrefix("a"))
    }
    func testOwnPacketsAlwaysFitWhenOthersFillTheQueue() throws {
        let queue=(0..<128).map{carried("x\($0)","sender\($0 % 8)",expires:UInt64($0+1))}
        let evict=try NearbyTransport.makeRoom(for:carried("mine","me"),in:queue,ownID:"me")
        XCTAssertEqual(evict.count,1);XCTAssertFalse(evict.contains("mine"))
        let ownOnly=(0..<128).map{carried("o\($0)","me")}
        XCTAssertThrowsError(try NearbyTransport.makeRoom(for:carried("more","me"),in:ownOnly,ownID:"me"))
    }
    func testLargePacketsMakeRoomByBytesWithoutTouchingOwnPackets() throws {
        let queue=[carried("own","me",bytes:1_000_000)]+(0..<5).map{carried("big\($0)","peer",expires:UInt64($0+1),bytes:1_000_000)}
        let evict=try NearbyTransport.makeRoom(for:carried("new","peer2",bytes:1_000_000),in:queue,ownID:"me")
        XCTAssertFalse(evict.contains("own"));XCTAssertTrue(evict.contains("big0"))
    }

    // MARK: Independent review cases (H1, H2, M2, M3)
    func testRemovingAContactNeverMovesOrCutsTheirHistory() async throws {
        let before=MessageArchive(directory:directory,contacts:["friend"])
        var cursor:UInt64=0
        for page in 0..<2 {
            try await before.commit((0..<30).map{packet("h-\(page)-\($0)","friend")},identity:me,after:cursor,cursor:cursor+30);cursor+=30
        }
        let after=MessageArchive(directory:directory,contacts:[]) // contact removed
        try await after.refresh(identity:me)
        try await after.commit([packet("still","friend")],identity:me,after:cursor,cursor:cursor+1)
        let saved=try await after.packets(identity:me),requests=try await after.requestPackets(identity:me)
        XCTAssertEqual(saved.count,61);XCTAssertTrue(requests.isEmpty)
    }
    func testRolledOutMessageDoesNotComeBackAsNew() async throws {
        let store=MessageArchive(directory:directory,contacts:["friend"])
        let start=Date().addingTimeInterval(-10_000)
        for i in 0..<501 {try await store.append(packet(String(format:"r%04d",i),"friend",date:start.addingTimeInterval(Double(i))),identity:me)}
        let older=try await store.olderPackets(identity:me,contactID:"friend")
        XCTAssertFalse(older.isEmpty)
        try await store.importNearby([mesh(older[0].id,"friend")],identity:me)
        let saved=try await store.packets(identity:me)
        XCTAssertFalse(saved.contains{$0.id==older[0].id})
    }
    func testAcceptingFromAnInvitationLastsAcrossRefresh() async throws {
        let store=MessageArchive(directory:directory,contacts:[])
        try await store.importNearby([mesh("a1","newfriend")],identity:me)
        let moved=try await store.accept(identity:me,senderID:"newfriend");XCTAssertTrue(moved)
        try await store.refresh(identity:me)
        try await store.importNearby([mesh("a2","newfriend")],identity:me)
        let saved=try await store.packets(identity:me),requests=try await store.requestPackets(identity:me)
        XCTAssertEqual(Set(saved.map(\.id)),["a1","a2"]);XCTAssertTrue(requests.isEmpty)
    }
    func testDuplicateRequestsAfterACrashAreMergedNotDiscarded() async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let one=packet("dup","stranger")
        let side:[String:Any]=["version":2,"packets":[try JSONSerialization.jsonObject(with:JSONEncoder().encode(one)),try JSONSerialization.jsonObject(with:JSONEncoder().encode(one))]]
        try JSONSerialization.data(withJSONObject:side).write(to:directory.appendingPathComponent(me+".requests.json"))
        let store=MessageArchive(directory:directory,contacts:[])
        let requests=try await store.requestPackets(identity:me)
        XCTAssertEqual(requests.map(\.id),["dup"])
        let aside=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.contains("damaged-")}
        XCTAssertTrue(aside.isEmpty)
    }

    func testChatReceiptReferencesNeverFillUp() async throws {
        let store=ChatReceiptIndex(directory:directory)
        let root="o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
        let start=Date(timeIntervalSince1970:1000)
        for i in 0..<260 {
            try await store.rememberVerified(root:root,transactionID:String(format:"%064x",i),hex:nil,date:start.addingTimeInterval(Double(i)))
        }
        let saved=try await store.entries(root:root)
        XCTAssertEqual(saved.count,256)
        XCTAssertEqual(saved.first?.id,String(format:"%064x",259))
        XCTAssertFalse(saved.contains{$0.id==String(format:"%064x",0)})
    }
}

import XCTest
@testable import Paranoid

final class NearbyTests:XCTestCase {
    func testEveryBLEChunkSizePreservesMultiplePackets() throws {
        let a=Data(repeating:0x7b,count:4097),b=Data(repeating:0xab,count:65536)
        let wire=try NearbyFrameDecoder.encode(a)+NearbyFrameDecoder.encode(b)
        for size in [1,7,20,64,185,512] {
            var decoder=NearbyFrameDecoder(),received:[Data]=[]
            for start in stride(from:0,to:wire.count,by:size) {
                received += try decoder.feed(wire.subdata(in:start..<min(wire.count,start+size)))
            }
            XCTAssertEqual(received,[a,b],"Fragment size \(size)")
        }
    }
    func testRejectsInvalidLengthsAndOversizedATTFragment() throws {
        for header in [Data([0,0,0,0]),Data([0,16,0,1]),Data([255,255,255,255])] {
            var decoder=NearbyFrameDecoder();XCTAssertThrowsError(try decoder.feed(header))
        }
        var decoder=NearbyFrameDecoder();XCTAssertThrowsError(try decoder.feed(Data(repeating:0,count:513)))
        XCTAssertThrowsError(try NearbyFrameDecoder.encode(Data()))
        XCTAssertThrowsError(try NearbyFrameDecoder.encode(Data(repeating:0,count:NearbyFrameDecoder.limit+1)))
    }
    func testDisconnectDiscardsPartialFrame() throws {
        var decoder=NearbyFrameDecoder()
        XCTAssertTrue(try decoder.feed(Data([0,0,0,10,1,2])).isEmpty)
        decoder=NearbyFrameDecoder()
        let fresh=Data([3,4,5]);XCTAssertEqual(try decoder.feed(NearbyFrameDecoder.encode(fresh)),[fresh])
    }
    func testNearbyStoreSurvivesRestartAndDeduplicates() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let packet=ValidatedMessage(id:"test",senderID:"a",recipientID:"b",expires:UInt64(Date().timeIntervalSince1970*1000)+60000,data:Data("ciphertext".utf8))
        let store=NearbyPacketStore(directory:directory)
        try await store.save(packet);try await store.save(packet)
        let reloaded=try await NearbyPacketStore(directory:directory).packets()
        XCTAssertEqual(reloaded,[packet.data])
        try await store.clear();let empty=try await store.packets();XCTAssertTrue(empty.isEmpty)
    }
    func testArchiveCursorAtomicAndStaleCommitRejected() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let own=String(repeating:"a",count:64),store=MessageArchive(directory:directory,contacts:["sender"])
        let packet=MessageArchive.Packet(id:"one",contactID:"sender",received:true,date:Date(),envelope:Data("ciphertext".utf8))
        try await store.commit([packet],identity:own,after:0,cursor:7)
        let reopened=MessageArchive(directory:directory,contacts:["sender"])
        let cursor=try await reopened.cursor(identity:own),saved=try await reopened.packets(identity:own)
        XCTAssertEqual(cursor,7);XCTAssertEqual(saved.count,1)
        do{try await reopened.commit([],identity:own,after:0,cursor:8);XCTFail("Stale writer advanced cursor")}catch{}
        let still=try await reopened.cursor(identity:own);XCTAssertEqual(still,7)
    }
    func testInboxCursorRejectsBoolNegativeAndFraction() throws {
        for value:NSNumber in [NSNumber(value:true),NSNumber(value:-1),NSNumber(value:1.5)] {XCTAssertThrowsError(try MessageInbox.cursor(value))}
        XCTAssertEqual(try MessageInbox.cursor(NSNumber(value:42)),42)
    }
}

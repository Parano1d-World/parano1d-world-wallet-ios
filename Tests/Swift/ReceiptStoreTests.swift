import XCTest
@testable import Paranoid

final class ReceiptStoreTests:XCTestCase {
    private func withStore(_ body:(ReceiptStore) throws -> Void) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        try body(ReceiptStore(directory:directory))
    }
    func testEvidenceSurvivesReopeningWithoutImplyingVerification() throws {
        try withStore {store in
            let id=String(repeating:"a",count:64)
            XCTAssertNil(try store.load(id))
            try store.save(ReceiptInput(hex:"00ab",transactionID:id))
            XCTAssertEqual(try ReceiptStore(directory:store.directory).load(id)?.hex,"00ab")
            // Storage only returns raw input; only the node can verify it.
        }
    }
    func testRejectsTraversalCorruptionAndOversizedEvidence() throws {
        try withStore {store in
            XCTAssertThrowsError(try store.load("../pending"))
            let id=String(repeating:"b",count:64)
            let path=store.directory.appendingPathComponent(id+".receipt")
            try Data("invalid".utf8).write(to:path)
            XCTAssertThrowsError(try store.load(id))
            try Data(repeating:48,count:262145).write(to:path)
            XCTAssertThrowsError(try store.load(id))
        }
    }
}

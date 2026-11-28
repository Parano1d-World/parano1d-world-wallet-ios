import XCTest
@testable import Paranoid

private final class MemoryAppCode:AppCodeStorage {
    var bytes:Data?
    func read() throws -> Data? {bytes}
    func save(_ data:Data) throws {bytes=data}
    func remove() throws {bytes=nil}
}
final class AppLockTests:XCTestCase {
    func testCodeOptionsRejectWeakAndMalformedPins() throws {
        try AppCodeKind.six.validate("873920")
        try AppCodeKind.four.validate("8026")
        for code in ["123456","000000","87392","８７３９２０","87 920"] {XCTAssertThrowsError(try AppCodeKind.six.validate(code))}
        XCTAssertThrowsError(try AppCodeKind.password.validate("short"))
        try AppCodeKind.password.validate("a long private password")
    }
    func testFailureCounterSurvivesStoreRecreation() async throws {
        let memory=MemoryAppCode();let first=AppLockStore(storage:memory)
        try await first.configure("873920",kind:.six)
        do{try await first.verify("873921");XCTFail("Wrong PIN accepted")}catch{}
        let saved=try JSONDecoder().decode(AppCodeRecord.self,from:XCTUnwrap(memory.bytes))
        XCTAssertEqual(saved.attempts,1)
        let reopened=AppLockStore(storage:memory)
        try await reopened.verify("873920")
        let reset=try JSONDecoder().decode(AppCodeRecord.self,from:XCTUnwrap(memory.bytes))
        XCTAssertEqual(reset.attempts,0)
    }
    func testTenFailuresDisablePinEvenWhenCorrectUntilDeviceReset() async throws {
        let memory=MemoryAppCode();let store=AppLockStore(storage:memory)
        try await store.configure("873920",kind:.six)
        for attempt in 0..<10 {
            do{try await store.verify("873921",now:Date(timeIntervalSince1970:Double(2_000_000_000+attempt*7200)));XCTFail("Wrong PIN accepted")}catch{}
        }
        let saved=try JSONDecoder().decode(AppCodeRecord.self,from:XCTUnwrap(memory.bytes))
        XCTAssertEqual(saved.attempts,10)
        do{try await store.verify("873920",now:Date(timeIntervalSince1970:2_001_000_000));XCTFail("Lockout bypassed")}catch{}
    }
    func testErasureDefaultsOffAndOldRecordsDecodeSafely() async throws {
        let memory=MemoryAppCode();let store=AppLockStore(storage:memory)
        try await store.configure("873920",kind:.six)
        let enabled=try await store.erasureEnabled();XCTAssertFalse(enabled)
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(memory.bytes)) as? [String:Any])
        legacy.removeValue(forKey:"eraseOnTenFailures");legacy.removeValue(forKey:"erasePending");legacy.removeValue(forKey:"eraseCompleted")
        memory.bytes=try JSONSerialization.data(withJSONObject:legacy)
        let old=try await AppLockStore(storage:memory).erasureEnabled();XCTAssertFalse(old)
    }
    func testOptInErasesOnlyAfterTenthConfirmedWrongCodeAndRetriesInterruptedDeletion() async throws {
        let memory=MemoryAppCode()
        var eraseCalls=0
        let store=AppLockStore(storage:memory,eraseLocalSecret:{eraseCalls+=1})
        try await store.configure("873920",kind:.six)
        try await store.setErasureEnabled(true)
        for attempt in 0..<9 {
            do {try await store.verify("873921",now:Date(timeIntervalSince1970:Double(2_000_000_000+attempt*7200)));XCTFail("Wrong PIN accepted")}catch{}
        }
        XCTAssertEqual(eraseCalls,0)
        do {try await store.verify("873921",now:Date(timeIntervalSince1970:2_000_100_000));XCTFail("Tenth wrong PIN accepted")}catch{}
        XCTAssertEqual(eraseCalls,1)
        let erased=try await store.erasureCompleted();XCTAssertTrue(erased)
        try await store.completePendingErasure()
        XCTAssertEqual(eraseCalls,1)

        let retryMemory=MemoryAppCode();var retries=0
        let interrupted=AppLockStore(storage:retryMemory,eraseLocalSecret:{retries+=1;if retries==1 {throw AppFailure("temporary Keychain failure")}})
        try await interrupted.configure("873920",kind:.six);try await interrupted.setErasureEnabled(true)
        for attempt in 0..<10 {
            do {try await interrupted.verify("873921",now:Date(timeIntervalSince1970:Double(2_000_000_000+attempt*7200)))}catch{}
        }
        let pending=try JSONDecoder().decode(AppCodeRecord.self,from:XCTUnwrap(retryMemory.bytes))
        XCTAssertTrue(pending.erasePending)
        try await interrupted.completePendingErasure()
        XCTAssertEqual(retries,2)
        let retried=try await interrupted.erasureCompleted();XCTAssertTrue(retried)
    }
    func testCorruptRecordFailsClosed() async throws {
        let memory=MemoryAppCode();memory.bytes=Data("damaged".utf8)
        let store=AppLockStore(storage:memory)
        do{_ = try await store.kind();XCTFail("Corruption treated as no app lock")}catch{}
        XCTAssertEqual(memory.bytes,Data("damaged".utf8))
    }
}

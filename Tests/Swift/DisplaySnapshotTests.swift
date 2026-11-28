import XCTest
@testable import Paranoid

final class DisplaySnapshotTests:XCTestCase {
    private let owner="o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
    func testRelaunchNetworkIsolationAndOlderWriteProtection() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let chain=String(repeating:"a",count:64)
        let now=Date()
        let first=DisplaySnapshotStore(directory:directory)
        try await first.save(kind:"assets",owner:owner,chain:chain,payload:["value":"new"],date:now)
        try await first.save(kind:"assets",owner:owner,chain:chain,payload:["value":"old"],date:now.addingTimeInterval(-60))
        let reopened=DisplaySnapshotStore(directory:directory)
        let saved=try await reopened.load(kind:"assets",owner:owner,chain:chain)
        XCTAssertEqual(saved?.payload["value"] as? String,"new")
        let other=try await reopened.load(kind:"assets",owner:owner,chain:String(repeating:"b",count:64))
        XCTAssertNil(other)
        let history=try await reopened.load(kind:"history",owner:owner,chain:chain)
        XCTAssertNil(history)
    }
}

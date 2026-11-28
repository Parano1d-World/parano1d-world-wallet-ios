import XCTest
@testable import Paranoid

final class NodeRefreshTests: XCTestCase {
    func testSuccessfulBalanceDoesNotSynchronizeTwice() throws {
        var operations:[String]=[]
        let result=try NodeRefresh.execute(["op":"wallet_balance","owner":"test-owner"]) { request in
            operations.append(request["op"] as! String)
            return ["amount_micronoid":"123","native_state_error":"snapshot peer unavailable"]
        }
        XCTAssertEqual(operations,["wallet_balance"])
        XCTAssertEqual(result["amount_micronoid"] as? String,"123")
        XCTAssertEqual(result["native_state_error"] as? String,"snapshot peer unavailable")
    }
    func testDiscoveryFailureStillSynchronizesNFTState() throws {
        var operations:[String]=[]
        let result=try NodeRefresh.execute(["op":"wallet_balance","owner":"test-owner","data_dir":"test-dir"]) { request in
            let operation=request["op"] as! String
            operations.append(operation)
            if operation == "wallet_balance" {throw AppFailure("discovery unavailable")}
            XCTAssertNil(request["owner"])
            XCTAssertEqual(request["data_dir"] as? String,"test-dir")
            return ["native_state":["height":100]]
        }
        XCTAssertEqual(operations,["wallet_balance","sync_once"])
        XCTAssertEqual(result["balance_error"] as? String,"discovery unavailable")
        XCTAssertNotNil(result["native_state"])
    }
    func testChainSyncFailureInsideBalanceIsNotRepeated() {
        var operations:[String]=[]
        XCTAssertThrowsError(try NodeRefresh.execute(["op":"wallet_balance","owner":"test-owner"]) { request in
            operations.append(request["op"] as! String)
            throw AppFailure(NodeRefresh.syncFailurePrefix+"No mainnet candidate passed verification. Last failure: proof: BadParentHash")
        }) { error in
            XCTAssertEqual(error.localizedDescription,"No mainnet candidate passed verification. Last failure: proof: BadParentHash")
        }
        XCTAssertEqual(operations,["wallet_balance"])
    }
    func testStateOnlyFailureIsNotRetried() {
        var calls=0
        XCTAssertThrowsError(try NodeRefresh.execute(["op":"sync_once"]) { _ in
            calls += 1;throw AppFailure("offline")
        })
        XCTAssertEqual(calls,1)
    }
    func testFailedFallbackDoesNotManufactureStateOrBalance() {
        XCTAssertThrowsError(try NodeRefresh.execute(["op":"wallet_balance"]) { _ in throw AppFailure("offline") })
    }
}

import XCTest
@testable import Paranoid
final class HistoryRowsTests:XCTestCase {
    func testPartialRefreshRetainsOlderTransaction() {
        let a=String(repeating:"a",count:64),b=String(repeating:"b",count:64)
        let result=HistoryRows.merge([["txid":a,"timestamp":1],["txid":b,"timestamp":2]],[["txid":b,"timestamp":3]])
        XCTAssertEqual(result.count,2)
        XCTAssertEqual(result.first?["txid"] as? String,b)
    }
    func testMergeDoesNotDuplicateLocalAndExplorerTransaction() {
        let id=String(repeating:"c",count:64)
        let result=HistoryRows.merge([["txid":id,"height":123]],[["txid":id,"local_status":"Authorized locally"]])
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result.first?["height"] as? Int,123)
        XCTAssertEqual(result.first?["local_status"] as? String,"Authorized locally")
    }
    func testDoesNotInferNFTSaleFromReceiptOfFunds() {
        XCTAssertEqual(HistoryRows.title(["address_received_micronoid":"1000000","address_spent_micronoid":"0"]),"NOID received")
    }
    func testAssetSelectionSurvivesStorageRelocation() {
        let a=NativeItem(fields:["type":"nft","collection_id":"collection","serial":"42","root":"old","slot_index":"1"])
        let b=NativeItem(fields:["type":"nft","collection_id":"collection","serial":"42","root":"new","slot_index":"9"])
        XCTAssertEqual(a.sendSelectionID,b.sendSelectionID)
        XCTAssertNotEqual(a.id,b.id)
    }
    func testClearTransferSummaryUsesExactAmountAndHonorsPrivacy() {
        let sent: [String:Any] = ["local_kind":"NOID transfer","local_amount":"1000000"]
        XCTAssertEqual(HistoryRows.summary(sent),"Sent 1 NOID")
        XCTAssertEqual(HistoryRows.summary(sent,hideAmounts:true),"Sent NOID")
        XCTAssertEqual(HistoryRows.summary(["address_received_micronoid":"1000000","address_spent_micronoid":"0"]),"Received 1 NOID")
        // Gross input spend includes change and fees, not the recipient's exact amount.
        XCTAssertEqual(HistoryRows.summary(["address_received_micronoid":"9000000","address_spent_micronoid":"10000000"]),"NOID sent")
    }
    func testNativeTransferLabelsDoNotClaimACompletedSale() {
        XCTAssertEqual(HistoryRows.summary(["local_kind":"NFT sent","serial":"42"]),"Sent NFT #42")
        XCTAssertEqual(HistoryRows.summary(["local_kind":"Token sent"]),"Sent native token")
        XCTAssertEqual(HistoryRows.summary(["local_kind":"Native asset transaction"]),"Native asset transaction")
    }
}

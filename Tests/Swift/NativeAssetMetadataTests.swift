import XCTest
@testable import Paranoid

final class NativeAssetMetadataTests:XCTestCase {
    func testTokenArtworkFollowsExactAssetID() {
        let a=String(repeating:"a",count:64),b=String(repeating:"b",count:64),hash=String(repeating:"c",count:64)
        let owned=[NativeItem(fields:["type":"token","asset_id":a]),NativeItem(fields:["type":"token","asset_id":b])]
        let market=[NativeItem(fields:["type":"dex","asset_id":a,"metadata_hash":hash])]
        let result=NativeAssetMetadata.attach(to:owned,markets:market)
        XCTAssertEqual(result[0].text("metadata_hash"),hash)
        XCTAssertEqual(result[1].text("metadata_hash"),"")
    }
    func testRejectsMalformedArtworkIdentity() {
        let asset=String(repeating:"a",count:64)
        let owned=[NativeItem(fields:["type":"token","asset_id":asset])]
        let market=[NativeItem(fields:["type":"curve","asset_id":asset,"metadata_hash":"missing"])]
        XCTAssertEqual(NativeAssetMetadata.attach(to:owned,markets:market)[0].text("metadata_hash"),"")
    }
}

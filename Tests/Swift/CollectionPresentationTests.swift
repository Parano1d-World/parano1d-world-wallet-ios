import XCTest
@testable import Paranoid
final class CollectionPresentationTests: XCTestCase {
    func testCountsUseIssuedNotMaximumAndDoNotInventTotal() {
        let definition = NativeItem(fields:["issued_items":"250","maximum_items":"1000"])
        XCTAssertEqual(CollectionPresentation.ownership(count:16,collection:definition),"16 owned of 250 issued")
        XCTAssertEqual(CollectionPresentation.ownership(count:16,collection:nil),"16 owned · total unavailable")
        XCTAssertEqual(CollectionPresentation.ownership(count:251,collection:definition),"251 owned · total unavailable")
    }
    func testNameUsesCollectionMetadataNotRepresentativeNFT() {
        let collection = NativeItem(fields:["collection_id":"abc","metadata_hash":"collection-hash"])
        XCTAssertEqual(CollectionPresentation.name(id:"abc",collections:[collection],names:["collection-hash":"Parano1ds","nft-hash":"Parano1d #16"]),"Parano1ds")
    }
    func testListingPriceIsExplicitAndMissingPriceIsNotZero() {
        XCTAssertEqual(CollectionPresentation.sale(NativeItem(fields:["seller":"owner","ask_micronoid":"15500000"])),"Listed for sale · 15.5 NOID")
        XCTAssertEqual(CollectionPresentation.sale(NativeItem(fields:["seller":"owner"])),"Listed for sale · price unavailable")
        XCTAssertNil(CollectionPresentation.sale(NativeItem(fields:["owner":"owner"])))
    }
}

import XCTest
@testable import Paranoid
final class CollectionSearchTests:XCTestCase {
    func testNameCaseSpacingAndAccents() {
        XCTAssertTrue(CollectionSearch.matches(query:"  PARANOID   café \n",name:"Paranoid Café Apes",id:"abcdef1234"))
        XCTAssertTrue(CollectionSearch.matches(query:"cafe",name:"Paranoid Café Apes",id:"abcdef1234"))
    }
    func testPartialAndFullIdentityWithoutMetadata() {
        XCTAssertTrue(CollectionSearch.matches(query:"CDEF",name:"",id:"abcdef1234"))
        XCTAssertTrue(CollectionSearch.matches(query:" ABCDEF1234 ",name:"",id:"abcdef1234"))
        XCTAssertFalse(CollectionSearch.matches(query:"apes",name:"",id:"abcdef1234"))
    }
    func testEmptyAndMixedTerms() {
        XCTAssertTrue(CollectionSearch.matches(query:" \n ",name:"Apes",id:"abcdef1234"))
        XCTAssertTrue(CollectionSearch.matches(query:"apes 1234",name:"Paranoid Apes",id:"abcdef1234"))
        XCTAssertFalse(CollectionSearch.matches(query:"apes dogs",name:"Paranoid Apes",id:"abcdef1234"))
    }
}

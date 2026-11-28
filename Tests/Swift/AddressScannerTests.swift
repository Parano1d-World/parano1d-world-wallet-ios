import XCTest
@testable import Paranoid
final class AddressScannerTests:XCTestCase {
    let address="o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
    func testAcceptsOnlyChecksummedAddress(){XCTAssertEqual(ScannedAddress.parse(address),address);XCTAssertEqual(ScannedAddress.parse(" \n"+address+"\n"),address);XCTAssertNil(ScannedAddress.parse(String(address.dropLast())+"x"))}
    func testRejectsURLsAndEmbeddedCommands(){for text in ["https://example.com/"+address,"javascript:alert(1)",address+"?amount=100","parano1d:"+address,String(repeating:"a",count:257)]{XCTAssertNil(ScannedAddress.parse(text))}}
}

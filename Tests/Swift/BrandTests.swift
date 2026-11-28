import XCTest
import UIKit
@testable import Paranoid

final class BrandTests: XCTestCase {
    func testInstalledDisplayName() {
        XCTAssertEqual(Bundle(for: WalletState.self).object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Parano1d Wallet")
    }
    func testOfficialBrandIsPackagedInApplication() {
        let bundle = Bundle(for: WalletState.self)
        XCTAssertNotNil(UIImage(named: "Brand", in: bundle, compatibleWith: nil))
    }
}

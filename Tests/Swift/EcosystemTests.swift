import XCTest
@testable import Paranoid

final class EcosystemTests: XCTestCase {
    func testOfficialDirectoryGroupsOnlyValidHTTPSProjects() throws {
        let payload = """
        {"version":1,"categories":[{"id":"apps","label":"Apps & trading"}],"projects":[
          {"id":"one","category":"apps","name":"NO ONE","url":"https://noone.parano1d.org/","description":"Game"},
          {"id":"bad","category":"apps","name":"Bad","url":"http://example.org/"},
          {"id":"one","category":"apps","name":"Duplicate","url":"https://elsewhere.example/"}]}
        """
        let parsed = try EcosystemDirectoryParser.parse(Data(payload.utf8))
        XCTAssertEqual(parsed.categories.map(\.label), ["Apps & trading"])
        XCTAssertEqual(parsed.sites.map(\.name), ["NO ONE"])
        XCTAssertEqual(parsed.sites.first?.summary, "Game")
        XCTAssertEqual(BrowsingOrigin.origin(parsed.sites.first?.url), "https://noone.parano1d.org")
    }

    func testInvalidDirectoryFailsWithoutPartialProjects() {
        let payload = Data("{\"version\":2,\"categories\":[],\"projects\":[]}".utf8)
        XCTAssertThrowsError(try EcosystemDirectoryParser.parse(payload))
        XCTAssertNil(BrowsingOrigin.origin(URL(string:"https://user@noone.parano1d.org")))
        XCTAssertNil(BrowsingOrigin.origin(URL(string:"https://noone.parano1d.org:8443")))
    }
}

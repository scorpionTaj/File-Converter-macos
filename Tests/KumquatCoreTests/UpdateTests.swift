import XCTest
@testable import KumquatCore

final class UpdateTests: XCTestCase {
    func release(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> ReleaseInfo {
        ReleaseInfo(tagName: tag, htmlURL: URL(string: "https://example.com/\(tag)")!, prerelease: prerelease, draft: draft)
    }

    func testVersionParsingAndOrder() throws {
        let version = try XCTUnwrap(SemanticVersion("v1.2.3"))
        XCTAssertEqual(version.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("0.4")?.description, "0.4.0")
        XCTAssertNil(SemanticVersion("nightly"))
        XCTAssertNil(SemanticVersion("1.x"))
        XCTAssertLessThan(SemanticVersion("0.3.1")!, SemanticVersion("0.4.0")!)
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("0.10.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-beta.2")!, SemanticVersion("1.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-beta.2")!, SemanticVersion("1.0.0-beta.10")!)
        XCTAssertEqual(SemanticVersion("v0.3.1")!, SemanticVersion("0.3.1")!)
    }

    func testNewestIgnoresNightlyDraftsAndOlder() {
        let releases = [release("nightly", prerelease: true), release("v0.3.0"), release("v0.3.1"),
                        release("v0.5.0", draft: true), release("v0.4.0-beta.1", prerelease: true)]
        XCTAssertNil(UpdateChecker.newest(in: releases, than: "0.3.1", includePrereleases: false))
        XCTAssertEqual(UpdateChecker.newest(in: releases, than: "0.3.0", includePrereleases: false)?.tagName, "v0.3.1")
        XCTAssertEqual(UpdateChecker.newest(in: releases, than: "0.3.1", includePrereleases: true)?.tagName, "v0.4.0-beta.1")
    }

    func testDecodesGitHubJSON() throws {
        let json = #"""
        [{"tag_name":"v0.4.0","name":"Kumquat 0.4.0","body":"Notes","html_url":"https://github.com/x/y/releases/tag/v0.4.0",
          "prerelease":false,"draft":false,
          "assets":[{"name":"SHA256SUMS.txt","size":10,"browser_download_url":"https://github.com/x/y/releases/download/v0.4.0/SHA256SUMS.txt"},
                    {"name":"Kumquat-0.4.0.dmg","size":3700000,"browser_download_url":"https://github.com/x/y/releases/download/v0.4.0/Kumquat-0.4.0.dmg"}]}]
        """#
        let releases = try JSONDecoder().decode([ReleaseInfo].self, from: Data(json.utf8))
        XCTAssertEqual(releases.first?.version?.description, "0.4.0")
        XCTAssertEqual(releases.first?.diskImage?.name, "Kumquat-0.4.0.dmg")
    }
}

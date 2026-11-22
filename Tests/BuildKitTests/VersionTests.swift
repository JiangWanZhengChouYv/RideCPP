import XCTest
@testable import BuildKit

final class VersionTests: XCTestCase {

    func testSemanticVersionComparison() {
        XCTAssertTrue(SemanticVersion("1.0.0")! < SemanticVersion("1.0.1")!)
        XCTAssertTrue(SemanticVersion("1.0.1")! < SemanticVersion("1.1.0")!)
        XCTAssertTrue(SemanticVersion("1.9.0")! < SemanticVersion("1.10.0")!)
        XCTAssertTrue(SemanticVersion("1.0.0")! > SemanticVersion("0.9.9")!)
        XCTAssertFalse(SemanticVersion("1.0.0")! < SemanticVersion("1.0.0")!)
    }

    func testParsesBuildNumberAndIgnoresPrefix() {
        let version = SemanticVersion("v1.2.3 (42)")
        XCTAssertEqual(version?.major, 1)
        XCTAssertEqual(version?.minor, 2)
        XCTAssertEqual(version?.patch, 3)
        XCTAssertEqual(version?.build, 42)
    }

    func testToleratesMissingComponents() {
        XCTAssertEqual(SemanticVersion("1.0"), SemanticVersion("1.0.0"))
        XCTAssertNil(SemanticVersion("not a version"))
    }

    func testIsNewerComparesBuildNumbers() {
        XCTAssertTrue(SemanticVersion.isNewer(latest: "1.0.1", build: 1, than: "1.0.1", build: 0))
        XCTAssertFalse(SemanticVersion.isNewer(latest: "1.0.1", build: 1, than: "1.0.1", build: 1))
        XCTAssertTrue(SemanticVersion.isNewer(latest: "1.1.0", build: 0, than: "1.0.9", build: 99))
    }
}

final class UpdateCheckerTests: XCTestCase {

    private func payload(tag: String, assets: [(String, String)] = []) -> Data {
        let assetJSON = assets.map { "{\"name\": \"\($0.0)\", \"browser_download_url\": \"\($0.1)\"}" }
            .joined(separator: ",")
        let json = """
        {"tag_name": "\(tag)", "name": "RideCPP \(tag)", "html_url": "https://github.com/o/r/releases/tag/\(tag)",
         "body": "notes", "published_at": "2026-11-22T12:00:00Z", "assets": [\(assetJSON)]}
        """
        return Data(json.utf8)
    }

    func testNewerReleaseIsReported() async throws {
        let data = payload(tag: "1.0.1 (1)", assets: [("RideCPP-1.0.1.dmg", "https://example.com/RideCPP-1.0.1.dmg")])
        let release = try await UpdateChecker.checkForUpdate(current: SemanticVersion("1.0.0 (1)")!,
                                                             transport: { _ in data })
        XCTAssertEqual(release?.tag, "1.0.1 (1)")
        XCTAssertEqual(release?.downloadURL?.absoluteString, "https://example.com/RideCPP-1.0.1.dmg")
        XCTAssertEqual(release?.notes, "notes")
        XCTAssertNotNil(release?.publishedAt)
    }

    func testSameVersionIsNotAnUpdate() async throws {
        let data = payload(tag: "1.0.0 (1)")
        let release = try await UpdateChecker.checkForUpdate(current: SemanticVersion("1.0.0 (1)")!,
                                                             transport: { _ in data })
        XCTAssertNil(release)
    }

    func testHigherBuildNumberOfSameVersionIsAnUpdate() async throws {
        let data = payload(tag: "1.0.0 (2)")
        let release = try await UpdateChecker.checkForUpdate(current: SemanticVersion("1.0.0 (1)")!,
                                                             transport: { _ in data })
        XCTAssertEqual(release?.tag, "1.0.0 (2)")
    }

    func testOlderReleaseIsNotAnUpdate() async throws {
        let data = payload(tag: "0.9.0 (9)")
        let release = try await UpdateChecker.checkForUpdate(current: SemanticVersion("1.0.0 (1)")!,
                                                             transport: { _ in data })
        XCTAssertNil(release)
    }

    func testMalformedPayloadThrows() async {
        do {
            _ = try await UpdateChecker.checkForUpdate(current: SemanticVersion("1.0.0")!,
                                                       transport: { _ in Data("not json".utf8) })
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is UpdateChecker.UpdateError)
        }
    }

    func testTransportErrorPropagates() async {
        struct Boom: Error {}
        do {
            _ = try await UpdateChecker.checkForUpdate(current: SemanticVersion("1.0.0")!,
                                                       transport: { _ in throw Boom() })
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}

final class ReleaseLabelTests: XCTestCase {
    func testVersionLabelStripsTagPrefixAndKeepsBuild() {
        let release = ReleaseInfo(tag: "v1.0.0(2)", name: "", notes: "",
                                  htmlURL: URL(string: "https://example.com")!,
                                  downloadURL: nil, publishedAt: nil)
        XCTAssertEqual(release.versionLabel, "1.0.0 (2)")
    }

    func testVersionLabelFallsBackToRawTag() {
        let release = ReleaseInfo(tag: "nightly", name: "", notes: "",
                                  htmlURL: URL(string: "https://example.com")!,
                                  downloadURL: nil, publishedAt: nil)
        XCTAssertEqual(release.versionLabel, "nightly")
    }
}

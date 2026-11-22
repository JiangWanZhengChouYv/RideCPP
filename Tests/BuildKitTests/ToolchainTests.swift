import XCTest
@testable import BuildKit

final class ToolchainTests: XCTestCase {

    func testDiscoversAtLeastTheSystemClang() throws {
        let compilers = Toolchain.discoverCompilers()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang++") else {
            throw XCTSkip("No /usr/bin/clang++ on this machine")
        }
        XCTAssertFalse(compilers.isEmpty)
        XCTAssertTrue(compilers.contains { $0.path == "/usr/bin/clang++" })
    }

    func testClassifiesAppleClang() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang++") else {
            throw XCTSkip("No /usr/bin/clang++")
        }
        let info = try XCTUnwrap(Toolchain.inspect(path: "/usr/bin/clang++"))
        XCTAssertEqual(info.family, .clang)
        XCTAssertEqual(info.displayName, "clang++")
        XCTAssertFalse(info.version.isEmpty)
        XCTAssertTrue(info.menuTitle.contains("clang"))
    }

    func testClassifiesGNUCompilerWhenPresent() throws {
        let gccPaths = ["/opt/homebrew/bin/g++-16", "/opt/homebrew/bin/g++-15",
                        "/opt/homebrew/bin/g++-14", "/usr/local/bin/g++-13"]
        guard let path = gccPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let info = Toolchain.inspect(path: path) else {
            throw XCTSkip("No Homebrew GNU g++ installed")
        }
        XCTAssertEqual(info.family, .gcc)
        XCTAssertTrue(info.version.contains("."))
    }

    func testAppleClangAliasDetection() {
        // /usr/bin/g++ is a symlink to Apple clang on macOS.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/g++") else { return }
        if let output = Toolchain.versionDescription(of: "/usr/bin/g++") {
            XCTAssertTrue(output.contains("Apple clang") || output.contains("GNU"))
        }
    }

    func testMissingCompilerReturnsNil() {
        XCTAssertNil(Toolchain.inspect(path: "/definitely/not/here/clang++"))
    }

    func testClangFormatLookupDoesNotCrashWhenMissing() {
        // Either a path or nil is acceptable; the call must simply not crash.
        let found = Toolchain.findClangFormat(preferredPath: "/nope/clang-format")
        if let found {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: found))
        }
    }

    func testPreferredClangFormatWins() throws {
        guard let existing = Toolchain.findClangFormat() else {
            throw XCTSkip("clang-format not installed")
        }
        XCTAssertEqual(Toolchain.findClangFormat(preferredPath: existing), existing)
    }
}

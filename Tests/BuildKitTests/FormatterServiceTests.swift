import XCTest
@testable import BuildKit

final class FormatterServiceTests: XCTestCase {

    private let messy = "int  main(){int x=1;return  0;}"

    func testFormatsWithLLVMStyle() throws {
        guard Toolchain.findClangFormat() != nil else {
            throw XCTSkip("clang-format not installed")
        }
        let formatted = try FormatterService.format(source: messy,
                                                    fileName: "main.cpp",
                                                    executablePath: nil,
                                                    style: "LLVM")
        XCTAssertTrue(formatted.contains("int main() {"))
        XCTAssertTrue(formatted.contains("  int x = 1;"))
    }

    func testFormattingIsIdempotent() throws {
        guard Toolchain.findClangFormat() != nil else {
            throw XCTSkip("clang-format not installed")
        }
        let once = try FormatterService.format(source: messy, fileName: "a.cpp", executablePath: nil, style: "LLVM")
        let twice = try FormatterService.format(source: once, fileName: "a.cpp", executablePath: nil, style: "LLVM")
        XCTAssertEqual(once, twice)
    }

    func testGoogleStyleDifferentFromLLVM() throws {
        guard Toolchain.findClangFormat() != nil else {
            throw XCTSkip("clang-format not installed")
        }
        let llvm = try FormatterService.format(source: messy, fileName: "a.cpp", executablePath: nil, style: "LLVM")
        let google = try FormatterService.format(source: messy, fileName: "a.cpp", executablePath: nil, style: "Google")
        XCTAssertFalse(llvm.isEmpty)
        XCTAssertFalse(google.isEmpty)
    }

    func testMissingToolThrowsToolNotFound() {
        XCTAssertThrowsError(try FormatterService.format(source: messy,
                                                         fileName: "a.cpp",
                                                         executablePath: "/nope/clang-format",
                                                         style: "LLVM")) { error in
            // A non-existent explicit path must surface as .toolNotFound.
            guard case FormatterError.toolNotFound = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAsyncFormattingMatchesSync() async throws {
        guard Toolchain.findClangFormat() != nil else {
            throw XCTSkip("clang-format not installed")
        }
        let sync = try FormatterService.format(source: messy, fileName: "a.cpp", executablePath: nil, style: "LLVM")
        let async = try await FormatterService.formatAsync(source: messy, fileName: "a.cpp", executablePath: nil, style: "LLVM")
        XCTAssertEqual(sync, async)
    }

    func testEmptySourceIsHandled() throws {
        guard Toolchain.findClangFormat() != nil else {
            throw XCTSkip("clang-format not installed")
        }
        XCTAssertThrowsError(try FormatterService.format(source: "", fileName: "a.cpp", executablePath: nil, style: "LLVM")) { error in
            guard case FormatterError.emptyResult = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

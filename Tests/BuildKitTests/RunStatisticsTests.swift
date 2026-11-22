import XCTest
@testable import BuildKit

final class RunStatisticsTests: XCTestCase {

    func testDurationFormatting() {
        XCTAssertEqual(RunStatisticsFormatter.duration(0), "0 ms")
        XCTAssertEqual(RunStatisticsFormatter.duration(0.012), "12 ms")
        XCTAssertEqual(RunStatisticsFormatter.duration(0.999), "999 ms")
        XCTAssertEqual(RunStatisticsFormatter.duration(1.0), "1.00 s")
        XCTAssertEqual(RunStatisticsFormatter.duration(2.345), "2.35 s")
    }

    func testMemoryFormatting() {
        XCTAssertEqual(RunStatisticsFormatter.memory(512 * 1024), "0.5 MB")
        XCTAssertEqual(RunStatisticsFormatter.memory(3 * 1024 * 1024 + 400 * 1024), "3.4 MB")
        XCTAssertEqual(RunStatisticsFormatter.memory(1024 * 1024 * 1024), "1.00 GB")
    }

    func testSmallMemoryFallsBackToKilobytes() {
        XCTAssertEqual(RunStatisticsFormatter.memory(32 * 1024), "32 KB")
    }

    func testNegativeDurationIsNotPrinted() {
        XCTAssertEqual(RunStatisticsFormatter.duration(-1), "—")
    }

    func testOverflowedDurationIsNotPrinted() {
        // What a UInt64 underflow used to produce.
        XCTAssertEqual(RunStatisticsFormatter.duration(18_446_744_073.71), "—")
        XCTAssertEqual(RunStatisticsFormatter.duration(.infinity), "—")
        XCTAssertEqual(RunStatisticsFormatter.duration(.nan), "—")
    }
}

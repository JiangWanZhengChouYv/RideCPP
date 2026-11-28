import XCTest
@testable import BuildKit

/// Automatic checks must notice a release the same day, without exhausting the
/// GitHub rate limit.
final class UpdateScheduleTests: XCTestCase {

    /// 24 checks a day is far below GitHub's 60-per-hour limit for one client,
    /// and means a release published in the morning is not missed until evening.
    func testAutomaticCheckIntervalIsAtMostAnHour() {
        XCTAssertLessThanOrEqual(UpdateThrottle.interval, 60 * 60,
                                 "a six-hour window meant releases waited half a day")
        XCTAssertGreaterThan(UpdateThrottle.interval, 60,
                             "checking every minute would exhaust the API limit")
    }

    func testChecksPerDayStayWellInsideTheLimit() {
        let perDay = (24 * 60 * 60) / UpdateThrottle.interval
        XCTAssertLessThanOrEqual(perDay, 24, "at most one check an hour")
        XCTAssertLessThan(perDay, 60, "must stay under GitHub's hourly allowance")
    }

    /// A check that ran recently must be skipped, so launches do not pile up.
    func testRecentCheckBlocksAnother() {
        let now = Date().timeIntervalSince1970
        // Checked a minute ago: not due.
        XCTAssertFalse(UpdateThrottle.shouldCheck(lastCheck: now - 60, now: now))
        XCTAssertFalse(UpdateThrottle.shouldCheck(lastCheck: now - 30 * 60, now: now))
        // Past the window: due again.
        XCTAssertTrue(UpdateThrottle.shouldCheck(lastCheck: now - 2 * 60 * 60, now: now))
        // Never checked before.
        XCTAssertTrue(UpdateThrottle.shouldCheck(lastCheck: 0, now: now))
    }
}

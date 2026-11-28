import Foundation

/// How often the app may look for a new release on its own.
///
/// Kept in `BuildKit` so the cadence can be tested without a running app: it is
/// the difference between noticing a release the same day and noticing it a day
/// later, and it interacts with a hard external constraint (GitHub's API limit).
public enum UpdateThrottle {

    /// Minimum time between automatic checks.
    ///
    /// One hour is 24 requests a day. That is far inside GitHub's 60-per-hour
    /// limit for unauthenticated clients, and short enough that a release
    /// published during the day is seen the same day. The previous six hours
    /// meant up to a quarter of a day of delay.
    public static let interval: TimeInterval = 60 * 60

    /// Whether an automatic check is due.
    ///
    /// `lastCheck == 0` means one has never run.
    public static func shouldCheck(lastCheck: TimeInterval, now: TimeInterval) -> Bool {
        guard lastCheck > 0 else { return true }
        let elapsed = now - lastCheck
        // A clock that moved backwards is treated as due rather than as a
        // reason never to check again.
        if elapsed < 0 { return true }
        return elapsed >= interval
    }
}

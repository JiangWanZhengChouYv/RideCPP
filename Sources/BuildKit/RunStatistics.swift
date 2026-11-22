import Foundation

/// Formats run statistics for display in the console.
public enum RunStatisticsFormatter {

    /// "12 ms" / "1.24 s"
    ///
    /// Guards against nonsensical values: a measurement that overflows, goes
    /// negative or exceeds a day is reported as "—" rather than printed as a
    /// 18-billion-second runtime.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 86_400 else { return "—" }
        if seconds < 1 {
            return String(format: "%.0f ms", max(0, seconds) * 1000)
        }
        return String(format: "%.2f s", seconds)
    }

    /// "512 KB" / "3.4 MB" / "1.20 GB"
    public static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 1024 {
            return String(format: "%.2f GB", megabytes / 1024)
        }
        if megabytes >= 0.1 {
            return String(format: "%.1f MB", megabytes)
        }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

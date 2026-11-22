import Foundation

/// A compiler the IDE can invoke.
public struct CompilerInfo: Identifiable, Hashable, Sendable {
    public enum Family: String, Sendable {
        case clang
        case gcc

        public var displayName: String {
            switch self {
            case .clang: return "clang"
            case .gcc: return "gcc"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let displayName: String
    public let version: String
    public let family: Family

    public init(path: String, displayName: String, version: String, family: Family) {
        self.path = path
        self.displayName = displayName
        self.version = version
        self.family = family
    }

    /// e.g. "clang++ (Apple clang 21.0.0)"
    public var menuTitle: String { "\(displayName) — \(version)" }
}

/// Locates compilers and clang-format, and describes the environment.
public enum Toolchain {

    /// Compilers found on this machine, most preferred first.
    public static func discoverCompilers() -> [CompilerInfo] {
        var candidates: [String] = []
        candidates.append(contentsOf: [
            "/usr/bin/clang++",
            "/opt/homebrew/opt/llvm/bin/clang++",
            "/usr/local/opt/llvm/bin/clang++"
        ])
        // Homebrew GCC installs versioned binary names, e.g. g++-16.
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            candidates.append(contentsOf: versionedBinaries(in: directory, prefix: "g++"))
        }
        candidates.append(contentsOf: ["/usr/bin/g++", "/usr/bin/c++"])

        var seen = Set<String>()
        var result: [CompilerInfo] = []
        for path in candidates {
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let info = inspect(path: path) else { continue }
            result.append(info)
        }
        return result
    }

    /// Reads `--version` for a compiler path and classifies it.
    public static func inspect(path: String) -> CompilerInfo? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        guard let output = runAndCapture(path: path, arguments: ["--version"], timeout: 5) else { return nil }
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
        let lower = firstLine.lowercased()
        let family: CompilerInfo.Family
        if lower.contains("clang") {
            family = .clang
        } else if lower.contains("gcc") || lower.contains("g++") || lower.contains("free software foundation") {
            family = .gcc
        } else {
            // Unknown but executable: treat as clang-like, which is the common case.
            family = lower.contains("apple") ? .clang : .gcc
        }
        let version = parseVersion(from: firstLine) ?? firstLine
        let name = (path as NSString).lastPathComponent
        return CompilerInfo(path: path, displayName: name, version: version, family: family)
    }

    /// True when the file at `path` is an Apple clang wrapper (like /usr/bin/g++).
    public static func isAppleClangAlias(path: String) -> Bool {
        guard let output = runAndCapture(path: path, arguments: ["--version"], timeout: 5) else { return false }
        return output.contains("Apple clang")
    }

    /// Finds clang-format, preferring an explicit path.
    public static func findClangFormat(preferredPath: String? = nil) -> String? {
        if let preferredPath, !preferredPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: preferredPath) {
            return preferredPath
        }
        let fixed = [
            "/opt/homebrew/opt/llvm/bin/clang-format",
            "/opt/homebrew/bin/clang-format",
            "/usr/local/opt/llvm/bin/clang-format",
            "/usr/local/bin/clang-format",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang-format",
            "/usr/bin/clang-format"
        ]
        for path in fixed where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // `xcrun -f clang-format` covers Xcode installations at other locations.
        if let output = runAndCapture(path: "/usr/bin/xcrun", arguments: ["-f", "clang-format"], timeout: 5) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: trimmed) { return trimmed }
        }
        return nil
    }

    /// A short description of an executable's version, for settings display.
    public static func versionDescription(of path: String) -> String? {
        guard let output = runAndCapture(path: path, arguments: ["--version"], timeout: 5) else { return nil }
        return output.split(separator: "\n").first.map(String.init)
    }

    // MARK: - Helpers

    static func runAndCapture(path: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private static func versionedBinaries(in directory: String, prefix: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { entry in
                guard entry.hasPrefix(prefix + "-") else { return false }
                let suffix = entry.dropFirst(prefix.count + 1)
                return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
            }
            .sorted { lhs, rhs in
                let l = Int(lhs.dropFirst(prefix.count + 1)) ?? 0
                let r = Int(rhs.dropFirst(prefix.count + 1)) ?? 0
                return l > r
            }
            .map { directory + "/" + $0 }
    }

    private static func parseVersion(from line: String) -> String? {
        if let range = line.range(of: #"(\d+\.\d+(\.\d+)?)"#, options: .regularExpression) {
            return String(line[range])
        }
        return nil
    }
}

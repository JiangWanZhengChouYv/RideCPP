import Foundation

/// An index of identifiers harvested from the C++ standard library headers that
/// the active toolchain actually ships.
///
/// Nothing here is a hand-written list of "useful names": the vocabulary is
/// whatever the installed SDK's headers contain, so the suggestions match the
/// code the user can really compile. Building the index takes ~0.2 s for the
/// ~3.5 MB of libc++ headers, so it happens once in the background at launch.
public final class HeaderSymbolIndex {

    /// Shared index used by the editor.
    public static let shared = HeaderSymbolIndex()

    /// Names found in the headers, with the header that declared each one.
    private var names: Set<String> = []
    /// Sorted once for stable, predictable suggestion order.
    private var sortedNames: [String] = []
    private let lock = NSLock()
    private var built = false
    private var buildStarted = false

    /// Directories that were actually scanned, for diagnostics and tests.
    public private(set) var scannedDirectories: [String] = []

    public init() {}

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return built
    }

    /// Number of vocabulary entries (0 until the index is built).
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sortedNames.count
    }

    /// Builds the index for `compilerPath` if it has not been built yet.
    ///
    /// Cheap to call repeatedly: subsequent calls (and concurrent ones) return
    /// immediately, and the work happens on a background queue.
    public func prepare(compilerPath: String?) {
        lock.lock()
        let alreadyStarted = buildStarted
        buildStarted = true
        lock.unlock()
        guard !alreadyStarted else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let directories = HeaderSymbolIndex.includeDirectories(for: compilerPath)
            let scan = HeaderSymbolIndex.scan(directories: directories)
            guard let self else { return }
            self.lock.lock()
            self.names = scan.names
            self.sortedNames = scan.names.sorted()
            self.scannedDirectories = directories
            self.built = true
            self.lock.unlock()
        }
    }

    /// Builds synchronously. Used by tests so results are deterministic.
    public func buildSynchronously(compilerPath: String?) {
        let directories = HeaderSymbolIndex.includeDirectories(for: compilerPath)
        let scan = HeaderSymbolIndex.scan(directories: directories)
        lock.lock()
        names = scan.names
        sortedNames = scan.names.sorted()
        scannedDirectories = directories
        built = true
        buildStarted = true
        lock.unlock()
    }

    /// All known names, sorted.
    public func allNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sortedNames
    }

    /// Names that start with `prefix`, case-insensitively, best first.
    ///
    /// Ordering: exact match, then a shorter name (so `int` beats `int64_t`),
    /// then alphabetical.
    public func names(withPrefix prefix: String, limit: Int = 40) -> [String] {
        let lowered = prefix.lowercased()
        guard !lowered.isEmpty else { return [] }
        lock.lock()
        let snapshot = sortedNames
        lock.unlock()
        guard !snapshot.isEmpty else { return [] }

        var matches: [String] = []
        for name in snapshot where name.lowercased().hasPrefix(lowered) {
            matches.append(name)
            if matches.count >= limit * 4 { break }
        }
        matches.sort { lhs, rhs in
            let lhsExact = lhs.lowercased() == lowered
            let rhsExact = rhs.lowercased() == lowered
            if lhsExact != rhsExact { return lhsExact }
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs < rhs
        }
        return Array(matches.prefix(limit))
    }

    // MARK: - Discovery

    /// Include directories the compiler itself reports, which is the only
    /// reliable answer across Xcode versions and Homebrew GCC installs.
    public static func includeDirectories(for compilerPath: String?) -> [String] {
        let compiler = compilerPath ?? "/usr/bin/clang++"
        // Ask the compiler: `-E -v` prints its search list on stderr.
        if let output = run(compiler, arguments: ["-x", "c++", "-E", "-v", "-"]) {
            let directories = parseSearchList(output)
            if !directories.isEmpty { return directories }
        }
        // Fallback: the active developer directory's libc++ headers.
        if let sdk = run("/usr/bin/xcrun", arguments: ["--show-sdk-path"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty {
            let candidate = sdk + "/usr/include/c++/v1"
            if FileManager.default.fileExists(atPath: candidate) { return [candidate] }
        }
        return []
    }

    /// Extracts paths from the `#include <...> search starts here:` block.
    public static func parseSearchList(_ output: String) -> [String] {
        var directories: [String] = []
        var inList = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#include <...> search starts here") {
                inList = true
                continue
            }
            if line.hasPrefix("End of search list") { break }
            guard inList else { continue }
            // Framework directories are bundles of headers, not namespaces we can
            // enumerate like a normal include dir.
            guard !line.contains("(framework directory)") else { continue }
            directories.append(line)
        }
        return directories
    }

    struct ScanResult {
        var names: Set<String> = []
        var fileCount = 0
        var byteCount = 0
    }

    /// Reads every regular file in `directories` and collects C++ identifiers.
    ///
    /// Underscore-prefixed names are skipped: libc++ uses them for internal
    /// machinery (`__vector_base`) that users should never be offered.
    static func scan(directories: [String], limitPerDirectory: Int = 4000) -> ScanResult {
        var result = ScanResult()
        let fileManager = FileManager.default
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            var scanned = 0
            for entry in entries.sorted() {
                if scanned >= limitPerDirectory { break }
                let path = directory + "/" + entry
                guard let data = fileManager.contents(atPath: path),
                      let text = String(data: data, encoding: .utf8) else { continue }
                scanned += 1
                result.fileCount += 1
                result.byteCount += data.count
                collectIdentifiers(from: text, into: &result.names)
            }
        }
        return result
    }

    /// Adds identifiers from `text`. Only names the headers actually declare are
    /// added; no vocabulary is invented here.
    ///
    /// Comments and literals are removed first: prose in libc++ headers is full
    /// of ordinary English words ("could", "couple", "Ian") that would otherwise
    /// pollute the suggestions.
    static func collectIdentifiers(from text: String, into names: inout Set<String>) {
        let code = strippingCommentsAndLiterals(text)
        var index = code.startIndex
        while index < code.endIndex {
            let character = code[index]
            guard character == "_" || character.isLetter else {
                index = code.index(after: index)
                continue
            }
            var end = index
            while end < code.endIndex, code[end] == "_" || code[end].isLetter || code[end].isNumber {
                end = code.index(after: end)
            }
            let word = code[index..<end]
            // Skip implementation details, all-caps macro soup, and one-letter
            // names: none of them help while typing real code.
            let isUseful = word.count >= 2
                && word.count <= 40
                && !word.hasPrefix("_")
                && word.contains { $0.isLowercase }
            if isUseful { names.insert(String(word)) }
            index = end
        }
    }

    /// Removes `//` and `/* */` comments plus string and character literals.
    static func strippingCommentsAndLiterals(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        let bytes = Array(text.utf8)
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte == 0x2F, index + 1 < count, bytes[index + 1] == 0x2F {
                while index < count, bytes[index] != 0x0A { index += 1 }
            } else if byte == 0x2F, index + 1 < count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                index = min(index + 2, count)
            } else if byte == 0x22 || byte == 0x27 {
                let quote = byte
                index += 1
                while index < count, bytes[index] != quote {
                    if bytes[index] == 0x5C { index += 1 }
                    index += 1
                }
                index += 1
            } else {
                result.unicodeScalars.append(Unicode.Scalar(byte))
                index += 1
            }
        }
        return result
    }

    private static func run(_ tool: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        // `-E -v` writes its search list to stderr.
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        _ = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

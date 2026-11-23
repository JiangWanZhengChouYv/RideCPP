import Foundation

/// An index of identifiers from the headers the **current document actually
/// includes**, resolved through the compiler that compiles it.
///
/// The design goal is "pay only for what you use":
///
/// * Only `#include`/`#import` lines in the open document are examined; nothing
///   is scanned at launch and no whole-SDK index is built.
/// * A header's symbols are scanned once, on a background queue, the first time
///   that header is seen, then kept in memory for the session.
/// * Small disk cache, keyed by the header's path **and** modification date, so a
///   changed SDK or GCC upgrade invalidates it automatically.
///
/// This is what makes `#include <bits/stdc++.h>` (a single header pulling
/// everything) cost one scan of that one header instead of a whole-toolchain
/// sweep.
public final class DocumentSymbolIndex {

    /// Shared index for the app.
    public static let shared = DocumentSymbolIndex()

    /// Symbols per resolved header path.
    private var byHeader: [String: [String]] = [:]
    /// Headers currently being scanned, so a header is never scanned twice.
    private var inFlight: Set<String> = []
    /// Include directives we could not resolve, to avoid retrying every keystroke.
    private var unresolved: Set<String> = []
    /// Directories from the compiler's own search list, resolved once.
    private var searchPaths: [String]?
    private let lock = NSLock()

    /// Cache directory: small, one file per header actually used.
    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("RideCPP/Symbols", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public init() {}

    // MARK: - Query

    /// Symbols contributed by `headers`, best first.
    ///
    /// Never blocks: headers not indexed yet simply contribute nothing this time
    /// and are queued for scanning.
    public func names(from headers: [String], prefix: String, limit: Int = 30) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let lowered = prefix.lowercased()

        lock.lock()
        var collected: [String] = []
        for header in headers {
            if let symbols = byHeader[header] {
                collected.append(contentsOf: symbols)
            }
        }
        let pending = headers.filter { byHeader[$0] == nil }
        lock.unlock()

        var seen = Set<String>()
        var matches: [String] = []
        for name in collected {
            guard name.lowercased().hasPrefix(lowered), !seen.contains(name) else { continue }
            seen.insert(name)
            matches.append(name)
        }
        matches.sort { lhs, rhs in
            let lhsExact = lhs.lowercased() == lowered
            let rhsExact = rhs.lowercased() == lowered
            if lhsExact != rhsExact { return lhsExact }
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs < rhs
        }
        let result = Array(matches.prefix(limit))
        if !pending.isEmpty {
            // Scan what is missing, for the next keystroke.
            requestIndex(headers: pending)
        }
        return result
    }

    /// Number of headers indexed so far (for diagnostics/tests).
    public var indexedHeaderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return byHeader.count
    }

    /// Total symbols held in memory (for diagnostics/tests).
    public var symbolCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return byHeader.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Indexing

    /// Queues the given headers for scanning if they are not already known.
    public func requestIndex(headers: [String]) {
        for header in headers {
            lock.lock()
            let known = byHeader[header] != nil || inFlight.contains(header) || unresolved.contains(header)
            if !known { inFlight.insert(header) }
            lock.unlock()
            guard !known else { continue }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let path = self.resolve(header: header)
                let symbols = path.map { Self.symbols(inHeader: $0) } ?? []
                if path == nil {
                    self.lock.lock()
                    self.unresolved.insert(header)
                    self.lock.unlock()
                }
                self.install(symbols, for: header)
            }
        }
    }

    /// Synchronous indexing, used by tests.
    public func indexSynchronously(headers: [String]) {
        for header in headers {
            let path = resolve(header: header)
            let symbols = path.map { Self.symbols(inHeader: $0) } ?? []
            install(symbols, for: header)
        }
    }

    private func install(_ symbols: [String], for header: String) {
        lock.lock()
        byHeader[header] = symbols
        inFlight.remove(header)
        lock.unlock()
    }

    /// Resolves `#include <x>` / `"x"` to a file path using the compiler's own
    /// search list. Falls back to the raw path when it is absolute.
    public func resolve(header: String) -> String? {
        let fileManager = FileManager.default
        if header.hasPrefix("/") {
            return fileManager.fileExists(atPath: header) ? header : nil
        }
        for directory in searchDirectories() {
            let candidate = directory + "/" + header
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The compiler's include search list, resolved once per session.
    ///
    /// `bits/stdc++.h` is found by the same mechanism as any other header: it is
    /// simply another path in this list, so it needs no special case.
    public func searchDirectories() -> [String] {
        lock.lock()
        if let searchPaths {
            lock.unlock()
            return searchPaths
        }
        lock.unlock()

        let directories = HeaderPaths.searchList()
        lock.lock()
        searchPaths = directories
        lock.unlock()
        return directories
    }

    // MARK: - Reading one header

    /// Identifiers declared by one header file, cached on disk by path + mtime.
    static func symbols(inHeader path: String) -> [String] {
        let modification = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        if let cached = loadCache(path: path, modification: modification) { return cached }

        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var names = Set<String>()
        collectIdentifiers(from: text, into: &names, followingIncludesAt: path, depth: 0)
        let sorted = names.sorted()
        saveCache(sorted, path: path, modification: modification)
        return sorted
    }

    /// Collects identifiers, following local `#include "..."` files one level deep
    /// so a wrapper header behaves like its contents.
    ///
    /// System includes are *not* followed: that is exactly the whole-SDK sweep
    /// this design avoids. `bits/stdc++.h` is cheap precisely because it is read
    /// as one (large) file.
    static func collectIdentifiers(from text: String,
                                    into names: inout Set<String>,
                                    followingIncludesAt path: String?,
                                    depth: Int) {
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
            let isUseful = word.count >= 2
                && word.count <= 40
                && !word.hasPrefix("_")
                && word.contains { $0.isLowercase }
            if isUseful { names.insert(String(word)) }
            index = end
        }

        // Aggregator headers (`bits/stdc++.h`, `iostream`) declare almost nothing
        // themselves; their value is what they pull in. Following every include
        // would sweep the whole toolchain, so only the *aggregator* case is
        // followed, and only one level deep: if a header is (almost) nothing but
        // includes, read the headers it names directly.
        guard depth < 1, let path else { return }
        let trimmedLines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let includeLines = trimmedLines.filter { $0.hasPrefix("#include") }
        let codeLines = trimmedLines.filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("/*")
            && !$0.hasPrefix("*") && !$0.hasPrefix("#include") && !$0.hasPrefix("#") }
        let isAggregator = !includeLines.isEmpty && codeLines.count <= 2
        guard isAggregator else { return }

        let directory = (path as NSString).deletingLastPathComponent
        for line in includeLines {
            guard let target = Self.includeTarget(in: line, relativeTo: directory) else { continue }
            guard let data = FileManager.default.contents(atPath: target),
                  let included = String(data: data, encoding: .utf8) else { continue }
            collectIdentifiers(from: included, into: &names, followingIncludesAt: nil, depth: depth + 1)
        }
    }

    /// Resolves one `#include` line to a path: relative for quoted includes,
    /// search-list based for angle includes.
    static func includeTarget(in line: String, relativeTo directory: String) -> String? {
        guard let after = line.range(of: "#include") else { return nil }
        let rest = line[after.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
            return directory + "/" + String(rest[rest.index(after: rest.startIndex)..<close])
        }
        if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            let header = String(rest[rest.index(after: rest.startIndex)..<close])
            return HeaderPaths.file(forHeader: header)
        }
        return nil
    }

    /// Removes `//` and `/* */` comments plus literals.
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

    // MARK: - Disk cache (one small file per header)

    private static func cacheURL(path: String, modification: Date?) -> URL? {
        guard let directory = cacheDirectory else { return nil }
        let stamp = modification.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        // Hash the path so long SDK paths stay within filename limits.
        var hasher = Hasher()
        hasher.combine(path)
        hasher.combine(stamp)
        return directory.appendingPathComponent("h\(hasher.finalize()).txt")
    }

    private static func loadCache(path: String, modification: Date?) -> [String]? {
        guard let url = cacheURL(path: path, modification: modification),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let names = text.split(separator: "\n").map(String.init)
        return names.isEmpty ? nil : names
    }

    private static func saveCache(_ names: [String], path: String, modification: Date?) {
        guard let url = cacheURL(path: path, modification: modification) else { return }
        try? names.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Compiler include paths, resolved once per session.
public enum HeaderPaths {

    private static var cached: [String] = []
    private static let lock = NSLock()

    /// The active compiler's `#include <...>` search list.
    public static func searchList(compilerPath: String? = nil) -> [String] {
        lock.lock()
        if !cached.isEmpty {
            let existing = cached
            lock.unlock()
            return existing
        }
        lock.unlock()

        let directories = resolve(compilerPath: compilerPath)
        lock.lock()
        cached = directories
        lock.unlock()
        return directories
    }

    /// Directories that exist on disk, from the compiler or the SDK fallback.
    public static func resolve(compilerPath: String? = nil) -> [String] {
        let compiler = compilerPath ?? "/usr/bin/clang++"
        if let output = run(compiler, arguments: ["-x", "c++", "-E", "-v", "-"]),
           let parsed = parseSearchList(output) as [String]?, !parsed.isEmpty {
            return parsed
        }
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
            guard !line.contains("(framework directory)") else { continue }
            directories.append(line)
        }
        return directories
    }

    /// Resolves an angle-include header name through the search list.
    public static func file(forHeader header: String) -> String? {
        for directory in searchList() {
            let candidate = directory + "/" + header
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Test hook: overrides the resolved search list for this process.
    public static func setSearchListForTesting(_ directories: [String]) {
        lock.lock()
        cached = directories
        lock.unlock()
    }

    /// `#include` targets in a document, in order, without duplicates.
    public static func includes(in document: String) -> [String] {
        var headers: [String] = []
        var seen = Set<String>()
        for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            guard let includeRange = trimmed.range(of: "#include") ?? trimmed.range(of: "#import"),
                  includeRange.lowerBound == trimmed.startIndex else { continue }
            let rest = trimmed[includeRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let header: String?
            if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
                header = String(rest[rest.index(after: rest.startIndex)..<close])
            } else if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
                header = String(rest[rest.index(after: rest.startIndex)..<close])
            } else {
                header = nil
            }
            guard let header, !header.isEmpty, !seen.contains(header) else { continue }
            seen.insert(header)
            headers.append(header)
        }
        return headers
    }

    private static func run(_ tool: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
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

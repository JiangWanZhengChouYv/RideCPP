import Foundation

/// Formats C++ source with clang-format.
public enum FormatterError: LocalizedError {
    case toolNotFound
    case failed(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "clang-format was not found."
        case .failed(let message):
            return message.isEmpty ? "clang-format failed." : message
        case .emptyResult:
            return "clang-format returned no output."
        }
    }
}

public enum FormatterService {

    /// Formats `source` by piping it through clang-format.
    ///
    /// - Parameters:
    ///   - source: the whole document text.
    ///   - fileName: used for `-assume-filename`, so clang-format treats it as C++.
    ///   - executablePath: explicit clang-format path, or `nil` to auto-detect.
    ///   - style: an LLVM style name, `"file"` to use `.clang-format`, or an
    ///     inline `{Key: Value}` configuration.
    public static func format(source: String,
                              fileName: String,
                              executablePath: String?,
                              style: String) throws -> String {
        let path: String
        if let executablePath, !executablePath.isEmpty {
            path = executablePath
        } else if let detected = Toolchain.findClangFormat() {
            path = detected
        } else {
            throw FormatterError.toolNotFound
        }

        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw FormatterError.toolNotFound
        }

        var arguments = ["-assume-filename=\(fileName)", "-style=\(style)"]
        if style == "file" {
            // Nothing else needed; clang-format searches parent directories.
            arguments = ["-assume-filename=\(fileName)", "-style=file"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw FormatterError.failed(error.localizedDescription)
        }

        let inputData = Data(source.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: inputData)
            try? stdin.fileHandleForWriting.close()
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw FormatterError.failed(message.isEmpty ? "clang-format exited with status \(process.terminationStatus)" : message)
        }
        let output = String(decoding: outputData, as: UTF8.self)
        guard !output.isEmpty else { throw FormatterError.emptyResult }
        return output
    }

    /// Formats asynchronously, off the main thread.
    public static func formatAsync(source: String,
                                   fileName: String,
                                   executablePath: String?,
                                   style: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try format(source: source,
                                            fileName: fileName,
                                            executablePath: executablePath,
                                            style: style)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

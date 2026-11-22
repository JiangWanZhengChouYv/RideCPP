import Foundation

/// Everything needed to compile (and optionally run) one source file.
public struct BuildRequest: Sendable {
    public enum Action: String, Sendable {
        case build
        case run
    }

    public var action: Action
    public var sourcePath: String
    /// File name the IDE displays when reporting scratch compiles.
    public var sourceDisplayName: String
    public var compilerPath: String
    public var standard: String
    public var optimization: String
    public var extraFlags: [String]
    public var runArguments: [String]
    public var outputPath: String
    public var workingDirectory: String

    public init(action: Action,
                sourcePath: String,
                sourceDisplayName: String,
                compilerPath: String,
                standard: String,
                optimization: String = "-O2",
                extraFlags: [String] = [],
                runArguments: [String] = [],
                outputPath: String,
                workingDirectory: String) {
        self.action = action
        self.sourcePath = sourcePath
        self.sourceDisplayName = sourceDisplayName
        self.compilerPath = compilerPath
        self.standard = standard
        self.optimization = optimization
        self.extraFlags = extraFlags
        self.runArguments = runArguments
        self.outputPath = outputPath
        self.workingDirectory = workingDirectory
    }

    /// The compiler command line, exposed for the output panel and for tests.
    public var compileArguments: [String] {
        var arguments = ["-std=\(standard)", optimization, "-g"]
        arguments.append(contentsOf: extraFlags)
        arguments.append(sourcePath)
        arguments.append(contentsOf: ["-o", outputPath])
        return arguments
    }

    public var displayCommand: String {
        ([compilerPath] + compileArguments).map { argument in
            argument.contains(" ") && !argument.hasPrefix("-") ? "'\(argument)'" : argument
        }.joined(separator: " ")
    }
}

/// An event produced while a build or run is in progress.
public enum BuildEvent: Sendable {
    /// Compile started; carries the command line for logging/diagnostics.
    case started(String)
    /// Raw compiler output. Not shown as program output: it only feeds the
    /// Problems list.
    case compilerOutput(String)
    case diagnostics([Diagnostic])
    /// Compile finished. `succeeded == false` means no run will happen.
    case finished(exitCode: Int32, succeeded: Bool)
    /// The program was launched on its interactive terminal.
    case runStarted
    /// Live output from the running program (its stdout/stderr on the terminal).
    case runOutput(String)
    /// The program has exited, with how long it actually ran (time spent waiting
    /// for user input excluded), its CPU time and its peak memory.
    case runFinished(exitCode: Int32,
                     duration: TimeInterval,
                     cpuTime: TimeInterval,
                     peakMemoryBytes: UInt64?)
    case failed(String)
}

/// Compiles the current file and, when asked, runs the resulting executable.
///
/// Compilation scope is one translation unit: the file in the active tab. That
/// keeps the IDE lightweight and is what the "current file" build mode means.
public final class BuildService {

    public static let buildTimeout: TimeInterval = 120
    private let scratchDirectory: URL
    /// Handle to the compiler currently running, so `cancel()` works.
    private let activeHandle = ProcessHandle()
    /// The interactive program session, when one is running.
    private var session: InteractiveProcess?

    public init(scratchDirectory: URL? = nil) {
        if let scratchDirectory {
            self.scratchDirectory = scratchDirectory
        } else {
            self.scratchDirectory = Self.defaultScratchDirectory()
        }
        try? FileManager.default.createDirectory(at: self.scratchDirectory, withIntermediateDirectories: true)
    }

    /// `~/Library/Application Support/RideCPP/Scratch`, falling back to the temp
    /// directory when that location is not writable (sandboxed test runs, CI).
    public static func defaultScratchDirectory() -> URL {
        let fileManager = FileManager.default
        if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let candidate = base.appendingPathComponent("RideCPP/Scratch", isDirectory: true)
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
                // Verify write access, not just existence.
                let probe = candidate.appendingPathComponent(".write-probe")
                try Data().write(to: probe)
                try? fileManager.removeItem(at: probe)
                return candidate
            } catch {
                // Fall through to the temp directory.
            }
        }
        let fallback = fileManager.temporaryDirectory.appendingPathComponent("RideCPP/Scratch", isDirectory: true)
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Writes unsaved content to a scratch file so it can be compiled and so
    /// diagnostics can be mapped back to the tab.
    public func prepareScratchFile(contents: String, tabID: UUID, suggestedName: String) -> (path: String, displayName: String) {
        let safeName = Self.sanitizedFileName(suggestedName)
        let folder = scratchDirectory.appendingPathComponent(tabID.uuidString, isDirectory: true)
        let fileURL = folder.appendingPathComponent(safeName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Last resort: a flat temp file, still unique per tab, so a build can
            // proceed even when the preferred scratch tree is unavailable.
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("RideCPP-\(tabID.uuidString)")
                .appendingPathComponent(safeName)
            try? FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? contents.write(to: fallback, atomically: true, encoding: .utf8)
            return (fallback.path, safeName)
        }
        return (fileURL.path, safeName)
    }

    /// Path of the executable produced for a source file.
    public func executableURL(for request: BuildRequest) -> URL {
        URL(fileURLWithPath: request.outputPath)
    }

    /// Builds, then optionally runs the program interactively.
    ///
    /// For `.run`, the program is attached to a pseudo-terminal: its output
    /// streams as it is produced (so prompts are visible before any input), and
    /// the caller can keep sending input through `send(_:)` until it exits.
    public func perform(_ request: BuildRequest) -> AsyncStream<BuildEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(request.displayCommand))
                let buildResult = await self.compile(request, continuation: continuation)
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                guard buildResult.succeeded, request.action == .run else {
                    continuation.yield(.finished(exitCode: buildResult.exitCode,
                                                 succeeded: buildResult.succeeded))
                    continuation.finish()
                    return
                }
                continuation.yield(.finished(exitCode: buildResult.exitCode, succeeded: true))

                guard let session = self.startInteractiveRun(request, continuation: continuation) else {
                    continuation.finish()
                    return
                }
                self.session = session
                continuation.yield(.runStarted)
                // Keep the stream open until the program exits.
                while session.isRunning {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.cancel()
            }
        }
    }

    private func compile(_ request: BuildRequest, continuation: AsyncStream<BuildEvent>.Continuation) async -> (succeeded: Bool, exitCode: Int32) {
        guard FileManager.default.isExecutableFile(atPath: request.compilerPath) else {
            continuation.yield(.failed("Compiler not found at \(request.compilerPath)"))
            return (false, -1)
        }

        // Ensure the working directory exists and is writable-ish; fall back to
        // the temp dir if the file was deleted while open.
        let workingDirectory = FileManager.default.fileExists(atPath: request.workingDirectory)
            ? request.workingDirectory
            : FileManager.default.temporaryDirectory.path

        var collectedOutput = ""
        var exitCode: Int32 = -1
        let stream = ProcessRunner.run(executable: request.compilerPath,
                                       arguments: request.compileArguments,
                                       workingDirectory: URL(fileURLWithPath: workingDirectory),
                                       handle: activeHandle)

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.buildTimeout * 1_000_000_000))
            if !Task.isCancelled {
                self.cancel()
            }
        }
        defer { timeoutTask.cancel() }

        do {
            for try await chunk in stream {
                if chunk.isComplete {
                    exitCode = chunk.terminationStatus ?? -1
                    continue
                }
                guard !chunk.text.isEmpty else { continue }
                collectedOutput += chunk.text
                continuation.yield(.compilerOutput(chunk.text))
            }
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            return (false, -1)
        }

        let parsed = DiagnosticsParser.parse(collectedOutput)
        if !parsed.isEmpty {
            continuation.yield(.diagnostics(parsed))
        }
        let outputExists = FileManager.default.isExecutableFile(atPath: request.outputPath)
        return (exitCode == 0 && outputExists, exitCode)
    }

    /// Launches the compiled program on an interactive terminal.
    private func startInteractiveRun(_ request: BuildRequest,
                                     continuation: AsyncStream<BuildEvent>.Continuation) -> InteractiveProcess? {
        guard FileManager.default.isExecutableFile(atPath: request.outputPath) else {
            continuation.yield(.failed("The compiled program was not produced."))
            return nil
        }

        let session: InteractiveProcess
        do {
            session = try InteractiveProcess()
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            return nil
        }

        let outputContinuation = continuation
        session.onOutput = { text in
            outputContinuation.yield(.runOutput(text))
        }
        // The session reports exact run costs from `wait4`, so the compiler's
        // resource use never mixes into them.
        session.onExit = { outcome in
            outputContinuation.yield(.runFinished(exitCode: outcome.exitCode,
                                                  duration: outcome.duration,
                                                  cpuTime: outcome.cpuTime,
                                                  peakMemoryBytes: outcome.peakResidentBytes))
            outputContinuation.finish()
        }

        let workingDirectory = FileManager.default.fileExists(atPath: request.workingDirectory)
            ? URL(fileURLWithPath: request.workingDirectory)
            : FileManager.default.temporaryDirectory

        do {
            try session.launch(executable: request.outputPath,
                               arguments: request.runArguments,
                               workingDirectory: workingDirectory,
                               environment: ["TERM": "dumb", "CLICOLOR": "0"])
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            return nil
        }
        return session
    }

    /// Sends a line of input to the running program. Returns false when no
    /// program is running.
    @discardableResult
    public func send(input: String) -> Bool {
        session?.send(input) ?? false
    }

    /// Sends Ctrl-C to the running program.
    public func interruptProgram() {
        session?.interrupt()
    }

    /// Terminates the running compiler or program.
    public func cancel() {
        activeHandle.terminate()
        session?.terminate()
    }

    /// Whether a build or program is currently running.
    public var isBusy: Bool { activeHandle.isRunning || (session?.isRunning ?? false) }

    // MARK: - Paths

    public static func sanitizedFileName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "Untitled" }
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        trimmed = trimmed.components(separatedBy: invalid).joined(separator: "_")
        if !trimmed.contains(".") {
            trimmed += ".cpp"
        }
        return trimmed
    }
}

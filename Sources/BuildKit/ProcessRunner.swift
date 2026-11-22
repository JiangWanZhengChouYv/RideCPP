import Foundation

/// One chunk of process output.
public struct ProcessOutput: Sendable {
    public enum Stream: Sendable {
        case stdout
        case stderr
    }

    public let stream: Stream
    public let text: String
    public let isComplete: Bool
    public let terminationStatus: Int32?

    public init(stream: Stream, text: String, isComplete: Bool = false, terminationStatus: Int32? = nil) {
        self.stream = stream
        self.text = text
        self.isComplete = isComplete
        self.terminationStatus = terminationStatus
    }
}

/// Handle to a running child process, so callers can stop it.
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    public init() {}

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Terminates the child process if it is still running.
    public func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

/// A launched child process whose output is delivered as an `AsyncStream`.
///
/// Output is line-buffered per stream: chunks may split a line in the middle, so
/// the consumer is fed whole lines where possible and any remaining tail when
/// the process exits.
public final class ProcessRunner {

    /// Runs `executable` with `arguments`, streaming stdout and stderr.
    ///
    /// - Parameters:
    ///   - workingDirectory: cwd for the child process, if any.
    ///   - standardInput: text written to the child's stdin, if any.
    ///   - environment: extra environment variables merged over the parent's.
    public static func run(executable: String,
                           arguments: [String],
                           workingDirectory: URL? = nil,
                           standardInput: String? = nil,
                           environment: [String: String] = [:],
                           handle: ProcessHandle? = nil) -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if !environment.isEmpty {
                var merged = ProcessInfo.processInfo.environment
                for (key, value) in environment { merged[key] = value }
                process.environment = merged
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdinPipe: Pipe?
            if standardInput != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            } else {
                process.standardInput = FileHandle.nullDevice
                stdinPipe = nil
            }

            let lock = NSLock()
            var stdoutBuffer = ""
            var stderrBuffer = ""
            var finished = false

            func emit(_ stream: ProcessOutput.Stream, _ text: String, force: Bool) {
                guard !text.isEmpty || force else { return }
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                continuation.yield(ProcessOutput(stream: stream, text: text))
                lock.unlock()
            }

            func drain(_ handle: FileHandle, stream: ProcessOutput.Stream) {
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                lock.lock()
                var buffer = stream == .stdout ? stdoutBuffer : stderrBuffer
                buffer += text
                var chunk = ""
                while let newlineIndex = buffer.firstIndex(of: "\n") {
                    chunk += String(buffer[...newlineIndex])
                    buffer = String(buffer[buffer.index(after: newlineIndex)...])
                }
                if stream == .stdout { stdoutBuffer = buffer } else { stderrBuffer = buffer }
                lock.unlock()
                emit(stream, chunk, force: false)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                drain(handle, stream: .stdout)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                drain(handle, stream: .stderr)
            }

            process.terminationHandler = { terminated in
                // Flush buffered tails.
                lock.lock()
                let remainingOut = stdoutBuffer
                let remainingErr = stderrBuffer
                stdoutBuffer = ""
                stderrBuffer = ""
                finished = true
                lock.unlock()
                continuation.yield(ProcessOutput(stream: .stdout, text: remainingOut))
                continuation.yield(ProcessOutput(stream: .stderr, text: remainingErr))
                continuation.yield(ProcessOutput(stream: .stdout,
                                                 text: "",
                                                 isComplete: true,
                                                 terminationStatus: terminated.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
                handle?.attach(process)
            } catch {
                lock.lock()
                finished = true
                lock.unlock()
                continuation.finish(throwing: error)
                return
            }

            if let stdinPipe, let standardInput {
                // Writing a modest amount up front is enough for interactive
                // test programs; keep it off the calling thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = stdinPipe.fileHandleForWriting
                    if let data = standardInput.data(using: .utf8) {
                        try? handle.write(contentsOf: data)
                    }
                    try? handle.close()
                }
            }

            continuation.onTermination = { _ in
                handle?.terminate()
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

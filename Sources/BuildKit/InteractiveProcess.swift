import Foundation
import Darwin

/// Splits UTF-8 data into complete text, holding back any trailing partial
/// multi-byte sequence so output is never garbled at chunk boundaries.
public enum UTF8Chunker {
    /// Returns the decodable prefix and the undecoded remainder.
    public static func split(_ data: Data) -> (text: String, remainder: Data) {
        guard !data.isEmpty else { return ("", Data()) }
        let bytes = [UInt8](data)
        // Find the start of the last character in the buffer.
        var start = bytes.count - 1
        var scanned = 0
        while start >= 0, scanned < 4 {
            let byte = bytes[start]
            if byte & 0xC0 != 0x80 { break }  // not a continuation byte
            start -= 1
            scanned += 1
        }
        guard start >= 0 else { return ("", Data()) }  // nothing decodable yet
        let expected = Self.sequenceLength(for: bytes[start])
        let available = bytes.count - start
        if expected > 1, available < expected {
            // Incomplete character: keep it for the next chunk.
            let head = data.prefix(start)
            return (String(decoding: head, as: UTF8.self), data.suffix(available))
        }
        return (String(decoding: data, as: UTF8.self), Data())
    }

    private static func sequenceLength(for byte: UInt8) -> Int {
        if byte & 0x80 == 0x00 { return 1 }
        if byte & 0xE0 == 0xC0 { return 2 }
        if byte & 0xF0 == 0xE0 { return 3 }
        if byte & 0xF8 == 0xF0 { return 4 }
        return 1
    }
}

/// What a finished program run cost.
public struct RunOutcome: Sendable {
    public let exitCode: Int32
    /// How long the program was actually running, in seconds.
    ///
    /// Time spent waiting for the user to type is excluded: for an interactive
    /// program this is the total running time minus the time parked in a read
    /// waiting for input. It equals wall time for a program that never reads
    /// stdin, which is the normal case for algorithm code.
    public let duration: TimeInterval
    /// User + system CPU time spent by the program, from `wait4`.
    public let cpuTime: TimeInterval
    /// Peak resident set size of the program itself, exactly as reported by
    /// `wait4`, or nil when the kernel did not provide it.
    public let peakResidentBytes: UInt64?

    public init(exitCode: Int32, duration: TimeInterval, cpuTime: TimeInterval, peakResidentBytes: UInt64?) {
        self.exitCode = exitCode
        self.duration = duration
        self.cpuTime = cpuTime
        self.peakResidentBytes = peakResidentBytes
    }
}

/// A program running attached to a pseudo-terminal, so it behaves exactly like
/// it would in Terminal: prompts appear immediately (stdout to a tty is
/// line-buffered, not block-buffered) and input can be typed while it runs.
///
/// The child is created with `posix_spawn` and reaped with `wait4`, which is what
/// makes exact per-run statistics available (peak memory, CPU time). A plain
/// `Process` cannot report them: it reaps the child itself and
/// `getrusage(RUSAGE_CHILDREN)` would mix in the compiler's numbers.
///
/// Terminal echo is turned off: the IDE renders the user's input itself, so the
/// output view shows the program's text without duplicate echo.
public final class InteractiveProcess {

    public enum Failure: LocalizedError {
        case ptyUnavailable
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .ptyUnavailable:
                return "Could not create a pseudo-terminal for interactive input."
            case .launchFailed(let message):
                return message
            }
        }
    }

    /// Called on a background queue with program output as it arrives.
    public var onOutput: ((String) -> Void)?
    /// Called once when the program exits, with its exit status and costs.
    public var onExit: ((RunOutcome) -> Void)?

    private let masterFD: Int32
    private var slaveFD: Int32
    private let stateLock = NSLock()
    private var hasLaunched = false
    private var masterClosed = false
    private var slaveClosed = false
    private var pendingBytes = Data()
    private var outputHandler: FileHandle?
    private var pid: pid_t = 0
    private var waitQueue = DispatchQueue(label: "RideCPP.InteractiveProcess.wait")
    private var monitoringQueue = DispatchQueue(label: "RideCPP.InteractiveProcess.monitor")
    private var monitorTimer: DispatchSourceTimer?
    private var monitoringStarted = false
    /// Actual running time accumulated so far, in nanoseconds.
    ///
    /// Measured with `kill(pid, 0)` rather than any of the kernel CPU counters:
    /// `proc_pid_rusage` and `proc_pidinfo` under-report badly on this system
    /// while a pseudo-terminal is attached (a 1.2 s CPU loop showed up as
    /// 14 ms), whereas a zero signal answers "is it runnable?" in well under a
    /// microsecond. Each probe that succeeds costs its own syscall time
    /// (~0.5 µs), which is negligible.
    private var activeTimeNanos: UInt64 = 0
    /// Monotonic time of the previous probe. Only 0 before the first probe of a
    /// launch, which is treated as "no measurable interval yet".
    private var lastProbeNanos: UInt64 = 0
    /// Written once the program has been reaped; no further probes may touch the
    /// counters after that.
    private var hasExited = false

    /// Creates the terminal. Returns `nil` when the system refuses to allocate a
    /// pty (which is rare, but possible under a restrictive sandbox).
    public init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw Failure.ptyUnavailable
        }
        masterFD = master
        slaveFD = slave
        // The parent keeps the master end: make sure the child does not inherit it.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        // Raw output (no CRLF translation: the view renders LF itself) and
        // canonical line input with echo suppressed.
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_oflag &= ~tcflag_t(OPOST)
            settings.c_lflag &= ~tcflag_t(ECHO)
            settings.c_lflag |= tcflag_t(ICANON)
            settings.c_lflag |= tcflag_t(ISIG)
            tcsetattr(slave, TCSANOW, &settings)
        }
        // A plausible window size, for programs that query the terminal.
        var size = winsize(ws_row: 50, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &size)
    }

    deinit {
        stopReading()
        closeMaster()
        closeSlave()
    }

    private func closeMaster() {
        stateLock.lock()
        let alreadyClosed = masterClosed
        masterClosed = true
        stateLock.unlock()
        if !alreadyClosed { close(masterFD) }
    }

    /// Closing the slave end is what lets a drain of the master reach EOF.
    private func closeSlave() {
        stateLock.lock()
        let alreadyClosed = slaveClosed
        slaveClosed = true
        stateLock.unlock()
        if !alreadyClosed { close(slaveFD) }
    }

    /// Launches `executable` on the terminal and starts streaming its output.
    ///
    /// - Parameter initialInput: text written to the program before it starts
    ///   asking, so prepared input is available to the first read.
    public func launch(executable: String,
                       arguments: [String],
                       workingDirectory: URL? = nil,
                       environment: [String: String] = [:],
                       initialInput: String? = nil) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Point the child's three standard streams at the terminal.
        posix_spawn_file_actions_adddup2(&actions, slaveFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slaveFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slaveFD, STDERR_FILENO)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        activeTimeNanos = 0
        lastProbeNanos = DispatchTime.now().uptimeNanoseconds
        var childPID: pid_t = 0
        let result = posix_spawn(&childPID, executable, &actions, nil, argv, envp)
        guard result == 0 else {
            throw Failure.launchFailed("Could not start \(executable): \(String(cString: strerror(result)))")
        }
        pid = childPID
        stateLock.lock()
        hasLaunched = true
        stateLock.unlock()
        // The child owns the slave now; the parent only keeps the master.
        closeSlave()

        startReading()
        startMonitoring()
        startWaiting()

        if let initialInput, !initialInput.isEmpty {
            self.send(initialInput)
        }
    }

    public var isRunning: Bool {
        stateLock.lock()
        let running = hasLaunched && !hasExited
        stateLock.unlock()
        return running
    }

    public var processIdentifier: Int32 { pid }

    /// Sends text to the program's standard input. A line without a trailing
    /// newline gets one, which is what an interactive program expects after the
    /// user presses Return.
    @discardableResult
    public func send(_ text: String) -> Bool {
        guard isRunning else { return false }
        var payload = text
        if !payload.hasSuffix("\n") { payload += "\n" }
        // A pty feeds a terminal in canonical mode, so CR is the Return key.
        payload = payload.replacingOccurrences(of: "\n", with: "\r")
        let data = Data(payload.utf8)
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var written = 0
            while written < data.count {
                let result = write(masterFD, base.advanced(by: written), data.count - written)
                if result <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += result
            }
            return true
        }
    }

    /// Sends an interrupt character, like pressing Ctrl-C in a terminal.
    public func interrupt() {
        guard isRunning else { return }
        var byte = UInt8(0x03)
        _ = write(masterFD, &byte, 1)
    }

    /// Stops the program: SIGTERM first, SIGKILL if it ignores that.
    public func terminate() {
        guard isRunning, pid > 0 else { return }
        kill(pid, SIGTERM)
        let target = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isRunning else { return }
            kill(target, SIGKILL)
        }
    }

    // MARK: - Plumbing

    private func startReading() {
        let handle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        outputHandler = handle
        handle.readabilityHandler = { [weak self] source in
            let data = source.availableData
            if data.isEmpty {
                source.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
    }

    private func stopReading() {
        outputHandler?.readabilityHandler = nil
        outputHandler = nil
        // The master must stay open for the wait thread's final drain.
    }

    private func consume(_ data: Data) {
        stateLock.lock()
        pendingBytes.append(data)
        let (text, remainder) = UTF8Chunker.split(pendingBytes)
        pendingBytes = remainder
        stateLock.unlock()
        guard !text.isEmpty else { return }
        onOutput?(text)
    }

    /// Blocks in `wait4` on its own queue: that is what yields the exact rusage
    /// (peak memory is only available once the child has been reaped).
    private func startWaiting() {
        let childPID = pid
        waitQueue.async { [weak self] in
            var status: Int32 = 0
            var usage = rusage()
            var reaped: pid_t
            repeat {
                reaped = wait4(childPID, &status, 0, &usage)
            } while reaped == -1 && errno == EINTR

            let active = self?.stopMonitoring() ?? 0
            let cpuTime = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
                + TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
            let exitCode: Int32
            if reaped == childPID {
                let signal = status & 0x7f
                if signal == 0 {
                    // Normal exit: the code is the high byte.
                    exitCode = (status >> 8) & 0xff
                } else {
                    // Killed by a signal, reported the way shells do.
                    exitCode = 128 + signal
                }
            } else {
                exitCode = -1
            }
            let peak = usage.ru_maxrss > 0 ? UInt64(usage.ru_maxrss) : nil
            let outcome = RunOutcome(exitCode: exitCode,
                                     duration: active,
                                     cpuTime: cpuTime,
                                     peakResidentBytes: peak)
            self?.handleExit(outcome)
        }
    }

    /// Measures how long the program actually runs, excluding time parked in a
    /// read waiting for the user to type.
    ///
    /// Each interval is counted as running time unless the process is asleep: a
    /// zero signal answers "is it still alive?" and `ps -o state=` distinguishes
    /// "running" from "sleeping in read". Resolution is the probe interval (2 ms).
    private func startMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: monitoringQueue)
        timer.schedule(deadline: .now(), repeating: 0.002, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.probe()
        }
        monitorTimer = timer
        timer.resume()
    }

    private func probe() {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let alive = kill(pid, 0) == 0
        // Only an idle wait counts as "not running": a process sleeping in a
        // terminal read is "S" (and "I" when the kernel reports it as idle). Any
        // other state, including "R", "U" and "D", is work in progress.
        let state = Self.processState(pid: pid)
        let waitingForInput = (state == "S" || state == "I")
        let running = alive && !waitingForInput
        stateLock.lock()
        defer { stateLock.unlock() }
        // Once the program has been reaped its pid may be reused, so a late probe
        // must never add time.
        guard !hasExited else { return }
        if running, lastProbeNanos > 0, nowNanos >= lastProbeNanos {
            activeTimeNanos &+= nowNanos - lastProbeNanos
        }
        lastProbeNanos = nowNanos
    }

    /// Single-letter process state from `ps`, or nil if it could not be read.
    private static func processState(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return nil }
        return String(first)
    }

    /// Stops measuring and returns how long the program actually ran.
    private func stopMonitoring() -> TimeInterval {
        // Cancel first, then drain: an in-flight probe should finish, but no new
        // one may start after the child has been reaped.
        monitorTimer?.cancel()
        monitorTimer = nil
        monitoringQueue.sync {}
        stateLock.lock()
        let total = activeTimeNanos
        let now = DispatchTime.now().uptimeNanoseconds
        let last = lastProbeNanos
        stateLock.unlock()
        // Count the tail up to the moment we learned about the exit, if the
        // program was still running then (not waiting for input).
        var measured = TimeInterval(total) / 1_000_000_000
        if last > 0, now > last {
            measured += Double(now - last) / 1_000_000_000
        }
        return max(0, measured)
    }

    private func handleExit(_ outcome: RunOutcome) {
        stateLock.lock()
        guard !hasExited else {
            stateLock.unlock()
            return
        }
        hasExited = true
        stateLock.unlock()

        // Drain whatever the program wrote just before exiting. The slave is
        // already closed, so this reaches EOF instead of blocking.
        stopReading()
        var remaining = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            let count = read(masterFD, &buffer, buffer.count)
            if count <= 0 { break }
            remaining.append(contentsOf: buffer[0..<count])
        }

        stateLock.lock()
        if !remaining.isEmpty { pendingBytes.append(remaining) }
        let (text, leftover) = UTF8Chunker.split(pendingBytes)
        pendingBytes = leftover
        stateLock.unlock()
        if !text.isEmpty { onOutput?(text) }

        onExit?(outcome)
        closeMaster()
    }
}

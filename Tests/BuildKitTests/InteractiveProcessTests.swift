import XCTest
@testable import BuildKit

final class UTF8ChunkerTests: XCTestCase {

    func testSplitsCompleteASCII() {
        let (text, remainder) = UTF8Chunker.split(Data("hello\n".utf8))
        XCTAssertEqual(text, "hello\n")
        XCTAssertTrue(remainder.isEmpty)
    }

    func testHoldsBackPartialMultiByteCharacter() {
        // "你好" is 6 bytes; cut after 4 so the second character is incomplete.
        let full = Data("你好".utf8)
        let firstHalf = full.prefix(4)
        let (text, remainder) = UTF8Chunker.split(firstHalf)
        XCTAssertEqual(text, "你")
        XCTAssertEqual(remainder, full.subdata(in: 3..<4))

        // Completing the remainder yields the second character.
        var pending = remainder
        pending.append(full.suffix(2))
        let (completed, leftover) = UTF8Chunker.split(pending)
        XCTAssertEqual(completed, "好")
        XCTAssertTrue(leftover.isEmpty)
    }

    func testEmptyInput() {
        let (text, remainder) = UTF8Chunker.split(Data())
        XCTAssertEqual(text, "")
        XCTAssertTrue(remainder.isEmpty)
    }

    func testEmojiAtBoundary() {
        let full = Data("a😀b".utf8)
        let cut = full.prefix(2)  // "a" + first byte of the emoji
        let (text, remainder) = UTF8Chunker.split(cut)
        XCTAssertEqual(text, "a")
        XCTAssertEqual(remainder.count, 1)
    }
}

@MainActor
final class InteractiveProcessTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPPInteractive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeEchoScript() throws -> URL {
        // A tiny shell script stands in for a compiled program: it prompts,
        // reads a line, and answers. This exercises stdin/stdout and a tty
        // without needing a compiler.
        let script = directory.appendingPathComponent("echo.sh")
        let body = """
        #!/bin/sh
        printf 'Say something: '
        read line
        printf 'You said %s\\n' "$line"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testPromptArrivesBeforeProgramExits() throws {
        let script = try makeEchoScript()
        let session = try InteractiveProcess()
        let prompted = expectation(description: "prompt received")
        let finished = expectation(description: "program finished")
        var collected = ""
        var replied = false

        session.onOutput = { text in
            collected += text
            if !replied, collected.contains("Say something:") {
                replied = true
                prompted.fulfill()
                session.send("hello tty")
            }
        }
        session.onExit = { outcome in
            XCTAssertEqual(outcome.exitCode, 0)
            XCTAssertGreaterThanOrEqual(outcome.duration, 0)
            XCTAssertNotNil(outcome.peakResidentBytes, "peak memory should come from wait4")
            XCTAssertGreaterThanOrEqual(outcome.cpuTime, 0)
            finished.fulfill()
        }
        try session.launch(executable: script.path, arguments: [])

        wait(for: [prompted, finished], timeout: 15)
        XCTAssertTrue(collected.contains("You said hello tty"), "got: \(collected)")
    }

    func testSendReturnsFalseWhenNotRunning() throws {
        let session = try InteractiveProcess()
        XCTAssertFalse(session.send("nobody is listening"))
    }

    func testTerminateStopsProgram() throws {
        let script = directory.appendingPathComponent("sleep.sh")
        try "#!/bin/sh\nwhile true; do echo tick; sleep 0.2; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let session = try InteractiveProcess()
        let exited = expectation(description: "exited")
        session.onExit = { _ in exited.fulfill() }
        try session.launch(executable: script.path, arguments: [])

        // Let it start printing, then stop it.
        let deadline = Date().addingTimeInterval(10)
        while session.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        session.terminate()
        wait(for: [exited], timeout: 15)
    }
}

/// Verifies that the reported run time excludes time spent waiting for input.
@MainActor
final class RunTimeAccountingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPPTime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeScript(_ name: String, _ body: String) throws -> URL {
        let script = directory.appendingPathComponent(name)
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func run(_ script: URL, waitForPrompt: Bool, prompt: String = "") throws -> RunOutcome {
        let session = try InteractiveProcess()
        var replied = false
        let finished = expectation(description: "finished")
        var outcome: RunOutcome?
        session.onOutput = { text in
            guard waitForPrompt, !replied, text.contains(prompt) else { return }
            replied = true
            // The "user" takes a moment to type.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                session.send("")
            }
        }
        session.onExit = { result in
            outcome = result
            finished.fulfill()
        }
        try session.launch(executable: script.path, arguments: [])
        wait(for: [finished], timeout: 20)
        return try XCTUnwrap(outcome)
    }

    func testWaitingForInputIsExcludedFromRunTime() throws {
        let script = try makeScript("prompt.sh", """
        #!/bin/sh
        printf 'name? '
        read name
        echo "hello $name"
        """)
        let outcome = try run(script, waitForPrompt: true, prompt: "name?")
        XCTAssertEqual(outcome.exitCode, 0)
        // A shell that finishes instantly must not report the second spent
        // waiting for input.
        XCTAssertLessThan(outcome.duration, 0.55,
                          "input wait leaked into the run time: \(outcome.duration) s")
    }

    func testSleepingProgramIsNotCountedAsRunning() throws {
        // No input, but the program sleeps: sleeping is not running.
        let script = try makeScript("sleeper.sh", """
        #!/bin/sh
        sleep 1
        """)
        let started = Date()
        let outcome = try run(script, waitForPrompt: false)
        let wall = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertGreaterThan(wall, 0.9)
        XCTAssertLessThan(outcome.duration, 0.5,
                          "a sleeping program reported \(outcome.duration) s of running time")
    }
}

import XCTest
@testable import BuildKit

final class BuildServiceTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func writeSource(_ contents: String, name: String = "main.cpp") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func collect(_ stream: AsyncStream<BuildEvent>) async -> [BuildEvent] {
        var events: [BuildEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func firstAvailableCompiler(file: StaticString = #filePath, line: UInt = #line) throws -> CompilerInfo {
        guard let compiler = Toolchain.discoverCompilers().first else {
            throw XCTSkip("No C++ compiler available on this machine", file: file, line: line)
        }
        return compiler
    }

    func testBuildAndRunHelloWorld() async throws {
        let compiler = try firstAvailableCompiler()
        let sourceURL = try writeSource("""
        #include <iostream>
        int main() { std::cout << "ridecpp-ok" << std::endl; return 0; }
        """)
        let executable = temporaryDirectory.appendingPathComponent("hello-bin")
        let request = BuildRequest(action: .run,
                                   sourcePath: sourceURL.path,
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: compiler.path,
                                   standard: "c++17",
                                   outputPath: executable.path,
                                   workingDirectory: temporaryDirectory.path)
        let service = BuildService(scratchDirectory: temporaryDirectory)
        let events = await collect(service.perform(request))

        let output = eventsText(events)
        XCTAssertTrue(output.contains("ridecpp-ok"), "program output missing:\n\(output)")
        XCTAssertTrue(events.contains { event in
            if case .finished(_, let succeeded) = event { return succeeded }
            return false
        }, "build should report success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    }

    func testBuildFailureProducesDiagnostics() async throws {
        let compiler = try firstAvailableCompiler()
        let sourceURL = try writeSource("int main() { this is not c++ }")
        let executable = temporaryDirectory.appendingPathComponent("bad-bin")
        let request = BuildRequest(action: .build,
                                   sourcePath: sourceURL.path,
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: compiler.path,
                                   standard: "c++17",
                                   outputPath: executable.path,
                                   workingDirectory: temporaryDirectory.path)
        let service = BuildService(scratchDirectory: temporaryDirectory)
        let events = await collect(service.perform(request))

        XCTAssertTrue(events.contains { event in
            if case .finished(_, let succeeded) = event { return !succeeded }
            return false
        })
        let diagnostics = events.compactMap { event -> [Diagnostic]? in
            if case .diagnostics(let parsed) = event { return parsed }
            return nil
        }.flatMap { $0 }
        XCTAssertFalse(diagnostics.isEmpty, "expected diagnostics for invalid source")
        XCTAssertTrue(diagnostics.contains { $0.severity == .error })
        XCTAssertEqual(diagnostics.first?.file, sourceURL.path)
    }

    // MARK: - Interactive run

    /// Runs `service.perform(request)` while collecting events, and lets the
    /// test answer the program's prompts as they appear.
    private func runInteractively(_ request: BuildRequest,
                                  service: BuildService,
                                  answer: @escaping (String) -> String?) async -> (text: String, exit: Int32?) {
        var output = ""
        var exit: Int32?
        for await event in service.perform(request) {
            switch event {
            case .runOutput(let chunk):
                output += chunk
                if let reply = answer(output) {
                    service.send(input: reply)
                }
            case .runFinished(let code, _, _, _):
                exit = code
            default:
                break
            }
        }
        return (output, exit)
    }

    func testProgramPromptAppearsBeforeInput() async throws {
        // The prompt has no trailing newline and no flush: this only shows up
        // before the program exits because it runs on a pty.
        let compiler = try firstAvailableCompiler()
        let sourceURL = try writeSource("""
        #include <iostream>
        #include <string>
        int main() {
            std::cout << "Name? ";
            std::string name;
            std::getline(std::cin, name);
            std::cout << "Hello " << name << std::endl;
            return 0;
        }
        """)
        let executable = temporaryDirectory.appendingPathComponent("prompt-bin")
        let request = BuildRequest(action: .run,
                                   sourcePath: sourceURL.path,
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: compiler.path,
                                   standard: "c++17",
                                   outputPath: executable.path,
                                   workingDirectory: temporaryDirectory.path)
        let service = BuildService(scratchDirectory: temporaryDirectory)
        var sawPromptBeforeAnswering = false
        var answered = false
        let result = await runInteractively(request, service: service) { text in
            if !answered, text.contains("Name? ") {
                sawPromptBeforeAnswering = true
                answered = true
                return "RideCPP"
            }
            return nil
        }
        XCTAssertTrue(sawPromptBeforeAnswering, "prompt was not delivered before input")
        XCTAssertTrue(result.text.contains("Hello RideCPP"), "program did not receive the input: \(result.text)")
        XCTAssertEqual(result.exit, 0)
    }

    func testMultipleInputsCanBeSentWhileRunning() async throws {
        let compiler = try firstAvailableCompiler()
        let sourceURL = try writeSource("""
        #include <iostream>
        int main() {
            int a = 0, b = 0;
            std::cout << "first: ";
            std::cin >> a;
            std::cout << "second: ";
            std::cin >> b;
            std::cout << "sum=" << (a + b) << std::endl;
            return 0;
        }
        """)
        let executable = temporaryDirectory.appendingPathComponent("twice-bin")
        let request = BuildRequest(action: .run,
                                   sourcePath: sourceURL.path,
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: compiler.path,
                                   standard: "c++17",
                                   outputPath: executable.path,
                                   workingDirectory: temporaryDirectory.path)
        let service = BuildService(scratchDirectory: temporaryDirectory)
        var answersSent = 0
        let result = await runInteractively(request, service: service) { text in
            if answersSent == 0, text.contains("first:") { answersSent = 1; return "20" }
            if answersSent == 1, text.contains("second:") { answersSent = 2; return "22" }
            return nil
        }
        XCTAssertEqual(answersSent, 2, "program did not prompt twice: \(result.text)")
        XCTAssertTrue(result.text.contains("sum=42"), "unexpected output: \(result.text)")
    }

    func testInterruptStopsRunningProgram() async throws {
        let compiler = try firstAvailableCompiler()
        let sourceURL = try writeSource("""
        #include <iostream>
        #include <unistd.h>
        int main() {
            for (int i = 0; i < 200; ++i) { std::cout << "tick " << i << std::endl; usleep(50000); }
            return 0;
        }
        """)
        let executable = temporaryDirectory.appendingPathComponent("loop-bin")
        let request = BuildRequest(action: .run,
                                   sourcePath: sourceURL.path,
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: compiler.path,
                                   standard: "c++17",
                                   outputPath: executable.path,
                                   workingDirectory: temporaryDirectory.path)
        let service = BuildService(scratchDirectory: temporaryDirectory)
        let started = Date()
        // Stop soon after the first output instead of waiting ~10s.
        let task = Task { () -> String in
            var text = ""
            var stopped = false
            for await event in service.perform(request) {
                if case .runOutput(let chunk) = event {
                    text += chunk
                    if !stopped, text.contains("tick 0") {
                        stopped = true
                        service.send(input: "\u{03}")
                    }
                }
            }
            return text
        }
        let text = await task.value
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 30, "program was not interrupted")
        XCTAssertTrue(text.contains("tick 0"), "program never produced output")
        service.cancel()
    }

    func testMissingCompilerFailsGracefully() async {
        let sourceURL = try? writeSource("int main() {}")
        let request = BuildRequest(action: .build,
                                   sourcePath: sourceURL?.path ?? "/tmp/main.cpp",
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: "/nonexistent/clang++",
                                   standard: "c++17",
                                   outputPath: temporaryDirectory.appendingPathComponent("x").path,
                                   workingDirectory: temporaryDirectory.path)
        let service = BuildService(scratchDirectory: temporaryDirectory)
        let events = await collect(service.perform(request))
        XCTAssertTrue(events.contains { event in
            if case .failed = event { return true }
            return false
        })
    }

    func testScratchFileIsWrittenForUnsavedTabs() throws {
        let service = BuildService(scratchDirectory: temporaryDirectory)
        let tabID = UUID()
        let scratch = try service.prepareScratchFile(contents: "int main(){}",
                                                     tabID: tabID,
                                                     suggestedName: "Untitled 1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertEqual(try String(contentsOfFile: scratch.path, encoding: .utf8), "int main(){}")
        XCTAssertEqual(scratch.displayName, "Untitled 1.cpp")
    }

    func testCompileArgumentsShape() {
        let request = BuildRequest(action: .build,
                                   sourcePath: "/tmp/main.cpp",
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: "/usr/bin/clang++",
                                   standard: "c++20",
                                   optimization: "-O2",
                                   extraFlags: ["-Wall", "-Wextra"],
                                   outputPath: "/tmp/out",
                                   workingDirectory: "/tmp")
        let args = request.compileArguments
        XCTAssertEqual(args.first, "-std=c++20")
        XCTAssertTrue(args.contains("-g"))
        XCTAssertTrue(args.contains("-Wall"))
        XCTAssertTrue(args.contains("-Wextra"))
        XCTAssertEqual(args.last, "/tmp/out")
        XCTAssertTrue(request.displayCommand.contains("-std=c++20"))
    }

    func testDefaultOptimizationIsO2() {
        // Algorithm work needs optimisation on; -O0 used to be the default.
        let request = BuildRequest(action: .build,
                                   sourcePath: "/tmp/main.cpp",
                                   sourceDisplayName: "main.cpp",
                                   compilerPath: "/usr/bin/clang++",
                                   standard: "c++17",
                                   outputPath: "/tmp/out",
                                   workingDirectory: "/tmp")
        XCTAssertTrue(request.compileArguments.contains("-O2"),
                      "expected -O2 by default, got \(request.compileArguments)")
    }

    func testSanitizedFileName() {
        XCTAssertEqual(BuildService.sanitizedFileName("Untitled 1"), "Untitled 1.cpp")
        XCTAssertEqual(BuildService.sanitizedFileName("a/b:c.cpp"), "a_b_c.cpp")
        XCTAssertEqual(BuildService.sanitizedFileName("   "), "Untitled.cpp")
    }

    private func eventsText(_ events: [BuildEvent]) -> String {
        var text = ""
        for event in events {
            switch event {
            case .runOutput(let chunk): text += chunk
            case .compilerOutput: break
            case .finished(let code, let ok): text += "\n[finished \(code) \(ok)]\n"
            default: break
            }
        }
        return text
    }
}

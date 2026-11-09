import XCTest
@testable import NXCore

/// `ProcessRunner`: the real one against small system tools, and the helpers over a fake.
final class ProcessRunnerTests: XCTestCase {
    private let real = SystemProcessRunner()

    // MARK: The real runner

    func testCaptureKeepsStdoutAndStderrApart() {
        let r = real.capture(ProcessLaunch(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertTrue(r.started)
        XCTAssertEqual(r.status, 3)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.out, "out\n")
        XCTAssertEqual(r.err, "err\n")
    }

    func testRunQuietMergesBothStreams() {
        let r = real.runQuiet(["/bin/sh", "-c", "echo out; echo err >&2"], env: ["PATH": "/usr/bin:/bin"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(Set(r.out.split(separator: "\n")), ["out", "err"])
    }

    func testTheEnvironmentIsExactlyTheOneGiven() {
        let r = real.runQuiet(["/usr/bin/env"], env: ["ONLY": "this"])
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines), "ONLY=this")
    }

    func testTheDirectoryIsTheOneGiven() {
        let dir = NSTemporaryDirectory()
        let r = real.capture(ProcessLaunch(executable: "/bin/pwd", directory: dir))
        let printed = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path, URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
    }

    func testAToolThatDoesNotExistFailsToStartWithAReason() {
        let r = real.runQuiet(["/nonexistent/tool"], env: [:])
        XCTAssertFalse(r.started)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.out.isEmpty)
        XCTAssertFalse(real.runOK("/nonexistent/tool", []))
        XCTAssertNil(real.output("/nonexistent/tool", []))
    }

    func testRunOKAndOutputFollowTheExitStatus() {
        XCTAssertTrue(real.runOK("/usr/bin/true", []))
        XCTAssertFalse(real.runOK("/usr/bin/false", []))
        XCTAssertEqual(real.output("/bin/echo", ["hello"]), "hello\n")
        XCTAssertNil(real.output("/usr/bin/false", []))
    }

    func testCaptureDoesNotBlockOnAFullStderrPipe() {
        // Far more than a pipe holds, on the stream that is read second.
        let r = real.capture(ProcessLaunch(["/bin/sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo done"]))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.out, "done\n")
        XCTAssertEqual(r.err.count, 300000)
    }

    func testStreamGivesEachLineAndTheResult() {
        let lines = Collected()
        let ok = real.runCaptured(["/bin/sh", "-c", "echo one; echo two >&2; exit 0"], env: ["PATH": "/usr/bin:/bin"]) { lines.add($0) }
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(lines.values), ["one", "two"])
        XCTAssertFalse(real.runCaptured(["/usr/bin/false"], env: [:]) { _ in })
    }

    func testStreamGivesTheLastLinesOfAToolThatFailsAsItExits() {
        // the error comes last and the tool exits right after it: it is what EngineLayout.failureKind reads
        for _ in 0..<20 {
            let lines = Collected()
            let script = "i=0; while [ $i -lt 2000 ]; do echo progress $i; i=$((i+1)); done; echo 'engine.py: cannot fetch abc' >&2; exit 2"
            XCTAssertFalse(real.runCaptured(["/bin/sh", "-c", script], env: ["PATH": "/usr/bin:/bin"]) { lines.add($0) })
            XCTAssertEqual(lines.values.count, 2001)
            XCTAssertTrue(lines.values.contains("engine.py: cannot fetch abc"))
        }
    }

    func testStreamKeepsALineAndACharacterThatArriveInTwoReads() {
        let lines = Collected()
        // printf writes "gr", sleeps, then "üße\n" with the ü's two bytes split across the two writes
        let script = "printf 'gr\\303'; sleep 0.2; printf '\\274\\303\\237e\\n'; printf 'Receiving 50%%\\rReceiving 100%%, done.\\n'"
        XCTAssertTrue(real.runCaptured(["/bin/sh", "-c", script], env: ["PATH": "/usr/bin:/bin"]) { lines.add($0) })
        XCTAssertEqual(lines.values, ["grüße", "Receiving 50%", "Receiving 100%, done."])
    }

    func testLineSplitterJoinsReadsAndDropsEmptyLines() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(Data("one\ntw".utf8)), ["one"])
        XCTAssertEqual(s.feed(Data([0x6F, 0x0A, 0x0A, 0xC3])), ["two"])   // "o\n\n" and the first byte of "é"
        XCTAssertEqual(s.feed(Data([0xA9])), [])
        XCTAssertEqual(s.finish(), "é")
        XCTAssertNil(s.finish())
    }

    func testStreamReportsAToolThatDoesNotStartAsALine() {
        let lines = Collected()
        XCTAssertFalse(real.runCaptured(["/nonexistent/tool"], env: [:]) { lines.add($0) })
        XCTAssertEqual(lines.values.count, 1)
        XCTAssertTrue(lines.values[0].hasPrefix("could not start /nonexistent/tool"))
    }

    func testStartReportsOutputAndTheExitStatus() throws {
        let output = Collected(), exited = expectation(description: "exit")
        var status: Int32 = -1
        _ = try real.start(ProcessLaunch(["/bin/sh", "-c", "echo started; exit 5"]), onOutput: { output.add(String(decoding: $0, as: UTF8.self)) },
                           onExit: { status = $0; exited.fulfill() })
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(status, 5)
        let deadline = Date().addingTimeInterval(5)
        while !output.values.joined().contains("started") && Date() < deadline { usleep(20_000) }
        XCTAssertTrue(output.values.joined().contains("started"))
    }

    func testStartThrowsForAToolThatDoesNotExist() {
        XCTAssertThrowsError(try real.start(ProcessLaunch(["/nonexistent/tool"]), onOutput: { _ in }, onExit: { _ in }))
    }

    /// With a group the process leads a group of its own, and the group is tracked until it exits.
    func testStartInAGroupLeadsItsOwnGroupAndEndsWithIt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        let exited = expectation(description: "exit")
        let process = try real.start(ProcessLaunch(["/bin/sh", "-c", "sleep 30"], groupPython: "/usr/bin/python3"), onOutput: { _ in },
                                     onExit: { _ in exited.fulfill() })
        let pid = process.processIdentifier
        var tries = 0
        while getpgid(pid) != pid && tries < 100 { usleep(50_000); tries += 1 }
        XCTAssertEqual(getpgid(pid), pid, "the process is the leader of its own group")
        XCTAssertTrue(ProcessGroups.buildProcessesAlive)
        ProcessGroups.endGroup(pid)
        wait(for: [exited], timeout: 10)
        var alive = true
        tries = 0
        while alive && tries < 50 { alive = ProcessGroups.buildProcessesAlive; if alive { usleep(50_000) }; tries += 1 }
        XCTAssertFalse(alive, "an ended process is no longer tracked")
    }

    /// The exit is reported after the last output. Here a child writes the tool's real error after the tool has exited:
    /// reported from terminationHandler alone, the exit came first, and runTool took its failure message from what it had.
    func testStartHandsOutTheLastOutputBeforeTheExit() throws {
        let output = Collected(), exited = expectation(description: "exit")
        var atExit = ""
        _ = try real.start(ProcessLaunch(["/bin/sh", "-c", "(sleep 0.5; echo 'error: the real reason') & echo started; exit 1"]),
                           onOutput: { output.add(String(decoding: $0, as: UTF8.self)) },
                           onExit: { _ in atExit = output.values.joined(); exited.fulfill() })
        wait(for: [exited], timeout: 10)
        XCTAssertTrue(atExit.contains("error: the real reason"), "the exit came before the last output: \(atExit)")
    }

    /// The ordinary case, many times: a tool that prints a lot and its error last, then exits at once.
    func testStartGivesEveryLineBeforeTheExitOverManyRuns() throws {
        let script = "i=0; while [ $i -lt 1500 ]; do echo progress $i; i=$((i+1)); done; echo 'error: last' >&2; exit 2"
        for round in 0..<30 {
            let output = Collected(), exited = expectation(description: "exit \(round)")
            var atExit = "", status: Int32 = -1
            _ = try real.start(ProcessLaunch(["/bin/sh", "-c", script]), onOutput: { output.add(String(decoding: $0, as: UTF8.self)) },
                               onExit: { atExit = output.values.joined(); status = $0; exited.fulfill() })
            wait(for: [exited], timeout: 10)
            XCTAssertEqual(status, 2)
            XCTAssertTrue(atExit.hasSuffix("error: last\n"), "round \(round): the last line came after the exit")
            XCTAssertEqual(atExit.split(separator: "\n").count, 1501, "round \(round)")
        }
    }

    /// A child the tool leaves behind with the output open (the build's MSBuild workers) does not hold the exit back for
    /// longer than `outputGrace`.
    func testStartReportsTheExitWhenAChildKeepsTheOutputOpen() throws {
        let exited = expectation(description: "exit"), began = Date()
        var status: Int32 = -1
        _ = try real.start(ProcessLaunch(["/bin/sh", "-c", "sleep 8 & echo started; exit 4"]), onOutput: { _ in },
                           onExit: { status = $0; exited.fulfill() })
        wait(for: [exited], timeout: SystemProcessRunner.outputGrace + 4)
        XCTAssertEqual(status, 4)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), SystemProcessRunner.outputGrace - 0.5)
    }

    /// Every chunk decodes on its own: one large write of multi-byte characters is read in pieces that cut characters.
    func testStartHandsOutWholeCharactersOnly() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        let output = Collected(), undecodable = Collected(), exited = expectation(description: "exit")
        let write = "import sys; sys.stdout.buffer.write(('\\u00e9\\u4e2d\\U0001F600' * 40000).encode())"
        _ = try real.start(ProcessLaunch(["/usr/bin/python3", "-c", write]), onOutput: { d in
            if let s = String(data: d, encoding: .utf8) { output.add(s) } else { undecodable.add("\(d.count) bytes") }
        }, onExit: { _ in exited.fulfill() })
        wait(for: [exited], timeout: 30)
        XCTAssertEqual(undecodable.values, [], "chunks that end inside a character")
        XCTAssertEqual(output.values.joined(), String(repeating: "\u{e9}\u{4e2d}\u{1F600}", count: 40000))
    }

    func testUTF8ChunkerNeverCutsACharacter() {
        let text = "a\u{e9}\u{4e2d}\u{1F600}b\u{4e2d}"
        let bytes = Array(text.utf8)
        for first in 0...bytes.count {
            for second in first...bytes.count {
                var chunker = UTF8Chunker()
                var out = Data()
                for part in [bytes[..<first], bytes[first..<second], bytes[second...]] {
                    let chunk = chunker.feed(Data(part))
                    XCTAssertNotNil(String(data: chunk, encoding: .utf8), "cut at \(first) and \(second)")
                    out.append(chunk)
                }
                XCTAssertEqual(chunker.finish(), Data())
                XCTAssertEqual(String(data: out, encoding: .utf8), text)
            }
        }
    }

    func testUTF8ChunkerPassesOnBytesThatAreNotUTF8AndKeepsAnUnfinishedEnd() {
        var chunker = UTF8Chunker()
        XCTAssertEqual(chunker.feed(Data([0x61, 0xFF])), Data([0x61, 0xFF]))
        XCTAssertEqual(chunker.feed(Data([0x80, 0x80, 0x80])), Data([0x80, 0x80, 0x80]))
        XCTAssertEqual(chunker.feed(Data([0x62, 0xE4, 0xB8])), Data([0x62]))
        XCTAssertEqual(chunker.finish(), Data([0xE4, 0xB8]))
        XCTAssertEqual(chunker.finish(), Data())
    }

    /// A process that exits before start() tracks its group is not tracked: its PID would stay in the set, and quitting
    /// would signal whatever group has that number by then.
    func testAGroupWhoseProcessExitedFirstIsNotTracked() throws {
        let quick = Process()
        quick.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try quick.run(); quick.waitUntilExit()
        let early = GroupLife()
        early.ended(quick)     // its terminationHandler ran first
        early.started(quick)   // then start() went on
        XCTAssertFalse(ProcessGroups.isTracked(quick.processIdentifier))

        let slow = Process()
        slow.executableURL = URL(fileURLWithPath: "/bin/sleep"); slow.arguments = ["5"]
        try slow.run()
        defer { slow.terminate() }
        let life = GroupLife()
        life.started(slow)
        XCTAssertTrue(ProcessGroups.isTracked(slow.processIdentifier))
        life.ended(slow)
        XCTAssertFalse(ProcessGroups.isTracked(slow.processIdentifier))
    }

    // MARK: Timeout, input and whole lines

    func testCaptureEndsARunThatOutlastsItsTimeout() {
        let start = Date()
        let r = real.capture(ProcessLaunch(executable: "/bin/sleep", arguments: ["30"], timeout: 0.3))
        XCTAssertTrue(r.started)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testCaptureWithATimeoutLeavesAFastRunAlone() {
        let r = real.capture(ProcessLaunch(executable: "/bin/echo", arguments: ["quick"], timeout: 30))
        XCTAssertTrue(r.ok)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.out, "quick\n")
    }

    func testCaptureWritesTheInputToStandardInputAndClosesIt() {
        let r = real.capture(ProcessLaunch(executable: "/bin/cat", input: "from the test\nsecond"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.out, "from the test\nsecond")
    }

    func testStreamLinesAssemblesWholeLinesAcrossChunksAndKeepsEmptyOnes() {
        let lines = Collected()
        var started = 0
        let r = real.streamLines(ProcessLaunch(["/bin/sh", "-c", "printf 'a'; sleep 0.2; printf 'b\\n\\nc\\n'; echo err >&2; printf 'tail'"]),
                                 started: { _ in started += 1 }) { lines.add($0) }
        XCTAssertTrue(r.started)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(started, 1)
        XCTAssertEqual(lines.values.filter { $0 != "err" }, ["ab", "", "c", "tail"], "stderr is merged in, so 'err' may sit anywhere")
        XCTAssertTrue(lines.values.contains("err"))
    }

    func testStreamLinesGivesTheExitStatusAndReportsAToolThatDoesNotStart() {
        XCTAssertEqual(real.streamLines(ProcessLaunch(["/bin/sh", "-c", "exit 7"]), started: { _ in }, line: { _ in }).status, 7)
        var started = false
        let r = real.streamLines(ProcessLaunch(["/nonexistent/tool"]), started: { _ in started = true }, line: { _ in })
        XCTAssertFalse(r.started)
        XCTAssertFalse(r.out.isEmpty)
        XCTAssertFalse(started)
    }

    func testStreamLinesInAGroupIsTrackedWhileItRunsAndLetGoAfter() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        var alive = false
        let r = real.streamLines(ProcessLaunch(["/bin/sh", "-c", "sleep 0.3"], groupPython: "/usr/bin/python3"),
                                 started: { p in
                                     var tries = 0
                                     while getpgid(p.processIdentifier) != p.processIdentifier && tries < 100 { usleep(20_000); tries += 1 }
                                     alive = ProcessGroups.buildProcessesAlive
                                 }, line: { _ in })
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(alive, "the group is tracked while the tool runs")
        XCTAssertFalse(ProcessGroups.buildProcessesAlive)
    }

    // MARK: The helpers over a fake

    func testRunQuietAsksForOneMergedRunWithTheGivenEnvironment() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(out: "hi") }
        let r = fake.runQuiet(["/usr/bin/git", "status"], env: ["A": "1"])
        XCTAssertEqual(r.out, "hi")
        XCTAssertEqual(fake.commands, ["git status"])
        XCTAssertTrue(fake.launches[0].mergesErrors)
        XCTAssertEqual(fake.launches[0].environment, ["A": "1"])
    }

    func testRunOKAndOutputReadTheFakesAnswer() {
        let fake = FakeProcessRunner()
        fake.answer = { $0.executable == "/good" ? ProcessResult(out: "yes\n") : ProcessResult(status: 1) }
        XCTAssertTrue(fake.runOK("/good", []))
        XCTAssertFalse(fake.runOK("/bad", []))
        XCTAssertEqual(fake.output("/good", []), "yes\n")
        XCTAssertNil(fake.output("/bad", []))
    }

    // MARK: A service that takes the runner

    func testToolchainReadsTheDeveloperDirectoryThroughTheRunner() throws {
        let fake = FakeProcessRunner()
        let folder = NSTemporaryDirectory()
        fake.answer = { _ in ProcessResult(out: folder + "\n") }
        XCTAssertEqual(Toolchain.developerDir(runner: fake), folder)
        XCTAssertEqual(fake.commands, ["xcode-select -p"])
        fake.answer = { _ in ProcessResult(status: 1) }
        XCTAssertNil(Toolchain.developerDir(runner: fake))
    }

    func testToolchainParsesThePythonVersionFromTheRunner() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(out: "3.12\n") }
        let v = Toolchain.pythonVersion("/fake/python3", runner: fake)
        XCTAssertEqual(v?.0, 3)
        XCTAssertEqual(v?.1, 12)
        fake.answer = { _ in ProcessResult(out: "not a version") }
        XCTAssertNil(Toolchain.pythonVersion("/fake/python3", runner: fake))
        fake.answer = { _ in .failedToStart("no such file") }
        XCTAssertNil(Toolchain.pythonVersion("/fake/python3", runner: fake))
    }

    func testToolchainTakesTheFirstLineOfAToolsOutput() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(out: "Apple metal version 32023\nTarget: air64\n") }
        XCTAssertEqual(Toolchain.firstOutputLine("/usr/bin/xcrun", ["metal", "--version"], runner: fake), "Apple metal version 32023")
        XCTAssertEqual(fake.commands, ["xcrun metal --version"])
    }

    func testMakeVenvLogsWhatTheToolsPrintAndStopsWhenOneFails() {
        let fake = FakeProcessRunner()
        fake.answer = { _ in ProcessResult(status: 1, out: "so far", err: "externally-managed-environment") }
        let r = Toolchain.makeVenv(base: "/fake/python3", runner: fake)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.log.contains("externally-managed-environment"))
    }
}

/// Lines from a pipe's threads, read afterwards.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var box: [String] = []
    func add(_ s: String) { lock.lock(); box.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return box }
}

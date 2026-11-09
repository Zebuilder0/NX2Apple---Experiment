import Foundation

/// What to start: the tool, its arguments and where it runs. Standard input is always empty for a captured or streamed run.
package struct ProcessLaunch {
    package var executable: String
    package var arguments: [String]
    /// nil: the app's own environment.
    package var environment: [String: String]?
    package var directory: String?
    /// stderr goes into the same stream as stdout.
    package var mergesErrors = false
    /// Start in a process group of its own, through this Python (`ProcessGroups`). nil: no group.
    package var groupPython: String?
    /// A captured run that is still going after this many seconds is ended (SIGTERM, then SIGKILL 2 s later) and reports `timedOut`.
    package var timeout: TimeInterval?
    /// Written to standard input of a captured run, which is then closed. nil: standard input is empty.
    package var input: String?

    package init(executable: String, arguments: [String] = [], environment: [String: String]? = nil, directory: String? = nil,
                 mergesErrors: Bool = false, groupPython: String? = nil, timeout: TimeInterval? = nil, input: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.directory = directory
        self.mergesErrors = mergesErrors; self.groupPython = groupPython; self.timeout = timeout; self.input = input
    }

    /// `command[0]` is the tool, the rest its arguments.
    package init(_ command: [String], environment: [String: String]? = nil, directory: String? = nil,
                 mergesErrors: Bool = false, groupPython: String? = nil) {
        self.init(executable: command[0], arguments: Array(command.dropFirst()), environment: environment, directory: directory,
                  mergesErrors: mergesErrors, groupPython: groupPython)
    }
}

/// How a captured run ended. A process that could not start is `started == false` with the reason in `out`.
package struct ProcessResult: Equatable {
    package var started: Bool
    package var status: Int32
    package var out: String
    package var err: String
    /// The run was ended because it outlasted `ProcessLaunch.timeout`.
    package var timedOut: Bool
    package var ok: Bool { started && status == 0 && !timedOut }

    package init(started: Bool = true, status: Int32 = 0, out: String = "", err: String = "", timedOut: Bool = false) {
        self.started = started; self.status = status; self.out = out; self.err = err; self.timedOut = timedOut
    }

    package static func failedToStart(_ reason: String) -> ProcessResult { ProcessResult(started: false, status: -1, out: reason) }
}

/// A process the runner started and that has not ended yet (Stop reads its identifier).
package protocol RunningProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
}

extension Process: RunningProcess {}

/// The only place that starts a process: process groups, environment and captured output. A service takes one through its
/// initializer, so a test passes in a fake that answers without starting anything.
package protocol ProcessRunner {
    /// Run to the end and capture the output (blocking).
    func capture(_ launch: ProcessLaunch) -> ProcessResult
    /// Run to the end and hand each output line to `line` as it arrives (blocking). true when it exited 0.
    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool
    /// Run to the end with stdout and stderr merged and hand out every whole line, empty ones too, a last line without its newline
    /// included (blocking). `started` gets the process right after it starts, for a caller that can end it (Stop). With
    /// `groupPython` the process leads a group of its own that `ProcessGroups` tracks until it exits. A process that could not
    /// start is `started == false` with the reason in `out`, and `started` is not called.
    func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult
    /// Start and return at once. `onOutput` gets the combined output in chunks on a background queue, each ending on a whole
    /// UTF-8 character, and `onExit` the exit status once the output has ended too, so after the last `onOutput` (unless a
    /// child the process left behind keeps the output open: see `SystemProcessRunner.outputGrace`).
    /// With `groupPython` the process is the leader of a group of its own that `ProcessGroups` tracks until it exits.
    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess
}

extension ProcessRunner {
    /// All output captured, none streamed (fetch, rev-list and pull print little). A failure to start is `ok == false`, its reason in `out`.
    package func runQuiet(_ args: [String], env: [String: String]) -> ProcessResult {
        capture(ProcessLaunch(args, environment: env, mergesErrors: true))
    }

    /// Whether the tool exits 0, its output thrown away.
    package func runOK(_ tool: String, _ args: [String], env: [String: String]? = nil) -> Bool {
        capture(ProcessLaunch(executable: tool, arguments: args, environment: env)).ok
    }

    /// The tool's stdout when it exits 0, nil when it does not start or fails.
    package func output(_ tool: String, _ args: [String], env: [String: String]? = nil) -> String? {
        let r = capture(ProcessLaunch(executable: tool, arguments: args, environment: env))
        return r.ok ? r.out : nil
    }

    /// Stream the output line by line. A failure to start is reported as a line and returns false.
    package func runCaptured(_ args: [String], env: [String: String], line: @escaping (String) -> Void) -> Bool {
        stream(ProcessLaunch(args, environment: env), line: line)
    }
}

/// Starts real processes.
package struct SystemProcessRunner: ProcessRunner {
    package init() {}

    private func process(_ launch: ProcessLaunch) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.arguments
        if let env = launch.environment { p.environment = env }
        if let dir = launch.directory { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        return p
    }

    package func capture(_ launch: ProcessLaunch) -> ProcessResult {
        let p = process(launch)
        let stdin = Pipe()
        p.standardInput = launch.input == nil ? FileHandle.nullDevice : stdin
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = launch.mergesErrors ? out : err
        do { try p.run() } catch { return .failedToStart(error.localizedDescription) }
        let deadline = launch.timeout.map { Deadline(p, after: $0) }
        if let input = launch.input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Both pipes are drained before the exit is awaited, so the child cannot block on a full pipe.
        let errData = LockedData()
        let drained = DispatchGroup()
        if !launch.mergesErrors {
            drained.enter()
            DispatchQueue.global().async { errData.set(err.fileHandleForReading.readDataToEndOfFile()); drained.leave() }
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        p.waitUntilExit()
        deadline?.cancel()
        return ProcessResult(status: p.terminationStatus, out: String(data: outData, encoding: .utf8) ?? "",
                             err: String(data: errData.value, encoding: .utf8) ?? "", timedOut: deadline?.fired ?? false)
    }

    package func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
        let p = process(launch)
        p.standardInput = FileHandle.nullDevice
        if let python = launch.groupPython { ProcessGroups.inOwnGroup(p, python: python) }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return .failedToStart(error.localizedDescription) }
        if launch.groupPython != nil { ProcessGroups.track(p) }
        started(p)
        var pending = ""
        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            pending += String(decoding: data, as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                line(String(pending[..<nl]))
                pending = String(pending[pending.index(after: nl)...])
            }
        }
        if !pending.isEmpty { line(pending) }
        p.waitUntilExit()
        if launch.groupPython != nil { ProcessGroups.untrack(p) }
        return ProcessResult(status: p.terminationStatus)
    }

    package func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
        let p = process(launch)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { line("could not start \(launch.executable): \(error.localizedDescription)"); return false }
        // Both pipes are read to their end on background queues before the exit is awaited, as capture() reads them. The
        // handlers this used to attach were removed right after the exit, which could leave the last output unread: the
        // error line of a failing sync, clone or pip, which EngineLayout.failureKind reads to tell "offline" from
        // "broken". Each read was also decoded on its own, so a line cut between two reads came out as two lines, and a
        // read that ended inside a multi-byte character did not decode and was dropped whole.
        let lock = NSLock()
        let drained = DispatchGroup()
        for h in [out.fileHandleForReading, err.fileHandleForReading] {
            drained.enter()
            DispatchQueue.global().async {
                var lines = LineSplitter()
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    for l in lines.feed(d) { lock.lock(); line(l); lock.unlock() }
                }
                if let rest = lines.finish() { lock.lock(); line(rest); lock.unlock() }
                drained.leave()
            }
        }
        drained.wait()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// How long after its exit a started process's exit is reported when its output has not ended by then: a child it left
    /// behind still holds the pipe. The build's `dotnet` leaves MSBuild workers running (`/nodeReuse:true`, which
    /// engine/scripts/regress.py skips as known leftovers), and waiting for them would hold the end of a build for minutes.
    package static let outputGrace: TimeInterval = 2

    package func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        let p = process(launch)
        if let python = launch.groupPython { ProcessGroups.inOwnGroup(p, python: python) }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        // The exit used to be reported from terminationHandler alone, which can run while the end of the output is still in
        // the pipe: runTool then took its failure message from a line before the real error, or none ("exit code 1"). Each
        // read was also handed out as it came, and a caller that decodes a chunk on its own dropped one that ended inside
        // a character.
        let gate = ExitAfterOutput(grace: Self.outputGrace, onExit: onExit)
        var chunks = UTF8Chunker()   // the read handler runs one read at a time, and only it touches this
        PipeReader.attach(to: pipe.fileHandleForReading, onData: { d in
            let whole = chunks.feed(d)
            if !whole.isEmpty { onOutput(whole) }
        }, onEnd: {
            let rest = chunks.finish()
            if !rest.isEmpty { onOutput(rest) }
            gate.endOfOutput()
        })
        // A group is tracked from start to exit. A process can exit before run() returns here: tracking it after its
        // terminationHandler has run would leave its PID in the set for good, and endAll at quit would signal whatever
        // process group has that number by then.
        let group = GroupLife()
        p.terminationHandler = { done in
            group.ended(done)
            gate.exited(done.terminationStatus)
        }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        if launch.groupPython != nil { group.started(p) }
        return p
    }
}

/// A started process's group in `ProcessGroups`: tracked after run() unless the process has already exited, let go when it exits.
final class GroupLife: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false, tracked = false

    func started(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        if !exited { ProcessGroups.track(p); tracked = true }
    }

    func ended(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        exited = true
        if tracked { ProcessGroups.untrack(p); tracked = false }
    }
}

/// Reports a started process's exit once its output has ended as well, so the exit comes after the last output. If the
/// output has not ended `grace` seconds after the exit (a child of the process holds the pipe), the exit is reported then.
final class ExitAfterOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var outputEnded = false, status: Int32?, reported = false
    private let grace: TimeInterval
    private let onExit: (Int32) -> Void

    init(grace: TimeInterval, onExit: @escaping (Int32) -> Void) {
        self.grace = grace; self.onExit = onExit
    }

    func endOfOutput() {
        lock.lock(); outputEnded = true; let s = status; lock.unlock()
        if let s { report(s) }
    }

    func exited(_ s: Int32) {
        lock.lock(); status = s; let ended = outputEnded; lock.unlock()
        if ended { report(s); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { self.report(s) }
    }

    private func report(_ s: Int32) {
        lock.lock(); let first = !reported; reported = true; lock.unlock()
        if first { onExit(s) }
    }
}

/// Cuts output into chunks that end on a whole UTF-8 character: the first bytes of a character a read stops inside are kept
/// for the next read, so a chunk decoded on its own never holds half a character.
package struct UTF8Chunker {
    private var pending = Data()

    package init() {}

    /// What `data` (after what was kept back) holds up to its last whole character.
    package mutating func feed(_ data: Data) -> Data {
        pending.append(data)
        let cut = Self.wholeLength(pending)
        let out = Data(pending.prefix(cut))
        pending = Data(pending.dropFirst(cut))
        return out
    }

    /// What is left at the end of output: the start of a character that never got its last bytes, or nothing.
    package mutating func finish() -> Data {
        defer { pending = Data() }
        return pending
    }

    /// The length of `d` without an unfinished character at its end. Bytes that are not UTF-8 are not held back: the
    /// decoder deals with them.
    static func wholeLength(_ d: Data) -> Int {
        let tail = [UInt8](d.suffix(3))
        var back = 0
        while back < tail.count {
            let b = tail[tail.count - 1 - back]
            if b & 0xC0 != 0x80 {   // the first byte of the last character
                return back + 1 < sequenceLength(b) ? d.count - back - 1 : d.count
            }
            back += 1
        }
        return d.count
    }

    /// How many bytes the character that starts with `first` has (1 for a byte that cannot start one).
    static func sequenceLength(_ first: UInt8) -> Int {
        if first & 0xE0 == 0xC0 { return 2 }
        if first & 0xF0 == 0xE0 { return 3 }
        if first & 0xF8 == 0xF0 { return 4 }
        return 1
    }
}

/// Cuts output into lines in bytes and decodes each whole line, so a line or a UTF-8 character that arrives in two reads
/// stays one. A line ends at "\n", and at "\r", which progress output such as `git clone --progress` uses to redraw its
/// line (each redraw is a line then, as a terminal shows it). Empty lines are dropped, as stream() always did.
package struct LineSplitter {
    private var pending = Data()

    package init() {}

    /// The lines that `data` completes.
    package mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        var i = start
        while i < pending.endIndex {
            let b = pending[i]
            if b == 0x0A || b == 0x0D {
                if i > start { lines.append(String(decoding: pending[start..<i], as: UTF8.self)) }
                start = pending.index(after: i)
            }
            i = pending.index(after: i)
        }
        pending = Data(pending[start..<pending.endIndex])
        return lines
    }

    /// The last line, when the output ended without a line end.
    package mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// The data a background read leaves for the thread that waits for it.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Ends a process that outlasts its time: SIGTERM at the deadline, SIGKILL 2 s later when it still runs. Cancelled when the run ends.
private final class Deadline: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false
    private var work: DispatchWorkItem?

    init(_ p: Process, after seconds: TimeInterval) {
        let item = DispatchWorkItem { [self] in
            lock.lock(); didFire = true; lock.unlock()
            if p.isRunning { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() { work?.cancel() }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return didFire }
}

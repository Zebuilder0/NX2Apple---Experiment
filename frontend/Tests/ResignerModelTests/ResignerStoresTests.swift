import XCTest
@testable import NXCore
@testable import ResignerCore
@testable import ResignerModel

/// A process runner that records what ran and answers every command with the same result.
final class RecordingRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var ran: [[String]] = []
    var result = ProcessResult(status: 0, out: "done")
    var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return ran }

    func capture(_ launch: ProcessLaunch) -> ProcessResult {
        lock.lock(); ran.append([launch.executable] + launch.arguments); lock.unlock()
        return result
    }
    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { capture(launch).ok }
    func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult { capture(launch) }
    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        throw NSError(domain: "RecordingRunner", code: 1)
    }
}

final class FakeProcess: RunningProcess {
    var processIdentifier: Int32 = 4242
    var isRunning = true
}

/// Facts made by hand: a shell root with one game, an iPad, a team.
func madeUpFacts(device: String = "00008112-001A2B3C4D5E6F70", team: String = "TEAM123456") -> EnvironmentFacts {
    let library = ShellLibrary(bundleID: "org.nxnative.shell", team: team, games: [.init(titleID: "0100000000010000", name: "Test Game", framework: "/f")])
    let app = ShellApp(path: "/r/derived-data/Build/Products/Release-iphoneos/DmShell.app", bundleID: "org.nxnative.shell", displayName: "NX2Apple",
                       version: "1.0", games: [EmbeddedGame(titleID: "0100000000010000", name: "Test Game", framework: "DmGame0100000000010000.framework")])
    var f = EnvironmentFacts(shell: ShellInspection(root: "/r", rootExists: true, library: library, app: app, appPath: app.path,
                                                    project: ShellProject(path: "/r/project/DmShell.xcodeproj", exists: true, derivedDataExists: true)))
    f.devices = [DeviceStatus(udid: device, name: "Jane's iPad", model: "iPad Pro", osVersion: "26.1", transport: "wired", developerMode: true)]
    f.selectedDevice = device
    f.selectedTeam = team
    f.teams = [SigningTeam(id: team, identity: "Apple Development: Jane Appleseed (ABCDE12345)", name: "Jane Appleseed")]
    f.certificates = [CertificateRecord(sha1: "0123456789ABCDEF0123456789ABCDEF01234567", commonName: "Apple Development: Jane Appleseed (ABCDE12345)",
                                        team: team, notAfter: Date().addingTimeInterval(86400 * 100),
                                        identity: IdentityRecord(sha1: "0123456789ABCDEF0123456789ABCDEF01234567", name: "Apple Development: Jane Appleseed (ABCDE12345)"))]
    return f
}

@MainActor
final class ResignerSettingsTests: XCTestCase {
    func testTheFirstRunTakesTheLaunchersChoicesAndNeverWritesThem() {
        let launcher = TestDefaults.make("launcher")
        launcher.set("/Volumes/Games/NX2Apple-cache", forKey: "shellRoot")
        launcher.set("00008112-001A2B3C4D5E6F70", forKey: "installDevice")
        launcher.set("TEAM123456", forKey: "signingTeam")
        let before = launcher.dictionaryRepresentation().filter { ["shellRoot", "installDevice", "signingTeam"].contains($0.key) }.count
        let settings = ResignerSettings(defaults: TestDefaults.make("resigner"), launcher: launcher, home: "/Users/jane")
        XCTAssertEqual(settings.shellRoot, "/Volumes/Games/NX2Apple-cache")
        XCTAssertEqual(settings.device, "00008112-001A2B3C4D5E6F70")
        XCTAssertEqual(settings.team, "TEAM123456")
        XCTAssertEqual(settings.route, .automatic)
        XCTAssertEqual(settings.configuration, "Release")
        settings.team = "OTHER12345"
        settings.shellRoot = "/elsewhere"
        XCTAssertEqual(launcher.string(forKey: "signingTeam"), "TEAM123456", "the launcher's settings are only read")
        XCTAssertEqual(launcher.dictionaryRepresentation().filter { ["shellRoot", "installDevice", "signingTeam"].contains($0.key) }.count, before)
        settings.useLauncherShellRoot()
        XCTAssertEqual(settings.shellRoot, "/Volumes/Games/NX2Apple-cache")
    }

    func testSavedChoicesWinAndMapToTheProbe() {
        let own = TestDefaults.make("resigner")
        let first = ResignerSettings(defaults: own, launcher: nil, home: "/Users/jane")
        XCTAssertEqual(first.shellRoot, "/Users/jane/Library/Application Support/NX2Apple/shell", "without the launcher's settings, its default folder")
        first.route = .profile; first.developerDir = "/Applications/Xcode-27.2.app/Contents/Developer"; first.configuration = "Debug"
        first.profile = "UUID"; first.bundleID = "org.nxnative.shell.TEAM123456"; first.verboseLog = true
        let again = ResignerSettings(defaults: own, launcher: nil, home: "/Users/jane")
        let request = again.probeRequest()
        XCTAssertEqual(request.route, .profile)
        XCTAssertEqual(request.developerDir, "/Applications/Xcode-27.2.app/Contents/Developer")
        XCTAssertEqual(request.configuration, "Debug")
        XCTAssertEqual(request.profile, "UUID")
        XCTAssertEqual(request.bundleID, "org.nxnative.shell.TEAM123456")
        XCTAssertTrue(again.verboseLog)
        again.developerDir = ""
        XCTAssertNil(again.probeRequest().developerDir, "empty means xcode-select's Xcode")
    }
}

@MainActor
final class EnvironmentStoreTests: XCTestCase {
    func settings() -> ResignerSettings { ResignerSettings(defaults: TestDefaults.make("resigner"), launcher: nil, home: "/Users/jane") }

    func testACheckPublishesTheRowsAndSettlesTheChoices() async {
        let s = settings()
        let store = EnvironmentStore(settings: s, runner: RecordingRunner(), read: { _ in madeUpFacts() })
        await store.check().value
        XCTAssertFalse(store.checking)
        XCTAssertNotNil(store.lastChecked)
        XCTAssertEqual(store.facts?.device?.name, "Jane's iPad")
        XCTAssertFalse(store.items.isEmpty)
        XCTAssertEqual(s.device, "00008112-001A2B3C4D5E6F70", "the device the probe found becomes the choice")
        XCTAssertEqual(s.team, "TEAM123456")
    }

    func testACheckAskedForDuringOneRunsOnceMore() async {
        let reads = LockedCounter()
        let store = EnvironmentStore(settings: settings(), runner: RecordingRunner(), read: { _ in reads.add(); Thread.sleep(forTimeInterval: 0.05); return madeUpFacts() })
        let first = store.check()
        store.check()
        store.check()
        await first.value
        XCTAssertEqual(reads.value, 2, "the requests during the first check become one more check, not two")
    }

    func testTheTrialSignatureCountsForItsIdentityOnly() async throws {
        let store = EnvironmentStore(settings: settings(), runner: RecordingRunner(), read: { _ in madeUpFacts() },
                                     trialSign: { _, _ in .keyAccessDenied("errSecInternalComponent") })
        await store.check().value
        XCTAssertEqual(store.items.first { $0.id == "signing.test" }?.status, .notChecked)
        try await XCTUnwrap(store.testSign()).value
        XCTAssertEqual(store.items.first { $0.id == "signing.test" }?.status, .misconfigured)
    }

    func testAFixRunsItsCommandAndChecksAgain() async throws {
        let runner = RecordingRunner()
        let reads = LockedCounter()
        let store = EnvironmentStore(settings: settings(), runner: runner, read: { _ in reads.add(); return madeUpFacts() })
        XCTAssertNil(store.fix(.openURL("https://example.com"), row: "x"), "the app opens links itself")
        try await XCTUnwrap(store.fix(.runTool(["/usr/bin/xcodebuild", "-downloadPlatform", "iOS"]), row: "xcode.iosSDK")).value
        XCTAssertEqual(runner.commands, [["/usr/bin/xcodebuild", "-downloadPlatform", "iOS"]])
        XCTAssertEqual(reads.value, 1)
        XCTAssertNil(store.fixing)
        runner.result = ProcessResult(status: 1, out: "error: the download failed")
        try await XCTUnwrap(store.fix(.runTool(["/usr/bin/xcodebuild", "-downloadPlatform", "iOS"]), row: "xcode.iosSDK")).value
        XCTAssertEqual(store.fixNote, LocalText("resigner.fix.failed", "error: the download failed"))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class ResignStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var settings: ResignerSettings!
    var environment: EnvironmentStore!
    var reads: LockedCounter!

    override func setUp() async throws {
        defaults = TestDefaults.make("resigner")
        settings = ResignerSettings(defaults: defaults, launcher: nil, home: "/Users/jane")
        settings.device = "00008112-001A2B3C4D5E6F70"
        reads = LockedCounter()
        let reads = reads!
        environment = EnvironmentStore(settings: settings, runner: RecordingRunner(), read: { _ in reads.add(); return madeUpFacts() })
    }

    func store(_ perform: @escaping (ResignRequest, PipelineHooks) -> ResignOutcome, terminate: @escaping (RunningProcess) -> Void = { _ in }) -> ResignStore {
        ResignStore(settings: settings, environment: environment, log: ResignLog(redactor: LogRedactor(home: "/Users/jane", user: "jane")),
                    defaults: defaults, perform: perform, terminate: terminate)
    }

    static func success(_ request: ResignRequest, _ hooks: PipelineHooks) -> ResignOutcome {
        for step in ResignStep.allCases.dropLast() { hooks.step(step, .running, nil); hooks.step(step, .done, nil) }
        hooks.step(.completed, .done, nil)
        hooks.log("copying /Users/jane/Library/Application Support/NX2Apple/shell\n")
        var o = ResignOutcome()
        o.ok = true; o.route = .xcode; o.bundleID = "org.nxnative.shell"; o.team = "TEAM123456"; o.deviceName = "Jane's iPad"
        o.deviceUDID = request.probe.device; o.profileExpiry = Date().addingTimeInterval(7 * 86400)
        return o
    }

    static func failing(_ kind: ResignFailureKind) -> (ResignRequest, PipelineHooks) -> ResignOutcome {
        { _, hooks in
            hooks.step(.checkingEnvironment, .running, nil)
            var o = ResignOutcome()
            o.failure = ResignFailure(step: .signing, kind: kind, message: LocalText("resigner.fail.cancelled"))
            hooks.step(.signing, .failed, o.failure?.message)
            return o
        }
    }

    func testASuccessfulRunKeepsItsRecordAndChecksAgain() async throws {
        let s = store(Self.success)
        try await XCTUnwrap(s.start()).value
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.outcome?.ok, true)
        XCTAssertEqual(s.steps.map(\.state), Array(repeating: .done, count: ResignStep.allCases.count))
        XCTAssertEqual(s.progress, 1)
        XCTAssertEqual(s.lastRecord?.team, "TEAM123456")
        XCTAssertTrue(s.log.text.contains("~/Library/Application Support/NX2Apple/shell"), "the log is redacted as it is written")
        XCTAssertFalse(s.log.text.contains("/Users/jane"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reads.value, 1, "the dashboard reads the renewed profile")
        let again = ResignStore(settings: settings, environment: environment, log: ResignLog(), defaults: defaults, perform: Self.success)
        XCTAssertEqual(again.lastRecord?.deviceName, "Jane's iPad", "the record survives a restart")
        XCTAssertEqual(again.knownDeviceTeam, "TEAM123456")
    }

    func testEachRunReadsTheEnvironmentAfreshAndPassesTheSettings() async throws {
        var seen: ResignRequest?
        settings.route = .profile; settings.verboseLog = true
        let s = store { request, hooks in seen = request; return Self.success(request, hooks) }
        try await XCTUnwrap(s.start()).value
        XCTAssertEqual(seen?.probe.route, .profile)
        XCTAssertEqual(seen?.verbose, true)
        XCTAssertEqual(seen?.allowWithoutMemoryLimit, false)
        XCTAssertEqual(seen?.allowFirstInstall, false)
    }

    func testTheMemoryLimitQuestionIsAnsweredForOneRun() async throws {
        var requests: [ResignRequest] = []
        var answer = Self.failing(.memoryCapability)
        let s = store { request, hooks in requests.append(request); return answer(request, hooks) }
        XCTAssertNil(s.retryWithoutMemoryLimit(), "only after the question was asked")
        try await XCTUnwrap(s.start()).value
        XCTAssertEqual(s.outcome?.failure?.kind, .memoryCapability)
        XCTAssertNil(s.confirmFirstInstall(), "another question was asked")
        answer = Self.success
        try await XCTUnwrap(s.retryWithoutMemoryLimit()).value
        XCTAssertEqual(requests.map(\.allowWithoutMemoryLimit), [false, true])
        try await XCTUnwrap(s.start()).value
        XCTAssertEqual(requests.last?.allowWithoutMemoryLimit, false, "the answer is not remembered")
    }

    func testTheFirstInstallQuestion() async throws {
        var requests: [ResignRequest] = []
        let s = store { request, hooks in requests.append(request); return Self.failing(.firstInstall)(request, hooks) }
        try await XCTUnwrap(s.start()).value
        try await XCTUnwrap(s.confirmFirstInstall()).value
        XCTAssertEqual(requests.map(\.allowFirstInstall), [false, true])
    }

    func testAFailureThatNamesADependencyChecksAgain() async throws {
        let s = store(Self.failing(.dependency))
        try await XCTUnwrap(s.start()).value
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(s.steps.first { $0.step == .signing }?.state, .failed)
        XCTAssertNil(s.lastRecord)
    }

    func testStopEndsTheToolAndTheRunBeforeTheInstall() async throws {
        let process = FakeProcess()
        var terminated = false
        let s = store({ _, hooks in
            hooks.step(.signing, .running, nil)
            hooks.processStarted(process)
            let deadline = Date().addingTimeInterval(5)
            while !hooks.cancelled(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            var o = ResignOutcome()
            o.failure = ResignFailure(step: .signing, kind: .cancelled, message: LocalText("resigner.fail.cancelled"))
            return o
        }, terminate: { _ in terminated = true })
        let task = try XCTUnwrap(s.start())
        XCTAssertNil(s.start(), "one run at a time")
        while s.current != .signing { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(s.canStop)
        s.stop()
        XCTAssertTrue(s.stopping)
        await task.value
        XCTAssertTrue(terminated)
        XCTAssertEqual(s.outcome?.failure?.kind, .cancelled)
        XCTAssertFalse(s.running)
    }

    func testNoStopDuringTheInstall() async throws {
        let gate = DispatchSemaphore(value: 0)
        let s = store { request, hooks in
            hooks.step(.installing, .running, nil)
            _ = gate.wait(timeout: .now() + 5)
            return Self.success(request, hooks)
        }
        let task = try XCTUnwrap(s.start())
        while s.current != .installing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(s.canStop)
        s.stop()
        XCTAssertFalse(s.stopping)
        gate.signal()
        await task.value
        XCTAssertEqual(s.outcome?.ok, true)
    }

    func testTheDiagnosticsExportIsRedactedAndHoldsNoCredential() async throws {
        await environment.check().value
        let s = store(Self.success)
        try await XCTUnwrap(s.start()).value
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "resigner-diagnostics-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try s.exportDiagnostics(to: url, appVersion: "1.0", t: { $0 })
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("== dependencies =="))
        XCTAssertTrue(text.contains("resigner.dep.device.name: ok"))
        XCTAssertFalse(text.contains("/Users/jane"))
        XCTAssertFalse(text.contains("Jane Appleseed"), "the certificate holder's name is hidden")
        XCTAssertFalse(text.contains("BEGIN CERTIFICATE") || text.contains("PRIVATE KEY"))
        XCTAssertFalse(text.contains("001A2B3C4D5E6F70"), "the UDID shows its last four characters only")
    }
}

/// The Resigner's layers are kept apart by what each target imports (frontend/resigner/ARCHITECTURE.md, as LayerImportsTests does
/// for the launcher's).
final class ResignerLayerImportsTests: XCTestCase {
    private func imports(of target: String) throws -> [(String, String)] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let root = url.appendingPathComponent("Sources").appendingPathComponent(target)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [(String, String)] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            for (i, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if words.first == "import" { found.append(("\(file.lastPathComponent):\(i + 1)", String(words.last ?? ""))) }
            }
        }
        XCTAssertFalse(found.isEmpty)
        return found
    }

    func testResignerCoreImportsFoundationAndNXCoreOnly() throws {
        for (place, module) in try imports(of: "ResignerCore") where !["Foundation", "NXCore"].contains(module) {
            XCTFail("\(place): ResignerCore imports \(module)")
        }
    }

    func testResignerModelImportsNoUI() throws {
        for (place, module) in try imports(of: "ResignerModel") where !["Foundation", "Combine", "NXCore", "NXModel", "ResignerCore"].contains(module) {
            XCTFail("\(place): ResignerModel imports \(module)")
        }
    }
}

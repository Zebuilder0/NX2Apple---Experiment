import Foundation
import Combine
import NXCore
import ResignerCore

/// The dependency check (`EnvironmentProbe` and `DependencyEvaluator`): its rows, when it ran, the trial signature, and the fixes
/// that run a tool. It runs when the app opens, when asked, and after a failure that names a dependency. The run reads its own
/// fresh facts and never these, so a re-sign never starts from a stale check.
@MainActor package final class EnvironmentStore: ObservableObject {
    @Published package private(set) var facts: EnvironmentFacts?
    @Published package private(set) var items: [DependencyItem] = []
    @Published package private(set) var checking = false
    @Published package private(set) var lastChecked: Date?
    @Published package private(set) var testing = false
    /// The row whose fix is running.
    @Published package private(set) var fixing: String?
    /// What the last fix said, when it failed.
    @Published package private(set) var fixNote: LocalText?

    private let settings: ResignerSettings
    private let runner: ProcessRunner
    private let read: (ProbeRequest) -> EnvironmentFacts
    private let trialSign: (String, String?) -> TestSignResult
    private var trial: (sha: String, result: TestSignResult)?
    private var again = false
    /// The team the device's copy was signed with, when the last re-sign knows it (`ResignStore`).
    package var deviceCopyTeam: () -> String = { "" }
    package var log: (String) -> Void = { _ in }
    /// Names the log hides once the check found them (team and certificate holders).
    package var learnedNames: ([String]) -> Void = { _ in }

    /// `read` and `trialSign` are the real probe and trial signature by default. A test passes made-up facts.
    package init(settings: ResignerSettings, runner: ProcessRunner = SystemProcessRunner(),
                 read: ((ProbeRequest) -> EnvironmentFacts)? = nil, trialSign: ((String, String?) -> TestSignResult)? = nil) {
        self.settings = settings
        self.runner = runner
        self.read = read ?? { request in EnvironmentProbe(runner: runner).read(request) }
        self.trialSign = trialSign ?? { sha, developerDir in
            IdentityInspector(runner: runner, tools: ToolPaths(developerDir: developerDir)).testSign(sha1: sha)
        }
    }

    package var blockers: [DependencyItem] { DependencyEvaluator.blockers(items) }
    package var problems: [DependencyItem] { items.filter { $0.status.isProblem } }
    package var okCount: Int { items.filter { $0.status == .ok }.count }

    /// A check asked for while one runs runs once more when that one ends, so the rows end up current.
    @discardableResult
    package func check() -> Task<Void, Never> {
        if checking { again = true; return Task {} }
        checking = true
        let request = settings.probeRequest()
        let read = read
        return Task { @MainActor in
            let facts = await Task.detached(priority: .userInitiated) { read(request) }.value
            self.apply(facts)
            self.lastChecked = Date()
            self.checking = false
            self.log("check: \(self.items.filter { $0.status == .ok }.count) of \(self.items.count) rows ready, \(self.blockers.count) blocking\n")
            if self.again { self.again = false; await self.check().value }
        }
    }

    /// The facts as the rows show them: with the trial signature's result for this identity and the team the device's copy has.
    private func apply(_ read: EnvironmentFacts) {
        var facts = read
        if let trial, trial.sha == facts.signingCertificate?.sha1 { facts.testSign = trial.result; facts.testSignedIdentity = trial.sha }
        let known = deviceCopyTeam()
        if facts.deviceCopyTeam.isEmpty, !known.isEmpty { facts.deviceCopyTeam = known }
        self.facts = facts
        items = DependencyEvaluator.evaluate(facts)
        learnedNames(Self.names(in: facts))
        // The device and the team the probe settled on become the choice when none was made
        if settings.device.isEmpty, !facts.selectedDevice.isEmpty { settings.device = facts.selectedDevice }
        if settings.team.isEmpty, !facts.selectedTeam.isEmpty { settings.team = facts.selectedTeam }
    }

    /// The personal names in the facts: the teams' names and the certificate holders'.
    package static func names(in facts: EnvironmentFacts) -> [String] {
        (facts.teams.map(\.name) + facts.certificates.map { holder($0.commonName) } + facts.profiles.map(\.teamName)).filter { !$0.isEmpty }
    }

    /// "Apple Development: Jane Appleseed (ABCDE12345)" -> "Jane Appleseed".
    static func holder(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return "" }
        var rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let paren = rest.range(of: " (", options: .backwards) { rest = String(rest[..<paren.lowerBound]) }
        return rest
    }

    /// The trial signature with the identity the profile route would use.
    @discardableResult
    package func testSign() -> Task<Void, Never>? {
        guard !testing, let sha = facts?.signingCertificate?.sha1 else { return nil }
        testing = true
        let trialSign = trialSign, developerDir = settings.developerDir.isEmpty ? nil : settings.developerDir
        return Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { trialSign(sha, developerDir) }.value
            self.trial = (sha, result)
            self.log("signing check with …\(sha.suffix(4)): \(result)\n")
            self.testing = false
            if let facts = self.facts { self.apply(facts) }
        }
    }

    /// The fixes that run a tool: an Apple installer or download (`runTool`) or a change that macOS confirms with an administrator's
    /// password (`runAdmin`). The user pressed the button, and nothing else runs one. The check runs again afterwards.
    @discardableResult
    package func fix(_ action: RemediationAction, row: String) -> Task<Void, Never>? {
        let command: [String]
        switch action {
        case .runTool(let c), .runAdmin(let c): command = c
        default: return nil
        }
        guard fixing == nil, let tool = command.first else { return nil }
        fixing = row
        fixNote = nil
        let runner = runner, env = ToolPaths(developerDir: settings.developerDir.isEmpty ? nil : settings.developerDir).environment()
        log("fix \(row): \(command.joined(separator: " "))\n")
        return Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                runner.capture(ProcessLaunch(executable: tool, arguments: Array(command.dropFirst()), environment: env, mergesErrors: true))
            }.value
            self.log(result.out.isEmpty ? "" : result.out + "\n")
            if !result.ok { self.fixNote = LocalText("resigner.fix.failed", FailureClassifier.lastError(result.out)) }
            self.fixing = nil
            await self.check().value
        }
    }
}

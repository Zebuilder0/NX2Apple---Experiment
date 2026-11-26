import Foundation
import Combine
import NXCore
import ResignerCore

/// One step of the run as the dashboard shows it.
package struct StepRow: Identifiable, Equatable {
    package var step: ResignStep
    package var state: StepState
    package var detail: LocalText?

    package init(step: ResignStep, state: StepState = .pending, detail: LocalText? = nil) { self.step = step; self.state = state; self.detail = detail }
    package var id: Int { step.rawValue }
}

/// The re-sign: Re-sign & Install, its steps, Stop, the two questions it may ask (sign without the Increased Memory Limit, a first
/// install) and the last re-sign that went through. The work is `ResignPipeline` (`perform`), off the main thread.
@MainActor package final class ResignStore: ObservableObject {
    @Published package private(set) var running = false
    @Published package private(set) var stopping = false
    @Published package private(set) var steps: [StepRow] = ResignStore.freshSteps
    @Published package private(set) var current: ResignStep?
    @Published package private(set) var outcome: ResignOutcome?
    @Published package private(set) var lastRecord: ResignRecord?

    static var freshSteps: [StepRow] { ResignStep.allCases.map { StepRow(step: $0) } }
    static let recordKey = "lastResign"

    package let log: ResignLog
    private let settings: ResignerSettings
    private let environment: EnvironmentStore
    private let perform: (ResignRequest, PipelineHooks) -> ResignOutcome
    private let defaults: UserDefaults
    private let now: () -> Date
    private let cancelFlag = LockedFlag()
    private var process: RunningProcess?
    /// Stops a running tool (the real one sends SIGTERM). A test passes a stand-in.
    private let terminate: (RunningProcess) -> Void

    package init(settings: ResignerSettings, environment: EnvironmentStore, log: ResignLog, defaults: UserDefaults = .standard,
                 now: @escaping () -> Date = Date.init,
                 perform: @escaping (ResignRequest, PipelineHooks) -> ResignOutcome = { ResignPipeline().run($0, hooks: $1) },
                 terminate: @escaping (RunningProcess) -> Void = { ($0 as? Process)?.terminate() }) {
        self.settings = settings; self.environment = environment; self.log = log; self.defaults = defaults; self.now = now
        self.perform = perform; self.terminate = terminate
        if let data = defaults.data(forKey: Self.recordKey) { lastRecord = try? JSONDecoder().decode(ResignRecord.self, from: data) }
        environment.deviceCopyTeam = { [weak self] in self?.knownDeviceTeam ?? "" }
        // The names the check finds (a team's, a certificate holder's) are hidden in the log and the export from then on
        environment.learnedNames = { [weak log] names in log?.hide(names) }
    }

    /// The team the last re-sign used for this device and bundle ID: iOS takes an update only from that team.
    package var knownDeviceTeam: String {
        guard let record = lastRecord, record.deviceUDID == settings.device || settings.device.isEmpty else { return "" }
        let bundle = settings.bundleID.isEmpty ? (environment.facts?.targetBundleID ?? record.bundleID) : settings.bundleID
        return record.bundleID == bundle ? record.team : ""
    }

    /// The share of the steps that are done, for the progress bar.
    package var progress: Double {
        Double(steps.filter { $0.state == .done && $0.step != .completed }.count) / Double(ResignStep.allCases.count - 1)
    }

    package var canStart: Bool { !running }
    /// Stop is offered until the install starts: the device is then left to finish what it began.
    package var canStop: Bool { running && !stopping && (current?.cancellable ?? true) }

    /// Re-sign & Install. Each run reads the environment afresh (the pipeline's first step), whatever the dashboard shows.
    /// `allowWithoutMemoryLimit` and `allowFirstInstall` are this run's answers to the two questions, never remembered.
    @discardableResult
    package func start(allowWithoutMemoryLimit: Bool = false, allowFirstInstall: Bool = false) -> Task<Void, Never>? {
        guard canStart else { return nil }
        running = true
        stopping = false
        outcome = nil
        steps = Self.freshSteps
        current = nil
        cancelFlag.set(false)
        log.clear()
        let request = ResignRequest(probe: settings.probeRequest(), allowWithoutMemoryLimit: allowWithoutMemoryLimit,
                                    allowFirstInstall: allowFirstInstall, knownDeviceTeam: knownDeviceTeam, verbose: settings.verboseLog)
        let flag = cancelFlag
        let hooks = PipelineHooks(log: { [weak self] line in onMain { self?.log.append(line) } },
                                  step: { [weak self] step, state, detail in onMain { self?.mark(step, state, detail) } },
                                  cancelled: { flag.value },
                                  processStarted: { [weak self] p in onMain { self?.process = p } })
        let perform = perform
        let started = now()
        return Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { perform(request, hooks) }.value
            // The pipeline's last callbacks are queued on the main queue before this: let them land first
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            self.finish(outcome, started: started)
        }
    }

    private func mark(_ step: ResignStep, _ state: StepState, _ detail: LocalText?) {
        guard let i = steps.firstIndex(where: { $0.step == step }) else { return }
        steps[i].state = state
        steps[i].detail = detail
        if state == .running { current = step }
    }

    private func finish(_ outcome: ResignOutcome, started: Date) {
        process = nil
        running = false
        stopping = false
        current = nil
        self.outcome = outcome
        if outcome.ok {
            let record = ResignRecord(date: now(), outcome: outcome)
            lastRecord = record
            if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.recordKey) }
            environment.check()
        } else if outcome.failure?.recheckDependencies == true {
            environment.check()
        }
        let seconds = Int(now().timeIntervalSince(started).rounded())
        log.append("resigner: \(outcome.ok ? "finished" : "stopped") after \(seconds) s\n")
    }

    /// Stop: the pipeline stops before its next step and the running tool is ended. Refused once the install has started.
    package func stop() {
        guard canStop else { return }
        stopping = true
        cancelFlag.set(true)
        if let process, process.isRunning { terminate(process) }
    }

    /// The answer to the Increased Memory Limit question: the same run again, without it, this time only.
    @discardableResult
    package func retryWithoutMemoryLimit() -> Task<Void, Never>? {
        guard outcome?.failure?.kind == .memoryCapability else { return nil }
        return start(allowWithoutMemoryLimit: true)
    }

    /// The answer to the first-install question: install although no NX2Apple is on the device.
    @discardableResult
    package func confirmFirstInstall() -> Task<Void, Never>? {
        guard outcome?.failure?.kind == .firstInstall else { return nil }
        return start(allowFirstInstall: true)
    }

    /// The diagnostics export: the dependency rows and the log, redacted (`DiagnosticReport`).
    package func diagnosticsText(appVersion: String, t: (String) -> String) -> String {
        let facts = environment.facts
        if let facts { log.hide(EnvironmentStore.names(in: facts)) }
        let xcode = facts?.activeXcode.map { $0.label } ?? facts?.xcodebuildVersion ?? ""
        return DiagnosticReport.text(appVersion: appVersion, macOS: facts?.macOSVersion ?? "", xcode: xcode,
                                     route: facts?.resolvedRoute ?? settings.route, items: environment.items, log: log.text, now: now(),
                                     t: t, redactor: log.redactor)
    }

    package func exportDiagnostics(to url: URL, appVersion: String, t: (String) -> String) throws {
        try diagnosticsText(appVersion: appVersion, t: t).write(to: url, atomically: true, encoding: .utf8)
    }
}

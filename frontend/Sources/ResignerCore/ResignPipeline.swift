import Foundation
import NXCore

/// What one run is asked to do.
package struct ResignRequest: Equatable, Sendable {
    package var probe: ProbeRequest
    /// The user said yes to signing without the Increased Memory Limit (after a failure that named it).
    package var allowWithoutMemoryLimit = false
    /// The user said yes to installing on a device that has no NX2Apple (nothing to keep).
    package var allowFirstInstall = false
    /// The team the device's copy was signed with, from the last re-sign, when shell.json does not say.
    package var knownDeviceTeam = ""
    /// Every line of the tools' output goes to the log, not only the errors and the summary lines.
    package var verbose = false

    package init(probe: ProbeRequest, allowWithoutMemoryLimit: Bool = false, allowFirstInstall: Bool = false, knownDeviceTeam: String = "",
                 verbose: Bool = false) {
        self.probe = probe; self.allowWithoutMemoryLimit = allowWithoutMemoryLimit; self.allowFirstInstall = allowFirstInstall
        self.knownDeviceTeam = knownDeviceTeam; self.verbose = verbose
    }
}

/// How a run ended.
package struct ResignOutcome: Equatable, Sendable {
    package var ok = false
    package var failure: ResignFailure?
    package var route: SigningRoute = .automatic
    package var bundleID = ""
    package var team = ""
    package var deviceName = ""
    package var deviceUDID = ""
    package var profileName = ""
    package var profileExpiry: Date?
    package var droppedEntitlements: [String] = []
    package var firstInstall = false
    package var games = 0
    package var notes: [LocalText] = []

    package init() {}
}

/// A record of the last re-sign that went through, kept by the store.
package struct ResignRecord: Codable, Equatable, Sendable {
    package var date: Date
    package var route: SigningRoute
    package var deviceName: String
    package var deviceUDID: String
    package var bundleID: String
    package var team: String
    package var profileExpiry: Date?
    package var droppedEntitlements: [String]

    package init(date: Date, outcome: ResignOutcome) {
        self.date = date; route = outcome.route; deviceName = outcome.deviceName; deviceUDID = outcome.deviceUDID
        bundleID = outcome.bundleID; team = outcome.team; profileExpiry = outcome.profileExpiry; droppedEntitlements = outcome.droppedEntitlements
    }
}

/// What a run reports while it works, and how it is asked to stop. The store hands these to the pipeline.
package struct PipelineHooks {
    package var log: (String) -> Void
    package var step: (ResignStep, StepState, LocalText?) -> Void
    package var cancelled: () -> Bool
    package var processStarted: (RunningProcess) -> Void

    package init(log: @escaping (String) -> Void = { _ in }, step: @escaping (ResignStep, StepState, LocalText?) -> Void = { _, _, _ in },
                 cancelled: @escaping () -> Bool = { false }, processStarted: @escaping (RunningProcess) -> Void = { _ in }) {
        self.log = log; self.step = step; self.cancelled = cancelled; self.processStarted = processStarted
    }
}

/// The re-sign, start to end, blocking (the store runs it off the main thread). Each step reports itself, a tool's output goes to
/// `log`, and a failing step ends the run with a `ResignFailure` that says why in the user's terms. The pipeline never uninstalls
/// and never changes the bundle ID: see frontend/resigner/ARCHITECTURE.md, "Data on the device".
package struct ResignPipeline {
    package var runner: ProcessRunner
    package var home: String
    package var fm: FileManager
    package var log: (String) -> Void = { _ in }
    package var step: (ResignStep, StepState, LocalText?) -> Void = { _, _, _ in }
    package var cancelled: () -> Bool = { false }
    package var processStarted: (RunningProcess) -> Void = { _ in }
    /// Where the profile route copies the app. A folder of its own is made inside and removed at the end.
    package var temporaryFolder: String = NSTemporaryDirectory()
    package var applicationFolders: [String]? = nil
    /// The tools' paths. The chosen Xcode's `DEVELOPER_DIR` goes on top.
    package var baseTools = ToolPaths()

    package init(runner: ProcessRunner = SystemProcessRunner(), home: String = NSHomeDirectory(), fm: FileManager = .default) {
        self.runner = runner; self.home = home; self.fm = fm
    }

    /// The run with the store's hooks.
    package func run(_ request: ResignRequest, hooks: PipelineHooks) -> ResignOutcome {
        var p = self
        p.log = hooks.log; p.step = hooks.step; p.cancelled = hooks.cancelled; p.processStarted = hooks.processStarted
        return p.run(request)
    }

    var probe: EnvironmentProbe {
        var p = EnvironmentProbe(runner: runner, home: home, fm: fm, applicationFolders: applicationFolders)
        p.baseTools = baseTools
        return p
    }

    /// The state the steps share.
    struct Run {
        var request: ResignRequest
        var tools: ToolPaths
        var facts: EnvironmentFacts
        var route: SigningRoute
        var outcome = ResignOutcome()
        var appToSign = ""
        var workFolder: String?
        var plan: EntitlementPlanner.Plan?
        var profile: ProvisioningProfile?
        var certificate: CertificateRecord?
        var device: DeviceStatus?
        var gamesBefore: [String] = []
    }

    package func run(_ request: ResignRequest) -> ResignOutcome {
        var tools = baseTools
        tools.developerDir = request.probe.developerDir
        begin(.checkingEnvironment)
        var facts = probe.read(request.probe)
        facts.allowWithoutMemoryLimit = request.allowWithoutMemoryLimit
        facts.allowFirstInstall = request.allowFirstInstall
        if facts.deviceCopyTeam.isEmpty { facts.deviceCopyTeam = request.knownDeviceTeam }
        var r = Run(request: request, tools: tools, facts: facts, route: facts.resolvedRoute)
        r.outcome.route = r.route
        r.outcome.bundleID = facts.targetBundleID
        r.outcome.team = facts.selectedTeam
        defer { if let work = r.workFolder { try? fm.removeItem(atPath: work) } }
        log("resigner: route \(r.route.rawValue), bundle ID \(r.outcome.bundleID), team \(r.outcome.team)\n")

        let steps: [(ResignStep, (inout Run) -> ResignFailure?)] = [
            (.checkingEnvironment, checkEnvironment), (.detectingDevice, detectDevice), (.validatingCredentials, validateCredentials),
            (.preparingProject, prepareProject), (.signing, sign), (.verifyingSignature, verifySignature), (.installing, install),
            (.verifyingInstallation, verifyInstallation),
        ]
        for (index, (current, body)) in steps.enumerated() {
            if index > 0 { begin(current) }
            if current.cancellable, cancelled() { return finish(&r, ResignFailure(step: current, kind: .cancelled, message: LocalText("resigner.fail.cancelled"))) }
            if let failure = body(&r) {
                if current.cancellable, cancelled() { return finish(&r, ResignFailure(step: current, kind: .cancelled, message: LocalText("resigner.fail.cancelled"))) }
                return finish(&r, failure)
            }
            step(current, .done, nil)
        }
        step(.completed, .done, nil)
        r.outcome.ok = true
        log("resigner: done, \(r.outcome.bundleID) on \(r.outcome.deviceName)\n")
        return r.outcome
    }

    private func begin(_ s: ResignStep) { step(s, .running, nil) }

    private func finish(_ r: inout Run, _ failure: ResignFailure) -> ResignOutcome {
        step(failure.step, .failed, failure.message)
        log("resigner: stopped at \(failure.step): \(failure.message)" + (failure.detail.isEmpty ? "" : " (\(failure.detail))") + "\n")
        r.outcome.ok = false
        r.outcome.failure = failure
        return r.outcome
    }

    // MARK: 1 to 4

    func checkEnvironment(_ r: inout Run) -> ResignFailure? {
        // Device, signing and provisioning rows are checked by their own steps below, which say more about them
        let items = DependencyEvaluator.evaluate(r.facts)
        for item in items where item.stops { log("dependency: \(item.id) \(item.status.rawValue): \(item.explanation)\n") }
        guard let blocker = DependencyEvaluator.blockers(items).first(where: { [.xcode, .tools, .project].contains($0.category) }) else { return nil }
        return ResignFailure(step: .checkingEnvironment, kind: .dependency, message: blocker.explanation, detail: blocker.version, remedy: blocker.remediation)
    }

    func detectDevice(_ r: inout Run) -> ResignFailure? {
        let f = r.facts
        guard let device = f.device else {
            return ResignFailure(step: .detectingDevice, kind: .device, message: LocalText(f.devices.isEmpty ? "resigner.dep.device.none" : "resigner.dep.device.notChosen"),
                                 remedy: LocalText("resigner.dep.device.noneFix"))
        }
        r.device = device
        r.outcome.deviceName = device.name
        r.outcome.deviceUDID = device.udid
        if let issue = DeviceReadiness.issues(device, minimumOS: f.shell.app?.minimumOS ?? "").first(where: \.blocking) {
            return ResignFailure(step: .detectingDevice, kind: .device, message: issue.text, remedy: LocalText("resigner.dep.device.fix"))
        }
        guard let apps = f.installedApps ?? probe.installedApps(device: device.udid, tools: r.tools) else {
            return ResignFailure(step: .detectingDevice, kind: .device, message: LocalText("resigner.fail.appList", device.name),
                                 remedy: LocalText("resigner.dep.device.fix"))
        }
        r.facts.installedApps = apps
        switch InstallTargetCheck.decide(bundleID: f.targetBundleID, apps: apps) {
        case .upgrade(let app):
            log("device: \(device.name) has \(app.bundle) (\(app.name)): the install is an update, its data stays\n")
        case .firstInstall:
            guard r.request.allowFirstInstall else {
                return ResignFailure(step: .detectingDevice, kind: .firstInstall, message: LocalText("resigner.dep.installed.none", device.name),
                                     remedy: LocalText("resigner.dep.installed.noneFix"))
            }
            r.outcome.firstInstall = true
            log("device: \(device.name) has no NX2Apple, this is a first install (confirmed)\n")
        case .otherBundleOnly(let others):
            let ids = others.map(\.bundle).joined(separator: ", ")
            return ResignFailure(step: .detectingDevice, kind: .otherBundle, message: LocalText("resigner.dep.installed.other", ids, f.targetBundleID),
                                 remedy: LocalText("resigner.dep.installed.otherFix"))
        }
        return nil
    }

    func validateCredentials(_ r: inout Run) -> ResignFailure? {
        let f = r.facts
        let team = f.selectedTeam
        guard !team.isEmpty else {
            return ResignFailure(step: .validatingCredentials, kind: .credentials, message: LocalText("resigner.dep.team.none"),
                                 remedy: LocalText("resigner.dep.team.noneFix"))
        }
        if !f.deviceCopyTeam.isEmpty, f.deviceCopyTeam != team {
            return ResignFailure(step: .validatingCredentials, kind: .teamMismatch,
                                 message: LocalText("resigner.dep.sameTeam.differs", f.deviceCopyTeam, team),
                                 remedy: LocalText("resigner.dep.sameTeam.fix", f.deviceCopyTeam))
        }
        if r.route == .xcode {
            guard f.xcodeAccountTeams.contains(where: { $0.id == team }) else {
                return ResignFailure(step: .validatingCredentials, kind: .credentials, message: LocalText("resigner.dep.team.noAccount", team),
                                     remedy: LocalText("resigner.dep.team.noAccountFix"))
            }
            return nil
        }
        // The profile route: an identity that signs, a profile that fits, the entitlements the profile grants
        let identityRow = DependencyEvaluator.identityRow(f, profileRoute: true)
        guard identityRow.status == .ok, let certificate = f.signingCertificate else {
            return ResignFailure(step: .validatingCredentials, kind: .credentials, message: identityRow.explanation, detail: identityRow.version,
                                 remedy: identityRow.remediation)
        }
        r.certificate = certificate
        let trial = IdentityInspector(runner: runner, tools: r.tools).testSign(sha1: certificate.sha1, temporaryFolder: temporaryFolder)
        log("signing: trial signature with \(certificate.commonName): \(trial)\n")
        if trial != .signed {
            var facts = f
            facts.testSign = trial
            facts.testSignedIdentity = certificate.sha1
            let row = DependencyEvaluator.signingRows(facts).first { $0.id == "signing.test" }!
            return ResignFailure(step: .validatingCredentials, kind: .credentials, message: row.explanation, detail: row.version, remedy: row.remediation)
        }
        let need = f.profileRequirement
        guard let profile = f.signingProfile ?? f.profileWithoutMemoryLimit else {
            let row = DependencyEvaluator.provisioningRows(f).first { $0.id == "provisioning.profile" }!
            return ResignFailure(step: .validatingCredentials, kind: .credentials, message: row.explanation, remedy: row.remediation)
        }
        let stops = ProfileMatcher.issues(profile, need).filter(\.blocking)
        if stops == [.entitlementMissing(EntitlementPlanner.memoryLimit)] {
            return ResignFailure(step: .validatingCredentials, kind: .memoryCapability,
                                 message: LocalText("resigner.dep.entitlements.memory", EntitlementPlanner.memoryLimit), detail: profile.name,
                                 remedy: LocalText("resigner.dep.entitlements.memoryFix"))
        }
        if let issue = stops.first {
            return ResignFailure(step: .validatingCredentials, kind: .credentials, message: issue.text, detail: profile.name,
                                 remedy: LocalText("resigner.dep.profile.fix"))
        }
        r.profile = profile
        let allowDrop: Set<String> = r.request.allowWithoutMemoryLimit ? [EntitlementPlanner.memoryLimit] : []
        switch EntitlementPlanner.plan(current: f.appEntitlements, profile: profile, bundleID: f.targetBundleID, allowDropping: allowDrop) {
        case .success(let plan):
            r.plan = plan
            r.outcome.droppedEntitlements = plan.dropped
            for key in plan.dropped { log("signing: \(key) left out, as chosen for this run\n") }
            return nil
        case .failure(.notGranted(let key)) where key == EntitlementPlanner.memoryLimit:
            return ResignFailure(step: .validatingCredentials, kind: .memoryCapability, message: LocalText("resigner.dep.entitlements.memory", key),
                                 detail: profile.name, remedy: LocalText("resigner.dep.entitlements.memoryFix"))
        case .failure(.notGranted(let key)):
            return ResignFailure(step: .validatingCredentials, kind: .credentials, message: LocalText("resigner.dep.entitlements.missing", key),
                                 detail: profile.name, remedy: LocalText("resigner.dep.profile.fix"))
        case .failure(.unsupported(let key)):
            return ResignFailure(step: .validatingCredentials, kind: .credentials, message: LocalText("resigner.dep.entitlements.unsupported", key))
        }
    }

    func prepareProject(_ r: inout Run) -> ResignFailure? {
        let f = r.facts
        guard let app = f.shell.app else {
            return ResignFailure(step: .preparingProject, kind: .project, message: LocalText("resigner.dep.app.missing"), detail: f.shell.appPath,
                                 remedy: LocalText("resigner.dep.root.missingFix"))
        }
        let row = DependencyEvaluator.appRow(f)
        if row.status != .ok { return ResignFailure(step: .preparingProject, kind: .project, message: row.explanation, remedy: row.remediation) }
        r.gamesBefore = app.games.map(\.framework).sorted()
        r.outcome.games = app.games.count
        if r.route == .xcode {
            let project = DependencyEvaluator.projectRow(f)
            guard f.shell.project.usable else {
                return ResignFailure(step: .preparingProject, kind: .project, message: project.explanation, detail: f.shell.project.path,
                                     remedy: LocalText("resigner.dep.project.fixAuto"))
            }
            r.appToSign = f.shell.appPath
            return nil
        }
        // The profile route signs a copy in a private folder: the launcher's own build stays as it is
        let work = (temporaryFolder as NSString).appendingPathComponent("nx2apple-resigner-" + UUID().uuidString)
        do {
            try fm.createDirectory(atPath: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            r.workFolder = work
            let copy = work + "/Payload/" + ShellInstall.appName
            try fm.createDirectory(atPath: work + "/Payload", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            log("prepare: copying \(app.path) to \(copy)\n")
            try fm.copyItem(atPath: app.path, toPath: copy)
            r.appToSign = copy
        } catch {
            return ResignFailure(step: .preparingProject, kind: .project, message: LocalText("resigner.fail.copy", error.localizedDescription))
        }
        return nil
    }

    // MARK: 5 to 8

    func sign(_ r: inout Run) -> ResignFailure? {
        r.route == .xcode ? signWithXcode(&r) : signWithProfile(&r)
    }

    /// `ShellInstall.buildCommand`, the launcher's own re-sign, with the configuration of Settings and, by the user's choice only, no
    /// entitlements file (the Increased Memory Limit left out).
    package static func xcodeCommand(xcrun: String, root: String, device: String, team: String, bundleID: String, configuration: String,
                                     withoutEntitlements: Bool) -> [String] {
        var command = ShellInstall.buildCommand(xcrun: xcrun, root: root, device: device, team: team, bundleID: bundleID)
        if let i = command.firstIndex(of: "-configuration"), i + 1 < command.count { command[i + 1] = configuration }
        if withoutEntitlements, let build = command.lastIndex(of: "build") { command.insert("CODE_SIGN_ENTITLEMENTS=", at: build) }
        return command
    }

    func signWithXcode(_ r: inout Run) -> ResignFailure? {
        let f = r.facts
        let command = Self.xcodeCommand(xcrun: r.tools.xcrun, root: f.shell.root, device: f.selectedDevice, team: f.selectedTeam,
                                        bundleID: f.targetBundleID, configuration: r.request.probe.configuration,
                                        withoutEntitlements: r.request.allowWithoutMemoryLimit)
        if r.request.allowWithoutMemoryLimit {
            r.outcome.droppedEntitlements = [EntitlementPlanner.memoryLimit]
            log("signing: \(EntitlementPlanner.memoryLimit) left out, as chosen for this run\n")
        }
        let result = runTool(command, r, label: "xcodebuild")
        guard result.status == 0 else { return FailureClassifier.xcodebuild(result.output, team: f.selectedTeam, bundleID: f.targetBundleID) }
        return nil
    }

    /// The order codesign needs: every embedded framework and library first, then the app that seals them.
    package static func signingOrder(app: String, fm: FileManager = .default) -> [String] {
        let folder = app + "/Frameworks"
        let nested = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".framework") || $0.hasSuffix(".dylib") }
            .sorted().map { folder + "/" + $0 }
        return nested + [app]
    }

    func signWithProfile(_ r: inout Run) -> ResignFailure? {
        guard let profile = r.profile, let certificate = r.certificate, let plan = r.plan else {
            return ResignFailure(step: .signing, kind: .credentials, message: LocalText("resigner.dep.profile.none", r.facts.targetBundleID))
        }
        let app = r.appToSign
        let tools = r.tools
        let entitlementsFile = (r.workFolder ?? temporaryFolder) + "/entitlements.plist"
        do {
            try EntitlementPlanner.plistData(plan.entitlements).write(to: URL(fileURLWithPath: entitlementsFile), options: .atomic)
            let embedded = app + "/" + AppSignature.profileName
            if fm.fileExists(atPath: embedded) { try fm.removeItem(atPath: embedded) }
            try fm.copyItem(atPath: profile.path, toPath: embedded)
        } catch {
            return ResignFailure(step: .signing, kind: .project, message: LocalText("resigner.fail.copy", error.localizedDescription))
        }
        // Extended attributes on the copy (a download's quarantine, Finder info) make codesign refuse the bundle
        _ = runTool(["/usr/bin/xattr", "-cr", app], r, label: "xattr")
        for item in Self.signingOrder(app: app, fm: fm) {
            if cancelled() { return ResignFailure(step: .signing, kind: .cancelled, message: LocalText("resigner.fail.cancelled")) }
            var args = ["--force", "--sign", certificate.sha1, "--timestamp=none", "--generate-entitlement-der"]
            if item == app { args += ["--entitlements", entitlementsFile] } else { args += ["--preserve-metadata=identifier,flags"] }
            let result = runTool([tools.codesign] + args + [item], r, label: "codesign")
            if result.status != 0 { return FailureClassifier.codesign(result.output, item: (item as NSString).lastPathComponent) }
        }
        r.outcome.profileName = profile.name
        return nil
    }

    func verifySignature(_ r: inout Run) -> ResignFailure? {
        let f = r.facts, app = r.appToSign, tools = r.tools
        func fail(_ key: String, _ detail: String = "", _ args: String...) -> ResignFailure {
            ResignFailure(step: .verifyingSignature, kind: .verification, message: LocalText(key, args: args), detail: detail)
        }
        let strict = runTool([tools.codesign, "--verify", "--deep", "--strict", "--verbose=2", app], r, label: "codesign verify")
        if strict.status != 0 {
            // installd checks the signature itself: a strict-only complaint is noted, a basic failure stops
            let basic = runTool([tools.codesign, "--verify", "--verbose=2", app], r, label: "codesign verify")
            if basic.status != 0 { return fail("resigner.fail.verify", FailureClassifier.lastError(basic.output)) }
            r.outcome.notes.append(LocalText("resigner.note.strict", FailureClassifier.lastError(strict.output)))
        }
        guard let built = ShellInspector.readApp(app, fm: fm) else { return fail("resigner.dep.app.missing", app) }
        if built.bundleID != f.targetBundleID { return fail("resigner.dep.app.bundle", "", built.bundleID, f.targetBundleID) }
        // A game the app had and lost would be gone from the device. One the launcher's project adds (a game added since the last
        // install) is what the project holds now, and is kept.
        let after = Set(built.games.map(\.framework))
        let lost = Set(r.gamesBefore).subtracting(after)
        if !lost.isEmpty {
            return fail("resigner.fail.gamesChanged", lost.sorted().joined(separator: ", "), String(r.gamesBefore.count), String(after.count))
        }
        for added in after.subtracting(r.gamesBefore).sorted() { log("verify: \(added) is new in the signed app (the launcher's project has it)\n") }
        r.outcome.games = after.count
        let signed = probe.entitlements(ofApp: app, tools: tools)
        let expectedID = f.selectedTeam + "." + f.targetBundleID
        guard case .string(let appID)? = signed["application-identifier"], appID == expectedID else {
            return fail("resigner.fail.appIdentifier", "", expectedID)
        }
        for key in f.requiredEntitlements where key != EntitlementPlanner.memoryLimit || !r.outcome.droppedEntitlements.contains(key) {
            if signed[key] == nil { return fail("resigner.fail.entitlementLost", "", key) }
        }
        guard let embedded = ProvisioningProfiles.read(app + "/" + AppSignature.profileName, runner: runner, tools: tools) else {
            return fail("resigner.fail.noEmbeddedProfile")
        }
        var need = ProfileRequirement(bundleID: f.targetBundleID, teamID: f.selectedTeam, deviceUDID: f.selectedDevice,
                                      deviceName: r.outcome.deviceName, now: Date())
        if r.route == .profile { need.certificateSHA1 = r.certificate?.sha1 }
        if let issue = ProfileMatcher.issues(embedded, need).first(where: \.blocking) {
            return ResignFailure(step: .verifyingSignature, kind: .verification, message: issue.text, detail: embedded.name)
        }
        r.outcome.profileName = embedded.name
        r.outcome.profileExpiry = embedded.expires
        log("verify: signed as \(appID), profile \(embedded.name), expires \(embedded.expires.map(ResignFormat.moment) ?? "-")\n")
        return nil
    }

    func install(_ r: inout Run) -> ResignFailure? {
        // Over the existing app, same bundle ID: an update, which keeps the app's data. Never an uninstall.
        let command = ShellInstall.installCommand(xcrun: r.tools.xcrun, device: r.facts.selectedDevice, app: r.appToSign)
        let result = runTool(command, r, label: "devicectl install")
        guard result.status == 0 else { return FailureClassifier.install(result.output, deviceName: r.outcome.deviceName, team: r.facts.selectedTeam) }
        return nil
    }

    func verifyInstallation(_ r: inout Run) -> ResignFailure? {
        guard let apps = probe.installedApps(device: r.facts.selectedDevice, tools: r.tools) else {
            return ResignFailure(step: .verifyingInstallation, kind: .verification, message: LocalText("resigner.fail.appList", r.outcome.deviceName))
        }
        guard let app = apps.first(where: { $0.bundle == r.facts.targetBundleID }) else {
            return ResignFailure(step: .verifyingInstallation, kind: .verification,
                                 message: LocalText("resigner.fail.notListed", r.facts.targetBundleID, r.outcome.deviceName))
        }
        log("verify: \(r.outcome.deviceName) lists \(app.bundle) (\(app.name))\n")
        return nil
    }

    // MARK: Tools

    struct ToolOutput { var status: Int32; var output: String }

    /// One tool, blocking, through the runner with the Resigner's environment. Its output is kept (the last 256 KB) for the
    /// classifier, and goes to the log line by line when the run is verbose, else only the lines that matter.
    func runTool(_ command: [String], _ r: Run, label: String) -> ToolOutput {
        log("[\(label)] " + command.joined(separator: " ") + "\n")
        var output = ""
        let verbose = r.request.verbose
        let launch = ProcessLaunch(executable: command[0], arguments: Array(command.dropFirst()), environment: r.tools.environment(home: home))
        let result = runner.streamLines(launch, started: processStarted) { line in
            output += line + "\n"
            if output.utf8.count > 512_000 { output = String(output.suffix(256_000)) }
            if verbose || Self.matters(line) { log(line + "\n") }
        }
        guard result.started else { log(result.out + "\n"); return ToolOutput(status: 127, output: result.out) }
        log("[\(label)] exit \(result.status)\n")
        return ToolOutput(status: result.status, output: output)
    }

    /// The lines kept in a short log: errors and warnings, the signing identity and profile, and the result lines.
    package static func matters(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("error") || l.contains("warning:") || l.contains("signing identity") || l.contains("provisioning profile")
            || l.contains("** build") || l.contains("app installed") || l.contains("bundleid") || l.contains("valid on disk")
            || l.contains("satisfies its designated requirement") || l.contains("signed ")
    }
}

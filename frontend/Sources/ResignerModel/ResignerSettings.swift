import Foundation
import Combine
import NXCore
import ResignerCore

/// Runs `body` on the main actor from a background queue (the pipeline's callbacks), in the order they were sent.
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// The Resigner's choices, kept in its own defaults. The first time, the shell folder, the device and the team come from the
/// launcher's settings (`org.nxnative.NSPortBuilder`), which are only read, never written.
@MainActor package final class ResignerSettings: ObservableObject {
    package static let launcherDomain = "org.nxnative.NSPortBuilder"
    package static let configurations = ["Release", "Debug"]

    enum Key {
        static let route = "route", shellRoot = "shellRoot", developerDir = "developerDir", configuration = "configuration"
        static let device = "device", team = "team", identity = "identity", profile = "profile", bundleID = "bundleID", verbose = "verboseLog"
    }

    @Published package var route: SigningRoute { didSet { defaults.set(route.rawValue, forKey: Key.route) } }
    /// The launcher's shell folder.
    @Published package var shellRoot: String { didSet { defaults.set(shellRoot, forKey: Key.shellRoot) } }
    /// `<Xcode>.app/Contents/Developer` for the Resigner only, "" for the one `xcode-select` names.
    @Published package var developerDir: String { didSet { defaults.set(developerDir, forKey: Key.developerDir) } }
    @Published package var configuration: String { didSet { defaults.set(configuration, forKey: Key.configuration) } }
    /// The device's UDID.
    @Published package var device: String { didSet { defaults.set(device, forKey: Key.device) } }
    @Published package var team: String { didSet { defaults.set(team, forKey: Key.team) } }
    /// The SHA-1 of the identity, "" for the newest valid one of the team.
    @Published package var identity: String { didSet { defaults.set(identity, forKey: Key.identity) } }
    /// The profile's UUID, "" for the best match.
    @Published package var profile: String { didSet { defaults.set(profile, forKey: Key.profile) } }
    /// "" for shell.json's bundle ID, else one the device has.
    @Published package var bundleID: String { didSet { defaults.set(bundleID, forKey: Key.bundleID) } }
    /// Every line of the tools' output goes to the log.
    @Published package var verboseLog: Bool { didSet { defaults.set(verboseLog, forKey: Key.verbose) } }

    private let defaults: UserDefaults
    package let launcherShellRoot: String

    /// `launcher` is the launcher's defaults (nil when they cannot be read). Tests pass suites of their own for both.
    package init(defaults: UserDefaults = .standard, launcher: UserDefaults? = UserDefaults(suiteName: ResignerSettings.launcherDomain),
                 home: String = NSHomeDirectory()) {
        self.defaults = defaults
        let launcherRoot = launcher.map { ShellLibrary.previewRoot(defaults: $0, parent: "", home: home) } ?? ShellRootMigration.defaultRoot(home: home)
        launcherShellRoot = launcherRoot
        route = defaults.string(forKey: Key.route).flatMap(SigningRoute.init(rawValue:)) ?? .automatic
        shellRoot = defaults.string(forKey: Key.shellRoot).flatMap { $0.isEmpty ? nil : $0 } ?? launcherRoot
        developerDir = defaults.string(forKey: Key.developerDir) ?? ""
        configuration = defaults.string(forKey: Key.configuration).flatMap { Self.configurations.contains($0) ? $0 : nil } ?? "Release"
        device = defaults.string(forKey: Key.device) ?? launcher?.string(forKey: "installDevice") ?? ""
        team = defaults.string(forKey: Key.team) ?? launcher?.string(forKey: "signingTeam") ?? ""
        identity = defaults.string(forKey: Key.identity) ?? ""
        profile = defaults.string(forKey: Key.profile) ?? ""
        bundleID = defaults.string(forKey: Key.bundleID) ?? ""
        verboseLog = defaults.bool(forKey: Key.verbose)
    }

    /// What the probe and the pipeline are asked for.
    package func probeRequest(readInstalledApps: Bool = true) -> ProbeRequest {
        ProbeRequest(shellRoot: shellRoot, configuration: configuration, developerDir: developerDir.isEmpty ? nil : developerDir, route: route,
                     device: device, team: team, identity: identity, profile: profile, bundleID: bundleID, readInstalledApps: readInstalledApps)
    }

    /// Back to the launcher's shell folder.
    package func useLauncherShellRoot() { shellRoot = launcherShellRoot }
}

/// The run's log, redacted line by line as it is written (`LogRedactor`). Only the log view observes it, so a line redraws the
/// log and nothing else, as the launcher's `BuildLog` does.
@MainActor package final class ResignLog: ObservableObject {
    package static let limit = 400_000
    package static let keep = 300_000

    @Published package private(set) var text = ""
    package var redactor: LogRedactor

    nonisolated package init(redactor: LogRedactor = LogRedactor()) { self.redactor = redactor }

    package func append(_ s: String) {
        text += redactor.redact(s)
        if text.count > Self.limit { text = String(text.suffix(Self.keep)) }
    }

    package func clear() { text = "" }

    /// Names that the redaction hides from now on (a team's name, a certificate holder's name).
    package func hide(_ names: [String]) {
        let new = names.filter { !$0.isEmpty && !redactor.names.contains($0) }
        if !new.isEmpty { redactor.names += new }
    }
}

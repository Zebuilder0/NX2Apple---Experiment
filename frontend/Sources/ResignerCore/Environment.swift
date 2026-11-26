import Foundation
import NXCore

/// One Xcode on this Mac.
package struct XcodeInstall: Equatable, Sendable, Identifiable {
    package var path: String
    package var version: String
    package var build: String

    package init(path: String, version: String, build: String = "") { self.path = path; self.version = version; self.build = build }

    package var id: String { path }
    package var developerDir: String { path + "/Contents/Developer" }
    package var label: String { build.isEmpty ? version : version + " (" + build + ")" }
}

package enum XcodeLocator {
    package static let bundleID = "com.apple.dt.Xcode"
    /// The shell's deployment target is iOS 26.0, so its SDK and the devices that run it need Xcode 26 or later.
    package static let minimumVersion = "26.0"
    /// The App Store page of Xcode and Apple's page of every Xcode release (README.md names 27.2 for NVN games).
    package static let appStoreURL = "macappstore://apps.apple.com/app/id497799835"
    package static let downloadsURL = "https://developer.apple.com/download/all/?q=Xcode"

    /// An Xcode.app's version, from its Info.plist and version.plist. nil for another app.
    package static func read(app: String, fm: FileManager = .default) -> XcodeInstall? {
        guard let data = fm.contents(atPath: app + "/Contents/Info.plist"),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID else { return nil }
        var build = ""
        if let v = fm.contents(atPath: app + "/Contents/version.plist"),
           let version = (try? PropertyListSerialization.propertyList(from: v, options: [], format: nil)) as? [String: Any] {
            build = version["ProductBuildVersion"] as? String ?? ""
        }
        return XcodeInstall(path: app, version: info["CFBundleShortVersionString"] as? String ?? "", build: build)
    }

    /// Every Xcode in the folders (`/Applications`, `~/Applications`) and at the extra paths (the selected one, wherever it is),
    /// newest first, each once.
    package static func find(roots: [String], extra: [String] = [], fm: FileManager = .default) -> [XcodeInstall] {
        var apps: [String] = extra
        for root in roots {
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where name.hasSuffix(".app") && name.lowercased().contains("xcode") {
                apps.append(root + "/" + name)
            }
        }
        var seen = Set<String>(), out: [XcodeInstall] = []
        for app in apps {
            let path = (app as NSString).standardizingPath
            guard seen.insert(path).inserted, let xcode = read(app: path, fm: fm) else { continue }
            out.append(xcode)
        }
        return out.sorted { (VersionNumber($0.version) ?? VersionNumber("0")!) > (VersionNumber($1.version) ?? VersionNumber("0")!) }
    }
}

/// What the probe found on this Mac, the device and in the shell root. Only facts: what they mean is `DependencyEvaluator`'s job,
/// so every situation is a test with facts made by hand.
package struct EnvironmentFacts: Equatable {
    package var now = Date()
    package var macOSVersion = ""
    /// `xcode-select -p` when that folder exists, nil otherwise.
    package var selectedDeveloperDir: String?
    /// The Xcode chosen in Settings for the Resigner (`DEVELOPER_DIR`), nil to use the selected one.
    package var chosenDeveloperDir: String?
    package var xcodes: [XcodeInstall] = []
    /// xcodebuild's first line ("Xcode 27.2"), nil when it did not run. `xcodebuildError` then holds its last line.
    package var xcodebuildVersion: String?
    package var xcodebuildError = ""
    package var licenseAccepted: Bool?
    package var firstLaunchDone: Bool?
    package var iosSDKVersion: String?
    package var commandLineToolsInstalled = false
    package var xcrunWorks = false
    package var codesignPresent = false
    package var securityPresent = false
    package var devicectlPath: String?
    package var deviceListWorked = false
    package var devices: [DeviceStatus] = []
    package var selectedDevice = ""
    /// The device's apps, nil when they were not read (no device, not connected, or the listing failed).
    package var installedApps: [InstalledApp]?
    package var identities: [IdentityRecord] = []
    package var certificates: [CertificateRecord] = []
    package var teams: [SigningTeam] = []
    package var xcodeAccountTeams: [XcodeTeam] = []
    package var selectedTeam = ""
    /// The SHA-1 of the identity chosen in Settings, "" for the first valid one of the team.
    package var selectedIdentity = ""
    package var testSign: TestSignResult?
    package var testSignedIdentity = ""
    package var profiles: [ProvisioningProfile] = []
    /// The UUID of the profile chosen in Settings, "" for the best match.
    package var selectedProfile = ""
    package var route: SigningRoute = .automatic
    package var shell: ShellInspection
    /// The bundle ID to install under. Settings may pick one the device has, otherwise it is shell.json's.
    package var bundleID = ""
    /// The built app's embedded.mobileprovision and its current entitlements.
    package var embeddedProfile: ProvisioningProfile?
    package var appEntitlements: [String: EntitlementValue] = [:]
    /// The team the device's copy was signed with, when the Resigner or the launcher knows it.
    package var deviceCopyTeam = ""
    /// Choices for this run: sign without the Increased Memory Limit, install although no NX2Apple is on the device.
    package var allowWithoutMemoryLimit = false
    package var allowFirstInstall = false

    package init(shell: ShellInspection) { self.shell = shell }

    // MARK: Derived

    package var activeDeveloperDir: String? { chosenDeveloperDir ?? selectedDeveloperDir }
    package var activeXcode: XcodeInstall? {
        guard let dir = activeDeveloperDir, let app = ToolPaths.xcodeApp(ofDeveloperDir: dir) else { return nil }
        return xcodes.first { $0.path == app } ?? xcodes.first { dir.hasPrefix($0.path + "/") }
    }
    package var resolvedRoute: SigningRoute { route.resolved(projectUsable: shell.project.usable) }
    package var device: DeviceStatus? { devices.first { $0.udid == selectedDevice } }
    package var targetBundleID: String { bundleID.isEmpty ? shell.bundleID : bundleID }

    /// The entitlements the renewed app must keep: what the built app has now (beyond the identity keys) and, for the Xcode route,
    /// what the project asks for.
    package var requiredEntitlements: [String] {
        var keys = Set(appEntitlements.keys).subtracting(["application-identifier", "com.apple.developer.team-identifier",
                                                         "get-task-allow", "keychain-access-groups"])
        if resolvedRoute == .xcode, shell.project.requestsEntitlements { keys.insert(EntitlementPlanner.memoryLimit) }
        if allowWithoutMemoryLimit { keys.remove(EntitlementPlanner.memoryLimit) }
        return keys.sorted()
    }

    /// The certificate that signs on the profile route: the chosen one, else the newest valid development one of the team.
    package var signingCertificate: CertificateRecord? {
        let usable = certificates.filter { $0.hasPrivateKey && $0.identity?.valid == true && !$0.expired(now: now) }
        if !selectedIdentity.isEmpty { return certificates.first { $0.sha1 == selectedIdentity.uppercased() } }
        return usable.filter { $0.team == selectedTeam && $0.kind == .development }
            .max { ($0.notAfter ?? .distantPast) < ($1.notAfter ?? .distantPast) }
            ?? usable.first { $0.team == selectedTeam }
    }

    package var profileRequirement: ProfileRequirement {
        ProfileRequirement(bundleID: targetBundleID, teamID: selectedTeam.isEmpty ? nil : selectedTeam,
                           certificateSHA1: signingCertificate?.sha1, deviceUDID: selectedDevice.isEmpty ? nil : selectedDevice,
                           deviceName: device?.name ?? "", entitlements: requiredEntitlements, now: now)
    }

    /// The profile the profile route would embed: the chosen one, else the best fit.
    package var signingProfile: ProvisioningProfile? {
        if !selectedProfile.isEmpty { return profiles.first { $0.uuid == selectedProfile } }
        return ProfileMatcher.candidates(profiles, profileRequirement).first
    }

    /// When no profile fits only because the app asks for the Increased Memory Limit: the one that fits without it, so the user is
    /// told exactly that and may choose to sign without it.
    package var profileWithoutMemoryLimit: ProvisioningProfile? {
        var without = profileRequirement
        guard without.entitlements.contains(EntitlementPlanner.memoryLimit) else { return nil }
        without.entitlements.removeAll { $0 == EntitlementPlanner.memoryLimit }
        if !selectedProfile.isEmpty {
            guard let chosen = profiles.first(where: { $0.uuid == selectedProfile }),
                  !ProfileMatcher.issues(chosen, without).contains(where: \.blocking) else { return nil }
            return chosen
        }
        return ProfileMatcher.candidates(profiles, without).first
    }

    package var team: SigningTeam? { teams.first { $0.id == selectedTeam } }
}

/// What to read, from the Settings and the dashboard's choices.
package struct ProbeRequest: Equatable, Sendable {
    package var shellRoot: String
    package var configuration = "Release"
    package var developerDir: String?
    package var route: SigningRoute = .automatic
    package var device = ""
    package var team = ""
    package var identity = ""
    package var profile = ""
    package var bundleID = ""
    package var readInstalledApps = true

    package init(shellRoot: String, configuration: String = "Release", developerDir: String? = nil, route: SigningRoute = .automatic,
                 device: String = "", team: String = "", identity: String = "", profile: String = "", bundleID: String = "",
                 readInstalledApps: Bool = true) {
        self.shellRoot = shellRoot; self.configuration = configuration; self.developerDir = developerDir; self.route = route
        self.device = device; self.team = team; self.identity = identity; self.profile = profile; self.bundleID = bundleID
        self.readInstalledApps = readInstalledApps
    }
}

/// Reads the facts. Every tool starts through the runner with fixed arguments and a deadline, and nothing is changed.
package struct EnvironmentProbe {
    package var runner: ProcessRunner
    package var home: String
    package var fm: FileManager
    /// Where Xcode is looked for.
    package var applicationFolders: [String]
    /// The tools' paths. A chosen Xcode's `DEVELOPER_DIR` goes on top for each read.
    package var baseTools = ToolPaths()

    package init(runner: ProcessRunner = SystemProcessRunner(), home: String = NSHomeDirectory(), fm: FileManager = .default,
                 applicationFolders: [String]? = nil) {
        self.runner = runner; self.home = home; self.fm = fm
        self.applicationFolders = applicationFolders ?? ["/Applications", home + "/Applications"]
    }

    private func capture(_ tools: ToolPaths, _ executable: String, _ args: [String], timeout: TimeInterval = 30, merge: Bool = false) -> ProcessResult {
        runner.capture(ProcessLaunch(executable: executable, arguments: args, environment: tools.environment(home: home),
                                     mergesErrors: merge, timeout: timeout))
    }

    package func read(_ request: ProbeRequest) -> EnvironmentFacts {
        var tools = baseTools
        tools.developerDir = request.developerDir
        var f = EnvironmentFacts(shell: ShellInspector.inspect(root: request.shellRoot, configuration: request.configuration, fm: fm))
        f.route = request.route
        f.chosenDeveloperDir = request.developerDir
        f.selectedDevice = request.device
        f.selectedTeam = request.team
        f.selectedIdentity = request.identity
        f.selectedProfile = request.profile
        f.bundleID = request.bundleID

        f.macOSVersion = capture(tools, tools.swVers, ["-productVersion"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        f.selectedDeveloperDir = Toolchain.developerDir(runner: runner)
        let extra = [f.selectedDeveloperDir, request.developerDir].compactMap { $0 }.compactMap(ToolPaths.xcodeApp(ofDeveloperDir:))
        f.xcodes = XcodeLocator.find(roots: applicationFolders, extra: extra, fm: fm)
        readXcode(tools, into: &f)

        f.commandLineToolsInstalled = fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin")
        f.xcrunWorks = capture(tools, tools.xcrun, ["--version"]).ok
        f.codesignPresent = fm.isExecutableFile(atPath: tools.codesign)
        f.securityPresent = fm.isExecutableFile(atPath: tools.security)

        readDevices(tools, request, into: &f)
        readSigning(tools, into: &f)
        f.profiles = ProvisioningProfiles.load(home: home, runner: runner, tools: tools, fm: fm)
        if let app = f.shell.app {
            if app.hasEmbeddedProfile { f.embeddedProfile = ProvisioningProfiles.read(app.path + "/" + AppSignature.profileName, runner: runner, tools: tools) }
            f.appEntitlements = entitlements(ofApp: app.path, tools: tools)
        }
        f.deviceCopyTeam = f.shell.team
        return f
    }

    private func readXcode(_ tools: ToolPaths, into f: inout EnvironmentFacts) {
        let version = capture(tools, tools.xcrun, ["xcodebuild", "-version"], merge: true)
        let lines = version.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if version.ok, let first = lines.first { f.xcodebuildVersion = first }
        else { f.xcodebuildError = lines.last ?? "" }
        guard f.xcodebuildVersion != nil || version.out.contains("license") else { return }
        f.licenseAccepted = capture(tools, tools.xcrun, ["xcodebuild", "-license", "check"], merge: true).status == 0
        if f.xcodebuildVersion != nil {
            f.firstLaunchDone = capture(tools, tools.xcrun, ["xcodebuild", "-checkFirstLaunchStatus"], merge: true).status == 0
            let sdk = capture(tools, tools.xcrun, ["--sdk", "iphoneos", "--show-sdk-version"])
            let text = sdk.out.trimmingCharacters(in: .whitespacesAndNewlines)
            f.iosSDKVersion = sdk.ok && !text.isEmpty ? text : nil
        }
    }

    private func readDevices(_ tools: ToolPaths, _ request: ProbeRequest, into f: inout EnvironmentFacts) {
        let find = capture(tools, tools.xcrun, ["--find", "devicectl"])
        let path = find.out.trimmingCharacters(in: .whitespacesAndNewlines)
        f.devicectlPath = find.ok && !path.isEmpty ? path : nil
        guard f.devicectlPath != nil else { return }
        let json = temporaryFile("devices", "json")
        defer { try? fm.removeItem(atPath: json) }
        let list = capture(tools, tools.xcrun, DeviceInventory.listArguments(json: json), timeout: 30, merge: true)
        f.deviceListWorked = list.ok
        if let data = fm.contents(atPath: json) { f.devices = DeviceInventory.parse(data) }
        if f.selectedDevice.isEmpty, let first = f.devices.first(where: { $0.connected && $0.paired }) { f.selectedDevice = first.udid }
        if request.readInstalledApps, let device = f.device, device.connected, device.paired {
            f.installedApps = installedApps(device: device.udid, tools: tools)
        }
    }

    private func readSigning(_ tools: ToolPaths, into f: inout EnvironmentFacts) {
        let inspector = IdentityInspector(runner: runner, tools: tools)
        f.identities = inspector.identities()
        f.certificates = SigningIdentities.join(certificates: inspector.certificates(), identities: f.identities)
        f.xcodeAccountTeams = DeviceTools.xcodeTeams(runner: runner)
        f.teams = DeviceTools.merge(certificates: SigningIdentities.teams(f.certificates), xcode: f.xcodeAccountTeams)
        if f.selectedTeam.isEmpty { f.selectedTeam = f.shell.team.isEmpty ? (f.teams.first?.id ?? "") : f.shell.team }
    }

    /// The device's apps (`devicectl device info apps`), nil when they could not be read.
    package func installedApps(device: String, tools: ToolPaths) -> [InstalledApp]? {
        let json = temporaryFile("apps", "json")
        defer { try? fm.removeItem(atPath: json) }
        let r = capture(tools, tools.xcrun, ["devicectl"] + InstalledApps.listArguments(device: device, json: json), timeout: 45, merge: true)
        guard r.ok, let data = fm.contents(atPath: json) else { return nil }
        return InstalledApps.parse(data)
    }

    /// The app's signed entitlements (`codesign -d --entitlements - --xml`, or the older `:-` form), empty when it has none.
    package func entitlements(ofApp app: String, tools: ToolPaths) -> [String: EntitlementValue] {
        for args in [["-d", "--entitlements", "-", "--xml", app], ["-d", "--entitlements", ":-", app]] {
            let r = capture(tools, tools.codesign, args, timeout: 30)
            guard r.ok, let start = r.out.range(of: "<?xml") ?? r.out.range(of: "<plist") else { continue }
            let xml = Data(r.out[start.lowerBound...].utf8)
            if let dict = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any] {
                return EntitlementValue.dictionary(dict)
            }
        }
        return [:]
    }

    private func temporaryFile(_ name: String, _ ext: String) -> String {
        NSTemporaryDirectory() + "nx2apple-resigner-\(name)-\(UUID().uuidString.prefix(8)).\(ext)"
    }
}

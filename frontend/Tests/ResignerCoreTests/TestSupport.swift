import Foundation
import XCTest
@testable import NXCore
@testable import ResignerCore

/// A process runner that answers from rules. A rule matches when its pattern is part of the command line (the executable and the
/// arguments joined by spaces). The rule added last wins, so a test overrides the healthy defaults by adding its own. A rule can
/// write a JSON file where the command asks for one (`--json-output <path>`). Every launch is kept, so a test can check what ran.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    struct Rule {
        var pattern: String
        var status: Int32
        var out: String
        var json: Data?
        var action: ((ProcessLaunch) -> Void)?
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private(set) var launches: [ProcessLaunch] = []

    var commands: [String] { lock.lock(); defer { lock.unlock() }; return launches.map { ([$0.executable] + $0.arguments).joined(separator: " ") } }

    func on(_ pattern: String, status: Int32 = 0, out: String = "", json: Data? = nil, action: ((ProcessLaunch) -> Void)? = nil) {
        lock.lock(); rules.append(Rule(pattern: pattern, status: status, out: out, json: json, action: action)); lock.unlock()
    }

    private func answer(_ launch: ProcessLaunch) -> Rule? {
        lock.lock()
        launches.append(launch)
        let line = ([launch.executable] + launch.arguments).joined(separator: " ")
        let rule = rules.last { line.contains($0.pattern) }
        lock.unlock()
        guard let rule else { return nil }
        if let json = rule.json, let i = launch.arguments.firstIndex(of: "--json-output"), i + 1 < launch.arguments.count {
            try? json.write(to: URL(fileURLWithPath: launch.arguments[i + 1]))
        }
        rule.action?(launch)
        return rule
    }

    func capture(_ launch: ProcessLaunch) -> ProcessResult {
        guard let rule = answer(launch) else { return ProcessResult(status: 1, out: "", err: "no rule") }
        return ProcessResult(status: rule.status, out: rule.out)
    }

    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool {
        let r = capture(launch)
        r.out.split(separator: "\n").forEach { line(String($0)) }
        return r.ok
    }

    func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
        guard let rule = answer(launch) else { line("no rule"); return ProcessResult(status: 1) }
        rule.out.split(separator: "\n", omittingEmptySubsequences: false).forEach { line(String($0)) }
        return ProcessResult(status: rule.status)
    }

    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        throw NSError(domain: "FakeRunner", code: 1)
    }
}

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
    static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
}

/// frontend/l10n, read once, to check that every text the core produces exists in English and Chinese with its placeholders.
enum Texts {
    static let frontend = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let en = load("en"), zh = load("zh")

    static func load(_ code: String) -> [String: String] {
        let url = frontend.appendingPathComponent("l10n/\(code).json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    static func placeholders(_ text: String) -> Int {
        let re = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?@")
        let ns = text as NSString
        var positions = Set<Int>(), next = 1
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if let n = Int(s.dropFirst().split(separator: "$").first ?? ""), s.contains("$") { positions.insert(n) } else { positions.insert(next); next += 1 }
        }
        return positions.count
    }

    static func check(_ text: LocalText?, file: StaticString = #filePath, line: UInt = #line) {
        guard let text else { return }
        guard let english = en[text.key] else { XCTFail("\(text.key) is not in en.json", file: file, line: line); return }
        XCTAssertNotNil(zh[text.key], "\(text.key) is not in zh.json", file: file, line: line)
        XCTAssertEqual(placeholders(english), text.args.count, "\(text.key) takes \(placeholders(english)) arguments, got \(text.args.count)",
                       file: file, line: line)
    }

    static func check(_ items: [DependencyItem], file: StaticString = #filePath, line: UInt = #line) {
        for item in items {
            check(item.name, file: file, line: line); check(item.explanation, file: file, line: line); check(item.remediation, file: file, line: line)
            item.actions.forEach { check($0.label, file: file, line: line) }
        }
    }
}

/// A Mac made of files in a temporary folder and a runner that answers like a healthy setup: Xcode 27.2 selected, its license
/// accepted, one Apple Development identity, an Xcode account for its team, an iPad on a cable with NX2Apple installed, and the
/// launcher's shell root with a built app holding one game. Each test breaks what it is about.
final class TestMac {
    static let team = "TEAM123456"
    static let udid = "00008112-001A2B3C4D5E6F70"
    static let bundleID = "org.nxnative.shell"
    static let titleID = "0100000000010000"
    static let certificateDER = Data("NX2Apple Resigner test certificate".utf8)
    static var certificateSHA1: String { SHA1.hex(certificateDER) }
    static let profileUUID = "11111111-2222-3333-4444-555555555555"

    let fm = FileManager.default
    let base: String
    let home: String
    let applications: String
    let xcode: String
    let root: String
    let runner = FakeRunner()
    let now = Date()

    var developerDir: String { xcode + "/Contents/Developer" }
    var appPath: String { ShellInstall.appPath(root: root) }
    var profilesFolder: String { home + "/Library/Developer/Xcode/UserData/Provisioning Profiles" }
    var profilePath: String { profilesFolder + "/" + Self.profileUUID + ".mobileprovision" }

    init() {
        base = NSTemporaryDirectory() + "resigner-tests-" + UUID().uuidString
        home = base + "/home"
        applications = base + "/Applications"
        xcode = applications + "/Xcode.app"
        root = home + "/Library/Application Support/NX2Apple/shell"
        makeXcode()
        makeShell()
        makeTools()
        defaultRules()
    }

    deinit { try? fm.removeItem(atPath: base) }

    func write(_ path: String, _ text: String) {
        try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func plist(_ object: Any) -> String {
        String(decoding: try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0), as: UTF8.self)
    }

    private func makeXcode() {
        write(xcode + "/Contents/Info.plist", plist(["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "27.2"]))
        write(xcode + "/Contents/version.plist", plist(["ProductBuildVersion": "17C52"]))
        try! fm.createDirectory(atPath: developerDir, withIntermediateDirectories: true)
    }

    /// The fixed tool paths of the core point into the temporary folder: a Linux machine has no /usr/bin/codesign, and the runner
    /// answers by command line anyway.
    var tools: ToolPaths {
        var t = ToolPaths()
        t.codesign = base + "/bin/codesign"
        t.security = base + "/bin/security"
        return t
    }

    private func makeTools() {
        for tool in ["codesign", "security"] {
            write(base + "/bin/" + tool, "#!/bin/sh\nexit 1\n")
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base + "/bin/" + tool)
        }
    }

    private func makeShell() {
        let mirror = ShellInstall.mirroredFramework(root: root, titleID: Self.titleID)
        let library = ShellLibrary(bundleID: Self.bundleID, team: Self.team,
                                   games: [.init(titleID: Self.titleID, name: "Test Game", framework: mirror)])
        try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try! library.save(root: root)
        writeFramework(mirror)
        // The project, its links into an engine tree, the frameworks it embeds, the entitlements request
        let project = ShellInstall.projectFolder(root: root)
        write(project + "/" + ShellInstall.projectName + "/project.pbxproj", "// project")
        for link in ["Sources", "Shell", "tools"] {
            try! fm.createDirectory(atPath: base + "/engine/dm/ios/" + link, withIntermediateDirectories: true)
            try! fm.createSymbolicLink(atPath: project + "/" + link, withDestinationPath: base + "/engine/dm/ios/" + link)
        }
        write(project + "/frameworks.txt", "\(Self.titleID)\t\(mirror)\tTest Game\n")
        write(project + "/Gen/dm.xcconfig", "CODE_SIGN_ENTITLEMENTS = Gen/DmShell.entitlements\n")
        // The built app
        write(appPath + "/Info.plist", plist(["CFBundleIdentifier": Self.bundleID, "CFBundleDisplayName": "NX2Apple",
                                              "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1.0", "CFBundleExecutable": "DmShell",
                                              "MinimumOSVersion": "26.0"]))
        write(appPath + "/DmShell", "binary")
        write(appPath + "/embedded.mobileprovision", "cms")
        writeFramework(appPath + "/Frameworks/DmGame\(Self.titleID).framework")
        write(appPath + "/Frameworks/libextra.dylib", "dylib")
    }

    func writeFramework(_ path: String) {
        write(path + "/game.manifest.json", #"{"title_id": "\#(Self.titleID)", "name": "Test Game", "framework": "DmGame\#(Self.titleID).framework", "framework_executable": "DmGame\#(Self.titleID)", "loader": "FH"}"#)
        write(path + "/DmGame\(Self.titleID)", "binary")
    }

    func profile(expires: Date? = nil, devices: [String] = [TestMac.udid], appID: String = TestMac.team + "." + TestMac.bundleID,
                 team: String = TestMac.team, certificates: [Data] = [TestMac.certificateDER], memory: Bool = true,
                 uuid: String = TestMac.profileUUID, name: String = "iOS Team Provisioning Profile: org.nxnative.shell") -> [String: Any] {
        var entitlements: [String: Any] = ["application-identifier": appID, "com.apple.developer.team-identifier": team,
                                           "get-task-allow": true, "keychain-access-groups": [team + ".*"]]
        if memory { entitlements[EntitlementPlanner.memoryLimit] = true }
        return ["UUID": uuid, "Name": name, "TeamIdentifier": [team], "TeamName": "Jane Appleseed", "AppIDName": "NX2Apple",
                "CreationDate": now.addingTimeInterval(-2 * 86400), "ExpirationDate": expires ?? now.addingTimeInterval(5 * 86400),
                "ProvisionedDevices": devices, "DeveloperCertificates": certificates, "Entitlements": entitlements, "Platform": ["iOS"],
                "IsXcodeManaged": true]
    }

    func installProfile(_ dict: [String: Any], at path: String? = nil) {
        let path = path ?? profilePath
        write(path, "cms envelope")
        runner.on("cms -D -i " + path, out: plist(dict))
    }

    static func pem(_ der: Data) -> String {
        "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString() + "\n-----END CERTIFICATE-----\n"
    }

    static func opensslDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "MMM d HH:mm:ss yyyy"
        return f.string(from: date) + " GMT"
    }

    func identity(valid: Bool = true) {
        let sha = Self.certificateSHA1
        let suffix = valid ? "" : " (CSSMERR_TP_CERT_REVOKED)"
        runner.on("find-identity -p codesigning", out: """
        Policy: Code Signing
          Matching identities
          1) \(sha) "Apple Development: Jane Appleseed (ABCDE12345)"\(suffix)
             1 identities found
        """)
    }

    private func defaultRules() {
        let r = runner
        r.on("sw_vers -productVersion", out: "26.6\n")
        r.on("xcode-select -p", out: developerDir + "\n")
        r.on("xcrun xcodebuild -version", out: "Xcode 27.2\nBuild version 17C52\n")
        r.on("xcodebuild -license check")
        r.on("xcodebuild -checkFirstLaunchStatus")
        r.on("--sdk iphoneos --show-sdk-version", out: "26.2\n")
        r.on("xcrun --version", out: "xcrun version 72.\n")
        r.on("xcrun --find devicectl", out: developerDir + "/usr/bin/devicectl\n")
        r.on("devicectl list devices", json: Fixture.data("devices-xcode26.json"))
        r.on("devicectl device info apps", json: Fixture.data("apps-with-shell.json"))
        identity()
        r.on("find-certificate -a -Z -p -c Apple Development", out: "SHA-256 hash: 00\nSHA-1 hash: \(Self.certificateSHA1)\n" + Self.pem(Self.certificateDER))
        r.on("x509 -noout -subject", out: """
        subject= /UID=ABCDE12345/CN=Apple Development: Jane Appleseed (ABCDE12345)/OU=\(Self.team)/O=Jane Appleseed/C=US
        notBefore=\(Self.opensslDate(now.addingTimeInterval(-30 * 86400)))
        notAfter=\(Self.opensslDate(now.addingTimeInterval(300 * 86400)))
        """)
        r.on("defaults export com.apple.dt.Xcode -", out: plist(["IDEProvisioningTeamByIdentifier": ["account": [
            ["teamID": Self.team, "teamName": "Jane Appleseed", "teamType": "Individual", "isFreeProvisioningTeam": false]]]]))
        // The built app's signature as the launcher left it
        r.on("cms -D -i " + appPath + "/embedded.mobileprovision", out: plist(profile()))
        r.on("--entitlements - --xml", out: plist(["application-identifier": Self.team + "." + Self.bundleID,
                                                   "com.apple.developer.team-identifier": Self.team, "get-task-allow": true,
                                                   EntitlementPlanner.memoryLimit: true]))
        installProfile(profile())
        // The re-sign itself
        r.on("xcodebuild -project", out: "Signing Identity: \"Apple Development: Jane Appleseed (ABCDE12345)\"\n** BUILD SUCCEEDED **\n")
        r.on("--verify --deep --strict", out: "valid on disk\nsatisfies its designated requirement\n")
        r.on("codesign --verify")
        r.on("--force --sign")
        r.on("/usr/bin/xattr -cr")
        r.on("devicectl device install app", out: "App installed:\n• bundleID: org.nxnative.shell\n")
    }

    func request(route: SigningRoute = .automatic, device: String = TestMac.udid, team: String = TestMac.team) -> ProbeRequest {
        ProbeRequest(shellRoot: root, route: route, device: device, team: team)
    }

    var probe: EnvironmentProbe {
        var p = EnvironmentProbe(runner: runner, home: home, applicationFolders: [applications])
        p.baseTools = tools
        return p
    }

    func facts(route: SigningRoute = .automatic) -> EnvironmentFacts { probe.read(request(route: route)) }

    func pipeline(log: @escaping (String) -> Void = { _ in }) -> ResignPipeline {
        var p = ResignPipeline(runner: runner, home: home)
        p.applicationFolders = [applications]
        p.baseTools = tools
        p.temporaryFolder = base + "/tmp/"
        try? fm.createDirectory(atPath: base + "/tmp", withIntermediateDirectories: true)
        p.log = log
        return p
    }
}

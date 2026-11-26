import XCTest
@testable import NXCore
@testable import ResignerCore

final class ResignPipelineTests: XCTestCase {
    var mac: TestMac!
    var steps: [(ResignStep, StepState)] = []
    var log = ""

    override func setUp() { mac = TestMac(); steps = []; log = "" }
    override func tearDown() { mac = nil }

    func resign(_ route: SigningRoute = .automatic, team: String = TestMac.team, device: String = TestMac.udid, allowWithoutMemoryLimit: Bool = false,
             allowFirstInstall: Bool = false, bundleID: String = "", cancelAt: ResignStep? = nil) -> ResignOutcome {
        var pipeline = mac.pipeline { [unowned self] in self.log += $0 }
        var reached: ResignStep?
        pipeline.step = { [unowned self] s, state, _ in
            self.steps.append((s, state))
            if state == .running { reached = s }
        }
        pipeline.cancelled = { cancelAt != nil && reached == cancelAt }
        var probe = mac.request(route: route, device: device, team: team)
        probe.bundleID = bundleID
        let outcome = pipeline.run(ResignRequest(probe: probe, allowWithoutMemoryLimit: allowWithoutMemoryLimit, allowFirstInstall: allowFirstInstall))
        if let failure = outcome.failure { Texts.check(failure.message); Texts.check(failure.remedy) }
        outcome.notes.forEach { Texts.check($0) }
        assertNeverRemovesAnything()
        return outcome
    }

    func assertNeverRemovesAnything(file: StaticString = #filePath, line: UInt = #line) {
        for launch in mac.runner.launches {
            let command = ([launch.executable] + launch.arguments).joined(separator: " ")
            XCTAssertFalse(command.contains("uninstall"), command, file: file, line: line)
            XCTAssertFalse(launch.executable.hasSuffix("/sh") || launch.executable.hasSuffix("/bash") || launch.executable.hasSuffix("/zsh"),
                           "no shell: \(command)", file: file, line: line)
            XCTAssertTrue(launch.executable.hasPrefix("/"), "a fixed path: \(command)", file: file, line: line)
        }
    }

    func commands(containing text: String) -> [String] { mac.runner.commands.filter { $0.contains(text) } }

    // MARK: Success

    func testTheXcodeRouteSignsTheLaunchersProjectAgainAndUpdatesTheApp() throws {
        let outcome = resign(.xcode)
        XCTAssertTrue(outcome.ok, "\(String(describing: outcome.failure))")
        let build = try XCTUnwrap(commands(containing: "xcodebuild -project").first)
        XCTAssertTrue(build.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(build.contains("DEVELOPMENT_TEAM=\(TestMac.team)"))
        XCTAssertTrue(build.contains("PRODUCT_BUNDLE_IDENTIFIER=\(TestMac.bundleID)"), "the bundle ID the device has: its data stays")
        XCTAssertTrue(build.contains("-destination id=\(TestMac.udid)"))
        XCTAssertTrue(build.contains("-configuration Release"))
        XCTAssertFalse(build.contains("CODE_SIGN_ENTITLEMENTS="), "nothing is left out without the user's word")
        XCTAssertEqual(build, ResignPipeline.xcodeCommand(xcrun: "/usr/bin/xcrun", root: mac.root, device: TestMac.udid, team: TestMac.team,
                                                          bundleID: TestMac.bundleID, configuration: "Release", withoutEntitlements: false).joined(separator: " "),
                       "the launcher's own re-sign command")
        let install = try XCTUnwrap(commands(containing: "devicectl device install app").first)
        XCTAssertTrue(install.hasSuffix(mac.appPath), "the launcher's signed app goes over the installed one")
        let order = ["xcodebuild -project", "--verify --deep --strict", "devicectl device install app"].map { p in mac.runner.commands.firstIndex { $0.contains(p) }! }
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(mac.runner.commands.last!.contains("devicectl device info apps"), "the install is checked on the device")
        XCTAssertEqual(steps.filter { $0.1 == .done }.map(\.0), ResignStep.allCases)
        XCTAssertEqual(outcome.deviceName, "Jane's iPad")
        XCTAssertEqual(outcome.games, 1)
        XCTAssertNotNil(outcome.profileExpiry)
        XCTAssertFalse(outcome.firstInstall)
    }

    func testTheProfileRouteSignsACopyFrameworksFirstAndLeavesTheLaunchersAppAlone() throws {
        mac.runner.on("Payload/DmShell.app/embedded.mobileprovision", out: mac.plist(mac.profile()))
        let launchersProfile = try String(contentsOfFile: mac.appPath + "/embedded.mobileprovision", encoding: .utf8)
        var entitlements: [String: Any] = [:]
        mac.runner.on("--entitlements", action: { launch in
            guard let i = launch.arguments.firstIndex(of: "--entitlements"), launch.arguments[i + 1].hasSuffix(".plist"),
                  let data = FileManager.default.contents(atPath: launch.arguments[i + 1]) else { return }
            entitlements = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] ?? [:]
        })
        mac.runner.on("--entitlements - --xml", out: mac.plist(["application-identifier": TestMac.team + "." + TestMac.bundleID, EntitlementPlanner.memoryLimit: true]))
        let outcome = resign(.profile)
        XCTAssertTrue(outcome.ok, "\(String(describing: outcome.failure))")
        XCTAssertTrue(commands(containing: "xcodebuild -project").isEmpty, "no Xcode project on this route")
        let signed = commands(containing: "--force --sign \(TestMac.certificateSHA1) --timestamp=none --generate-entitlement-der")
        XCTAssertEqual(signed.count, 3)
        XCTAssertTrue(signed[0].hasSuffix("/Frameworks/DmGame\(TestMac.titleID).framework"))
        XCTAssertTrue(signed[1].hasSuffix("/Frameworks/libextra.dylib"))
        XCTAssertTrue(signed[2].hasSuffix("/Payload/DmShell.app") && signed[2].contains("--entitlements"), "the app last, with its entitlements")
        XCTAssertEqual(entitlements["application-identifier"] as? String, TestMac.team + "." + TestMac.bundleID)
        XCTAssertEqual(entitlements[EntitlementPlanner.memoryLimit] as? Bool, true, "the Increased Memory Limit is kept")
        let install = try XCTUnwrap(commands(containing: "devicectl device install app").first)
        XCTAssertTrue(install.contains(mac.base + "/tmp/nx2apple-resigner-"), "the signed copy is installed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mac.base + "/tmp"), [], "the copy is removed afterwards")
        XCTAssertEqual(try String(contentsOfFile: mac.appPath + "/embedded.mobileprovision", encoding: .utf8), launchersProfile)
        XCTAssertEqual(outcome.profileName, "iOS Team Provisioning Profile: org.nxnative.shell")
        XCTAssertTrue(commands(containing: "--force --sign \(TestMac.certificateSHA1) --timestamp=none ").first!.contains("nx2apple-resigner-test-"),
                      "the trial signature ran first")
    }

    func testAFirstInstallNeedsTheUsersWord() {
        mac.runner.on("devicectl device info apps", json: Fixture.data("apps-none.json"))
        let refused = resign(.xcode)
        XCTAssertEqual(refused.failure?.kind, .firstInstall)
        XCTAssertTrue(commands(containing: "xcodebuild -project").isEmpty)
        mac.runner.on("devicectl device install app", action: { _ in self.mac.runner.on("devicectl device info apps", json: Fixture.data("apps-with-shell.json")) })
        let confirmed = resign(.xcode, allowFirstInstall: true)
        XCTAssertTrue(confirmed.ok)
        XCTAssertTrue(confirmed.firstInstall)
    }

    // MARK: Stops before signing

    func testNoDeviceConnected() {
        mac.runner.on("devicectl list devices", json: Data(#"{"result": {"devices": []}}"#.utf8))
        let outcome = resign()
        XCTAssertEqual(outcome.failure?.step, .detectingDevice)
        XCTAssertEqual(outcome.failure?.kind, .device)
        XCTAssertEqual(outcome.failure?.message.key, "resigner.dep.device.none")
        XCTAssertTrue(commands(containing: "install app").isEmpty)
    }

    func testADeviceConnectedButNotTrusted() {
        let outcome = resign(device: "00008140-000A1B2C3D4E5F60")
        XCTAssertEqual(outcome.failure?.message.key, "resigner.device.notPaired")
        XCTAssertTrue(commands(containing: "xcodebuild -project").isEmpty)
    }

    func testADeviceThatIsUnavailable() {
        let outcome = resign(device: "00008110-000C1D2E3F405060")
        XCTAssertEqual(outcome.failure?.message.key, "resigner.device.notConnected")
    }

    func testTheDevicesAppsCannotBeRead() {
        mac.runner.on("devicectl device info apps", status: 1, out: "ERROR: The device is locked")
        let outcome = resign()
        XCTAssertEqual(outcome.failure?.message.key, "resigner.fail.appList")
        XCTAssertTrue(commands(containing: "xcodebuild -project").isEmpty)
    }

    func testNX2AppleUnderAnotherBundleIDOnly() {
        mac.runner.on("devicectl device info apps", json: Fixture.data("apps-team-variant.json"))
        let outcome = resign()
        XCTAssertEqual(outcome.failure?.kind, .otherBundle)
        XCTAssertEqual(outcome.failure?.message.args.first, "org.nxnative.shell.TEAM123456")
    }

    func testAnotherTeamThanTheDevicesCopy() {
        let outcome = resign(team: "OTHER12345")
        XCTAssertEqual(outcome.failure?.kind, .teamMismatch)
        XCTAssertEqual(outcome.failure?.step, .validatingCredentials)
        XCTAssertTrue(commands(containing: "xcodebuild -project").isEmpty)
    }

    func testAMissingDependencyStopsFirst() {
        mac.runner.on("xcode-select -p", status: 2, out: "")
        try! FileManager.default.removeItem(atPath: mac.xcode)
        mac.runner.on("xcrun xcodebuild -version", status: 1, out: "xcrun: error: unable to find utility \"xcodebuild\"")
        let outcome = resign()
        XCTAssertEqual(outcome.failure?.step, .checkingEnvironment)
        XCTAssertEqual(outcome.failure?.kind, .dependency)
        XCTAssertEqual(outcome.failure?.message.key, "resigner.dep.xcode.missing")
    }

    func testTheProfileRoutesTrialSignatureFails() {
        mac.runner.on("--timestamp=none " + mac.base + "/tmp/nx2apple-resigner-test", status: 1, out: "probe: errSecInternalComponent")
        let outcome = resign(.profile)
        XCTAssertEqual(outcome.failure?.step, .validatingCredentials)
        XCTAssertEqual(outcome.failure?.message.key, "resigner.dep.testSign.denied")
        XCTAssertEqual(commands(containing: "--generate-entitlement-der").count, 0, "nothing of the app is signed")
    }

    func testAProfileThatCannotCarryTheMemoryLimit() {
        mac.installProfile(mac.profile(memory: false))
        let outcome = resign(.profile)
        XCTAssertEqual(outcome.failure?.kind, .memoryCapability, "named, not stripped silently")
    }

    func testStopBeforeSigning() {
        let outcome = resign(.xcode, cancelAt: .signing)
        XCTAssertEqual(outcome.failure?.kind, .cancelled)
        XCTAssertTrue(commands(containing: "xcodebuild -project").isEmpty)
        XCTAssertTrue(commands(containing: "install app").isEmpty)
    }

    // MARK: Signing failures

    func testTheTeamCannotCarryTheIncreasedMemoryLimit() throws {
        mac.runner.on("xcodebuild -project", status: 65,
                      out: "error: Provisioning profile \"iOS Team Provisioning Profile: org.nxnative.shell\" doesn't include the com.apple.developer.kernel.increased-memory-limit entitlement.")
        let refused = resign(.xcode)
        XCTAssertEqual(refused.failure?.kind, .memoryCapability)
        XCTAssertEqual(commands(containing: "xcodebuild -project").count, 1, "no second attempt without the user's word")
        mac.runner.on("xcodebuild -project", out: "** BUILD SUCCEEDED **")
        let consented = resign(.xcode, allowWithoutMemoryLimit: true)
        XCTAssertTrue(consented.ok, "\(String(describing: consented.failure))")
        XCTAssertTrue(try XCTUnwrap(commands(containing: "xcodebuild -project").last).contains("CODE_SIGN_ENTITLEMENTS= build"))
        XCTAssertEqual(consented.droppedEntitlements, [EntitlementPlanner.memoryLimit])
        XCTAssertTrue(log.contains("left out, as chosen for this run"))
    }

    func testTheBundleIDBelongsToAnotherTeamAndNoVariantIsTried() {
        mac.runner.on("xcodebuild -project", status: 65, out: "error: The app identifier \"org.nxnative.shell\" cannot be registered to your development team because it is not available.")
        let outcome = resign(.xcode)
        XCTAssertEqual(outcome.failure?.kind, .teamTaken)
        XCTAssertTrue(commands(containing: "PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.shell.").isEmpty, "the launcher's team variant would be a new, empty app")
        XCTAssertTrue(commands(containing: "install app").isEmpty)
    }

    func testOtherXcodeFailuresAreNamed() {
        let cases: [(String, String)] = [
            ("error: No Account for Team \"TEAM123456\". Add a new account in Accounts settings", "resigner.fail.noAccount"),
            ("error: Unable to find a destination matching the provided destination specifier", "resigner.fail.destination"),
            ("error: Build input file cannot be found: '/x/Shell/main.m'", "resigner.fail.projectFiles"),
            ("error: something nobody has seen", "resigner.fail.xcodebuild"),
        ]
        for (output, key) in cases {
            let failure = FailureClassifier.xcodebuild(output, team: TestMac.team, bundleID: TestMac.bundleID)
            XCTAssertEqual(failure.message.key, key, output)
            Texts.check(failure.message); Texts.check(failure.remedy)
            XCTAssertFalse(failure.detail.isEmpty, "the tool's own line is kept")
        }
    }

    func testSignatureVerificationFails() {
        mac.runner.on("codesign --verify", status: 1, out: "DmShell.app: a sealed resource is missing or invalid")
        let outcome = resign(.xcode)
        XCTAssertEqual(outcome.failure?.step, .verifyingSignature)
        XCTAssertTrue(commands(containing: "install app").isEmpty, "a broken signature is never installed")
    }

    func testAStrictOnlyComplaintIsANote() {
        mac.runner.on("--verify --deep --strict", status: 3, out: "DmShell.app: invalid destination for symbolic link in bundle")
        let outcome = resign(.xcode)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.notes.map(\.key), ["resigner.note.strict"])
    }

    func testTheSignedAppHasAnotherApplicationIdentifier() {
        mac.runner.on("--entitlements - --xml", out: mac.plist(["application-identifier": "OTHER12345." + TestMac.bundleID]))
        XCTAssertEqual(resign(.xcode).failure?.message.key, "resigner.fail.appIdentifier")
    }

    // MARK: Install failures

    func testInstallRefusedForAnotherTeam() {
        mac.runner.on("devicectl device install app", status: 1,
                      out: "ERROR: MismatchedApplicationIdentifierEntitlement: Upgrade's application-identifier entitlement string does not match installed application's application-identifier string; rejecting upgrade.")
        let outcome = resign(.xcode)
        XCTAssertEqual(outcome.failure?.step, .installing)
        XCTAssertEqual(outcome.failure?.kind, .teamMismatch)
        XCTAssertEqual(commands(containing: "install app").count, 1, "nothing more is tried, the app on the device stays as it was")
    }

    func testInstallFailure() {
        mac.runner.on("devicectl device install app", status: 1, out: "ERROR: Failed to install the app on the device. (0xe8000067)")
        let outcome = resign(.xcode)
        XCTAssertEqual(outcome.failure?.kind, .install)
        XCTAssertEqual(outcome.failure?.message.key, "resigner.fail.install")
        XCTAssertEqual(outcome.failure?.detail, "ERROR: Failed to install the app on the device. (0xe8000067)")
    }

    func testInstallFailureCases() {
        let cases: [(String, String)] = [
            ("ERROR: A valid provisioning profile for this executable was not found. (0xe8008015)", "resigner.fail.installProfile"),
            ("ERROR: The device is locked", "resigner.fail.installLocked"),
            ("ERROR: Developer Mode is disabled", "resigner.device.developerModeOff"),
        ]
        for (output, key) in cases {
            let failure = FailureClassifier.install(output, deviceName: "iPad", team: TestMac.team)
            XCTAssertEqual(failure.message.key, key, output)
            Texts.check(failure.message); Texts.check(failure.remedy)
        }
    }

    func testTheAppIsNotListedAfterTheInstall() {
        mac.runner.on("devicectl device install app", action: { _ in self.mac.runner.on("devicectl device info apps", json: Fixture.data("apps-none.json")) })
        let outcome = resign(.xcode)
        XCTAssertEqual(outcome.failure?.step, .verifyingInstallation)
        XCTAssertEqual(outcome.failure?.message.key, "resigner.fail.notListed")
    }

    func testTheLogNeverHoldsAPrivateKeyOrPassword() {
        _ = resign(.profile)
        XCTAssertFalse(log.contains("BEGIN CERTIFICATE"))
        XCTAssertFalse(log.contains("PRIVATE KEY"))
    }
}

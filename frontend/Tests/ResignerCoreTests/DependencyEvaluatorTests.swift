import XCTest
@testable import NXCore
@testable import ResignerCore

final class DependencyEvaluatorTests: XCTestCase {
    var mac: TestMac!

    override func setUp() { mac = TestMac() }
    override func tearDown() { mac = nil }

    func rows(_ f: EnvironmentFacts) -> [DependencyItem] {
        let items = DependencyEvaluator.evaluate(f)
        Texts.check(items)
        return items
    }

    func row(_ id: String, _ f: EnvironmentFacts, file: StaticString = #filePath, line: UInt = #line) -> DependencyItem {
        guard let item = rows(f).first(where: { $0.id == id }) else { XCTFail("no row \(id)", file: file, line: line); fatalError() }
        return item
    }

    // MARK: The probe and a healthy Mac

    func testTheProbeReadsAHealthyMac() {
        let f = mac.facts()
        XCTAssertEqual(f.macOSVersion, "26.6")
        XCTAssertEqual(f.selectedDeveloperDir, mac.developerDir)
        XCTAssertEqual(f.activeXcode?.version, "27.2")
        XCTAssertEqual(f.activeXcode?.build, "17C52")
        XCTAssertEqual(f.xcodebuildVersion, "Xcode 27.2")
        XCTAssertEqual(f.licenseAccepted, true)
        XCTAssertEqual(f.firstLaunchDone, true)
        XCTAssertEqual(f.iosSDKVersion, "26.2")
        XCTAssertTrue(f.xcrunWorks && f.codesignPresent && f.securityPresent)
        XCTAssertNotNil(f.devicectlPath)
        XCTAssertEqual(f.device?.name, "Jane's iPad")
        XCTAssertEqual(f.installedApps?.map(\.bundle), ["com.apple.mobilesafari", TestMac.bundleID])
        XCTAssertEqual(f.certificates.first?.team, TestMac.team)
        XCTAssertEqual(f.signingCertificate?.sha1, TestMac.certificateSHA1)
        XCTAssertEqual(f.teams.map(\.id), [TestMac.team])
        XCTAssertEqual(f.profiles.map(\.uuid), [TestMac.profileUUID])
        XCTAssertEqual(f.embeddedProfile?.uuid, TestMac.profileUUID)
        XCTAssertEqual(f.appEntitlements[EntitlementPlanner.memoryLimit], .bool(true))
        XCTAssertEqual(f.resolvedRoute, .xcode)
        XCTAssertEqual(f.requiredEntitlements, [EntitlementPlanner.memoryLimit])
        XCTAssertEqual(f.deviceCopyTeam, TestMac.team)
    }

    func testAHealthyMacHasNoBlockerOnEitherRoute() {
        for route in [SigningRoute.xcode, .profile] {
            let items = rows(mac.facts(route: route))
            XCTAssertEqual(DependencyEvaluator.blockers(items).map(\.id), [], "\(route)")
            XCTAssertEqual(items.first { $0.id == "signing.test" }?.status, .notChecked, "the trial signature runs on request only")
        }
    }

    func testTheProbeOnlyReads() {
        _ = mac.facts()
        for command in mac.runner.commands {
            XCTAssertFalse(command.contains(" install") || command.contains("uninstall") || command.contains("--force") || command.contains("-s ")
                           || command.contains("-runFirstLaunch") || command.contains("accept"), command)
        }
    }

    // MARK: Xcode

    func testXcodeMissing() {
        var f = mac.facts()
        f.xcodes = []; f.selectedDeveloperDir = "/Library/Developer/CommandLineTools"; f.xcodebuildVersion = nil
        f.xcodebuildError = "xcode-select: error: tool 'xcodebuild' requires Xcode"; f.licenseAccepted = nil; f.firstLaunchDone = nil; f.iosSDKVersion = nil
        let app = row("xcode.app", f)
        XCTAssertEqual(app.status, .missing)
        XCTAssertTrue(app.stops)
        XCTAssertEqual(app.actions.map(\.action), [.openURL(XcodeLocator.appStoreURL), .openURL(XcodeLocator.downloadsURL)])
        XCTAssertEqual(row("xcode.xcodebuild", f).status, .missing)
        XCTAssertEqual(row("xcode.developerDir", f).status, .missing)
    }

    func testXcodeInstalledAndCurrent() {
        let f = mac.facts()
        XCTAssertEqual(row("xcode.app", f).status, .ok)
        XCTAssertEqual(row("xcode.app", f).version, "27.2 (17C52)")
        XCTAssertEqual(row("xcode.version", f).status, .ok)
    }

    func testAnOldXcodeIsOutdated() {
        var f = mac.facts()
        f.xcodes = [XcodeInstall(path: mac.xcode, version: "16.4", build: "16F6")]
        XCTAssertEqual(row("xcode.version", f).status, .outdated)
        XCTAssertTrue(row("xcode.version", f).stops)
    }

    func testTheCommandLineToolsSelectedWithXcodeInstalledIsAWrongDeveloperFolder() {
        var f = mac.facts()
        f.selectedDeveloperDir = "/Library/Developer/CommandLineTools"
        let dir = row("xcode.developerDir", f)
        XCTAssertEqual(dir.status, .misconfigured)
        XCTAssertTrue(dir.stops)
        guard case .runAdmin(let command)? = dir.actions.first?.action else { return XCTFail("the switch asks for an administrator") }
        XCTAssertEqual(command.first, "/usr/bin/osascript")
        XCTAssertTrue(command.last!.contains("with administrator privileges"))
        XCTAssertEqual(dir.actions.last?.action, .openSettings, "or use that Xcode for the Resigner only")
    }

    func testAnXcodeChosenForTheResignerIsUsedWithoutChangingTheSystem() {
        var f = mac.facts()
        f.selectedDeveloperDir = "/Library/Developer/CommandLineTools"
        f.chosenDeveloperDir = mac.developerDir
        XCTAssertEqual(row("xcode.developerDir", f).status, .ok)
        XCTAssertEqual(f.activeXcode?.path, mac.xcode)
        f.chosenDeveloperDir = "/Applications/Gone.app/Contents/Developer"
        XCTAssertEqual(row("xcode.developerDir", f).status, .misconfigured)
    }

    func testAnXcodePathThatIsNotSafeInAShellGetsNoAdminButton() {
        var f = mac.facts()
        f.selectedDeveloperDir = "/Library/Developer/CommandLineTools"
        f.xcodes = [XcodeInstall(path: "/Applications/Xcode'; rm -rf ~.app", version: "27.2")]
        XCTAssertFalse(row("xcode.developerDir", f).actions.contains { if case .runAdmin = $0.action { return true } else { return false } })
        XCTAssertNil(DependencyEvaluator.adminCommand(["/usr/bin/xcodebuild", "-license", "accept;reboot"]))
        XCTAssertNotNil(DependencyEvaluator.adminCommand(["/usr/bin/xcodebuild", "-license", "accept"]))
    }

    func testLicenseAndFirstLaunch() {
        var f = mac.facts()
        f.licenseAccepted = false; f.firstLaunchDone = false
        XCTAssertEqual(row("xcode.license", f).status, .needsAction)
        XCTAssertTrue(row("xcode.license", f).stops)
        XCTAssertEqual(row("xcode.firstLaunch", f).status, .needsAction)
    }

    func testTheIOSPlatformMattersOnlyToTheXcodeRoute() {
        var f = mac.facts(route: .xcode)
        f.iosSDKVersion = nil
        XCTAssertTrue(row("xcode.iosSDK", f).stops)
        XCTAssertEqual(row("xcode.iosSDK", f).actions.first?.action, .runTool(Toolchain.iosPlatformCmd))
        f.route = .profile
        XCTAssertFalse(row("xcode.iosSDK", f).stops)
    }

    // MARK: Command line tools

    func testMissingCommandLineTools() {
        var f = mac.facts()
        f.xcrunWorks = false; f.devicectlPath = nil; f.codesignPresent = false
        XCTAssertEqual(row("tools.xcrun", f).status, .missing)
        XCTAssertEqual(row("tools.xcrun", f).actions.first?.action, .runTool(["/usr/bin/xcode-select", "--install"]))
        XCTAssertEqual(row("tools.codesign", f).status, .missing)
        XCTAssertEqual(row("tools.devicectl", f).status, .missing)
        XCTAssertNil(rows(f).first { $0.id == "device.list" }, "no device listing without devicectl")
    }

    // MARK: Signing

    func testMissingSigningIdentity() {
        var f = mac.facts(route: .profile)
        f.certificates = []; f.identities = []
        XCTAssertEqual(row("signing.identity", f).status, .missing)
        XCTAssertTrue(row("signing.identity", f).stops)
        f.route = .xcode
        XCTAssertEqual(row("signing.identity", f).status, .notApplicable, "Xcode makes a certificate for a signed-in account")
        XCTAssertFalse(row("signing.identity", f).stops)
    }

    func testInvalidSigningIdentity() {
        mac.identity(valid: false)
        let f = mac.facts(route: .profile)
        let identity = row("signing.identity", f)
        XCTAssertEqual(identity.status, .misconfigured)
        XCTAssertEqual(identity.explanation.key, "resigner.dep.identity.revoked")
        XCTAssertTrue(identity.stops)
        let untrusted = DependencyEvaluator.invalidIdentity("x", "CSSMERR_TP_NOT_TRUSTED", blocking: true)
        XCTAssertEqual(untrusted.actions.first?.action, .openURL("https://www.apple.com/certificateauthority/"))
    }

    func testACertificateWithoutItsPrivateKey() {
        mac.runner.on("find-identity -p codesigning", out: "Policy: Code Signing\n  Matching identities\n     0 identities found\n")
        let f = mac.facts(route: .profile)
        XCTAssertEqual(row("signing.identity", f).explanation.key, "resigner.dep.identity.noKey")
        XCTAssertEqual(row("signing.identity", f).status, .misconfigured)
    }

    func testAnExpiredCertificate() {
        var f = mac.facts(route: .profile)
        f.certificates = [CertificateRecord(sha1: TestMac.certificateSHA1, commonName: "Apple Development: J (X)", team: TestMac.team,
                                            notAfter: mac.now.addingTimeInterval(-86400),
                                            identity: IdentityRecord(sha1: TestMac.certificateSHA1, name: "Apple Development: J (X)"))]
        f.selectedIdentity = TestMac.certificateSHA1
        XCTAssertEqual(row("signing.identity", f).status, .outdated)
    }

    func testTheTrialSignatureResult() {
        var f = mac.facts(route: .profile)
        f.testSign = .keyAccessDenied("errSecInternalComponent"); f.testSignedIdentity = TestMac.certificateSHA1
        XCTAssertEqual(row("signing.test", f).status, .misconfigured)
        XCTAssertTrue(row("signing.test", f).stops)
        f.testSign = .signed
        XCTAssertEqual(row("signing.test", f).status, .ok)
        f.testSignedIdentity = "OTHER"
        XCTAssertEqual(row("signing.test", f).status, .notChecked, "a result for another identity does not count")
    }

    func testNoTeamAndATeamWithoutAnXcodeAccount() {
        var f = mac.facts(route: .xcode)
        f.selectedTeam = ""
        XCTAssertEqual(row("signing.team", f).status, .needsAction)
        f.selectedTeam = TestMac.team; f.xcodeAccountTeams = []
        XCTAssertEqual(row("signing.team", f).explanation.key, "resigner.dep.team.noAccount")
        XCTAssertTrue(row("signing.team", f).stops)
        f.route = .profile
        XCTAssertEqual(row("signing.team", f).status, .ok, "the profile route needs no Xcode account")
    }

    func testAnotherTeamThanTheDevicesCopyStops() {
        var f = mac.facts()
        f.selectedTeam = "OTHER12345"
        let same = row("signing.sameTeam", f)
        XCTAssertEqual(same.status, .misconfigured)
        XCTAssertTrue(same.stops)
        XCTAssertEqual(same.explanation.args, [TestMac.team, "OTHER12345"])
    }

    // MARK: Provisioning

    func testMissingProvisioningProfile() {
        var f = mac.facts(route: .profile)
        f.profiles = []
        let profile = row("provisioning.profile", f)
        XCTAssertEqual(profile.status, .missing)
        XCTAssertTrue(profile.stops)
        XCTAssertEqual(profile.explanation.key, "resigner.dep.profile.none")
    }

    func testExpiredProvisioningProfile() {
        mac.installProfile(mac.profile(expires: mac.now.addingTimeInterval(-60)))
        let profile = row("provisioning.profile", mac.facts(route: .profile))
        XCTAssertEqual(profile.status, .missing, "no profile fits")
        XCTAssertEqual(profile.explanation.key, "resigner.profile.expired", "the closest profile says why")
    }

    func testAChosenProfileForAnotherDevice() {
        mac.installProfile(mac.profile(devices: ["00008000-0000000000000000"]))
        var f = mac.facts(route: .profile)
        f.selectedProfile = TestMac.profileUUID
        XCTAssertEqual(row("provisioning.profile", f).explanation.key, "resigner.profile.deviceMissing")
        XCTAssertEqual(row("provisioning.profile", f).status, .misconfigured)
    }

    func testTheMemoryLimitAProfileCannotGrant() {
        mac.installProfile(mac.profile(memory: false))
        var f = mac.facts(route: .profile)
        f.selectedProfile = TestMac.profileUUID
        let ent = row("provisioning.entitlements", f)
        XCTAssertEqual(ent.explanation.key, "resigner.dep.entitlements.memory")
        XCTAssertTrue(ent.stops)
        f.allowWithoutMemoryLimit = true
        XCTAssertEqual(row("provisioning.entitlements", f).status, .ok)
        XCTAssertEqual(row("provisioning.entitlements", f).explanation.key, "resigner.dep.entitlements.dropped")
    }

    func testTheXcodeRouteShowsTheProfileTheAppHasNow() {
        let p = row("provisioning.profile", mac.facts(route: .xcode))
        XCTAssertEqual(p.status, .ok)
        XCTAssertEqual(p.explanation.key, "resigner.dep.profile.xcodeCurrent")
    }

    // MARK: Device

    func testMissingDevice() {
        var f = mac.facts()
        f.devices = []; f.selectedDevice = ""; f.installedApps = nil
        let device = row("device.selected", f)
        XCTAssertEqual(device.status, .missing)
        XCTAssertTrue(device.stops)
        XCTAssertEqual(device.explanation.key, "resigner.dep.device.none")
    }

    func testAnUntrustedDevice() {
        var f = mac.facts()
        f.selectedDevice = "00008140-000A1B2C3D4E5F60"
        XCTAssertEqual(row("device.selected", f).explanation.key, "resigner.device.notPaired")
        XCTAssertTrue(row("device.selected", f).stops)
    }

    func testDeveloperModeOffAndAnOldSystem() {
        var f = mac.facts()
        f.selectedDevice = "00008110-000C1D2E3F405060"
        XCTAssertEqual(row("device.selected", f).explanation.key, "resigner.device.notConnected")
        f.devices = f.devices.map { var d = $0; if d.udid == f.selectedDevice { d.transport = "wired" }; return d }
        XCTAssertEqual(row("device.selected", f).explanation.key, "resigner.device.developerModeOff")
    }

    func testInstalledAppDecisions() {
        var f = mac.facts()
        XCTAssertEqual(row("device.installed", f).explanation.key, "resigner.dep.installed.upgrade")
        f.installedApps = InstalledApps.parse(Fixture.data("apps-none.json"))
        XCTAssertEqual(row("device.installed", f).status, .needsAction)
        XCTAssertTrue(row("device.installed", f).stops)
        f.allowFirstInstall = true
        XCTAssertFalse(row("device.installed", f).stops)
        f.installedApps = InstalledApps.parse(Fixture.data("apps-team-variant.json"))
        XCTAssertEqual(row("device.installed", f).status, .misconfigured)
        f.bundleID = "org.nxnative.shell.TEAM123456"
        XCTAssertEqual(row("device.installed", f).status, .ok)
    }

    // MARK: Project

    func testNoShellRoot() {
        let f = mac.probe.read(ProbeRequest(shellRoot: mac.base + "/nowhere", device: TestMac.udid, team: TestMac.team))
        XCTAssertEqual(row("project.root", f).status, .missing)
        XCTAssertTrue(DependencyEvaluator.blockers(rows(f)).contains { $0.id == "project.root" })
    }

    func testABrokenProjectStopsOnlyTheXcodeRoute() {
        try! FileManager.default.removeItem(atPath: mac.base + "/engine")
        let auto = mac.facts(route: .automatic)
        XCTAssertEqual(auto.resolvedRoute, .profile)
        XCTAssertFalse(row("project.xcode", auto).stops)
        let xcode = mac.facts(route: .xcode)
        XCTAssertEqual(row("project.xcode", xcode).status, .misconfigured)
        XCTAssertTrue(row("project.xcode", xcode).stops)
        XCTAssertEqual(row("project.xcode", xcode).explanation.key, "resigner.dep.project.links")
    }

    func testAnAppWithoutGames() {
        try! FileManager.default.removeItem(atPath: mac.appPath + "/Frameworks/DmGame\(TestMac.titleID).framework")
        XCTAssertEqual(row("project.app", mac.facts()).explanation.key, "resigner.dep.app.noGames")
    }
}

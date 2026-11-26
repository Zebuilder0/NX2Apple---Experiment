import XCTest
@testable import NXCore
@testable import ResignerCore

final class ShellInspectorTests: XCTestCase {
    func testAHealthyShellRoot() {
        let mac = TestMac()
        let shell = ShellInspector.inspect(root: mac.root)
        XCTAssertTrue(shell.rootExists)
        XCTAssertEqual(shell.library?.bundleID, TestMac.bundleID)
        XCTAssertEqual(shell.team, TestMac.team)
        XCTAssertEqual(shell.app?.bundleID, TestMac.bundleID)
        XCTAssertEqual(shell.app?.games, [EmbeddedGame(titleID: TestMac.titleID, name: "Test Game", framework: "DmGame\(TestMac.titleID).framework")])
        XCTAssertEqual(shell.app?.otherCode, ["libextra.dylib"])
        XCTAssertEqual(shell.app?.minimumOS, "26.0")
        XCTAssertTrue(shell.app?.hasEmbeddedProfile ?? false)
        XCTAssertTrue(shell.project.usable)
        XCTAssertTrue(shell.project.requestsEntitlements)
        XCTAssertTrue(shell.project.derivedDataExists)
    }

    func testAMissingRootAndAMissingApp() {
        let mac = TestMac()
        let nothing = ShellInspector.inspect(root: mac.base + "/nowhere")
        XCTAssertFalse(nothing.rootExists)
        XCTAssertNil(nothing.library)
        XCTAssertNil(nothing.app)
        XCTAssertEqual(nothing.bundleID, ShellLibrary.defaultBundleID)
        try! FileManager.default.removeItem(atPath: mac.appPath)
        XCTAssertNil(ShellInspector.inspect(root: mac.root).app)
    }

    func testAnEngineThatMovedBreaksTheProjectButNotTheApp() {
        let mac = TestMac()
        try! FileManager.default.removeItem(atPath: mac.base + "/engine")
        let shell = ShellInspector.inspect(root: mac.root)
        XCTAssertEqual(shell.project.brokenLinks, ["Sources", "Shell", "tools"])
        XCTAssertFalse(shell.project.usable)
        XCTAssertNotNil(shell.app, "the built app is still there for the profile route")
        XCTAssertEqual(SigningRoute.automatic.resolved(projectUsable: shell.project.usable), .profile)
        XCTAssertEqual(SigningRoute.automatic.resolved(projectUsable: true), .xcode)
    }

    func testAFrameworkTheProjectEmbedsIsGone() {
        let mac = TestMac()
        try! FileManager.default.removeItem(atPath: ShellInstall.mirroredFramework(root: mac.root, titleID: TestMac.titleID))
        XCTAssertEqual(ShellInspector.inspect(root: mac.root).project.missingFrameworks.count, 1)
    }

    func testAnIncompleteGameFrameworkIsNamed() {
        let mac = TestMac()
        try! FileManager.default.removeItem(atPath: mac.appPath + "/Frameworks/DmGame\(TestMac.titleID).framework/DmGame\(TestMac.titleID)")
        XCTAssertEqual(ShellInspector.inspect(root: mac.root).app?.games.first?.missingFile, "DmGame\(TestMac.titleID)")
    }

    func testAnotherConfigurationHasItsOwnProductsFolder() {
        XCTAssertTrue(ShellInspector.appPath(root: "/r", configuration: "Debug").hasSuffix("/Build/Products/Debug-iphoneos/DmShell.app"))
        XCTAssertEqual(ShellInspector.appPath(root: "/r", configuration: "Release"), ShellInstall.appPath(root: "/r"))
    }
}

final class DeviceInventoryTests: XCTestCase {
    func testTheOlderListing() {
        let devices = DeviceInventory.parse(Fixture.data("devices-xcode26.json"))
        XCTAssertEqual(devices.map(\.name), ["Guest iPhone", "Jane's iPad", "Old iPhone"], "connected ones first, the simulator left out")
        let ipad = devices.first { $0.udid == TestMac.udid }!
        XCTAssertEqual(ipad.model, "iPad Pro 13-inch (M4)")
        XCTAssertEqual(ipad.deviceType, "iPad")
        XCTAssertEqual(ipad.osVersion, "26.1")
        XCTAssertTrue(ipad.paired && ipad.wired)
        XCTAssertEqual(ipad.developerMode, true)
        XCTAssertEqual(DeviceReadiness.issues(ipad), [])
    }

    func testTheNewerListing() {
        let air = DeviceInventory.parse(Fixture.data("devices-xcode27.json")).first!
        XCTAssertEqual(air.name, "Air")
        XCTAssertEqual(air.osVersion, "26.2")
        XCTAssertEqual(air.transport, "localNetwork")
        XCTAssertEqual(air.developerMode, true)
        XCTAssertEqual(DeviceReadiness.issues(air), [.notPrepared])
        XCTAssertFalse(DeviceIssue.notPrepared.blocking)
    }

    func testAnUntrustedDisconnectedAndOldDevice() {
        let devices = DeviceInventory.parse(Fixture.data("devices-xcode26.json"))
        XCTAssertEqual(DeviceReadiness.issues(devices.first { $0.name == "Guest iPhone" }!), [.notPaired])
        XCTAssertEqual(DeviceReadiness.issues(devices.first { $0.name == "Old iPhone" }!),
                       [.notConnected, .developerModeOff, .osTooOld(found: "18.6", needed: "26.0")])
        [DeviceIssue.notConnected, .notPaired, .developerModeOff, .notPrepared, .osTooOld(found: "1", needed: "2")].forEach { Texts.check($0.text) }
    }

    func testUnreadableJSONIsNoDevices() {
        XCTAssertEqual(DeviceInventory.parse(Data("{".utf8)), [])
        XCTAssertEqual(DeviceInventory.parse(Data(#"{"result": {}}"#.utf8)), [])
    }

    func testTheInstallIsAnUpdateOnlyUnderTheSameBundleID() {
        let withShell = InstalledApps.parse(Fixture.data("apps-with-shell.json"))!
        XCTAssertEqual(InstallTargetCheck.decide(bundleID: TestMac.bundleID, apps: withShell), .upgrade(InstalledApp(bundle: TestMac.bundleID, name: "NX2Apple")))
        XCTAssertEqual(InstallTargetCheck.decide(bundleID: TestMac.bundleID, apps: InstalledApps.parse(Fixture.data("apps-none.json"))!), .firstInstall)
        let variant = InstalledApps.parse(Fixture.data("apps-team-variant.json"))!
        XCTAssertEqual(InstallTargetCheck.decide(bundleID: TestMac.bundleID, apps: variant),
                       .otherBundleOnly([InstalledApp(bundle: "org.nxnative.shell.TEAM123456", name: "NX2Apple")]))
        XCTAssertEqual(InstallTargetCheck.decide(bundleID: "org.nxnative.shell.TEAM123456", apps: variant),
                       .upgrade(InstalledApp(bundle: "org.nxnative.shell.TEAM123456", name: "NX2Apple")))
    }
}

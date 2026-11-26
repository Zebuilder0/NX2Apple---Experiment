import AppKit
import SwiftUI
import XCTest
@testable import NXCore
@testable import NXModel
@testable import NXLauncher
@testable import ResignerCore
@testable import ResignerModel
@testable import ResignerUI

/// A window outside every display, never key or main, for drawing pages in a test (as NX2AppleTests' OffscreenWindow).
final class HiddenWindow: NSWindow {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        setFrame(NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: frame.size), display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Facts made by hand: a shell root with one game, an iPad on a cable, a team, a certificate and one blocking row (no Xcode account).
func pageFacts() -> EnvironmentFacts {
    let library = ShellLibrary(bundleID: "org.nxnative.shell", team: "TEAM123456", games: [.init(titleID: "0100000000010000", name: "Test Game", framework: "/f")])
    let app = ShellApp(path: "/r/derived-data/Build/Products/Release-iphoneos/DmShell.app", bundleID: "org.nxnative.shell", displayName: "NX2Apple",
                       version: "1.0", games: [EmbeddedGame(titleID: "0100000000010000", name: "Test Game", framework: "DmGame0100000000010000.framework")],
                       hasEmbeddedProfile: true)
    var f = EnvironmentFacts(shell: ShellInspection(root: "/r", rootExists: true, library: library, app: app, appPath: app.path,
                                                    project: ShellProject(path: "/r/project/DmShell.xcodeproj", exists: true, derivedDataExists: true)))
    f.selectedDeveloperDir = "/Applications/Xcode.app/Contents/Developer"
    f.xcodes = [XcodeInstall(path: "/Applications/Xcode.app", version: "27.2", build: "17C52")]
    f.xcodebuildVersion = "Xcode 27.2"; f.licenseAccepted = true; f.firstLaunchDone = true; f.iosSDKVersion = "26.2"
    f.xcrunWorks = true; f.codesignPresent = true; f.securityPresent = true; f.devicectlPath = "/x/devicectl"; f.deviceListWorked = true
    f.devices = [DeviceStatus(udid: "00008112-001A2B3C4D5E6F70", name: "Jane's iPad", model: "iPad Pro", deviceType: "iPad", osVersion: "26.1",
                              transport: "wired", developerMode: true, ddiServicesAvailable: true)]
    f.selectedDevice = "00008112-001A2B3C4D5E6F70"
    f.installedApps = [InstalledApp(bundle: "org.nxnative.shell", name: "NX2Apple")]
    f.selectedTeam = "TEAM123456"
    f.teams = [SigningTeam(id: "TEAM123456", identity: "Apple Development: Jane Appleseed (ABCDE12345)", name: "Jane Appleseed")]
    f.certificates = [CertificateRecord(sha1: "0123456789ABCDEF0123456789ABCDEF01234567", commonName: "Apple Development: Jane Appleseed (ABCDE12345)",
                                        team: "TEAM123456", notAfter: Date().addingTimeInterval(86400 * 100),
                                        identity: IdentityRecord(sha1: "0123456789ABCDEF0123456789ABCDEF01234567", name: "Apple Development: Jane Appleseed (ABCDE12345)"))]
    f.embeddedProfile = ProvisioningProfile(uuid: "U", name: "iOS Team Provisioning Profile: org.nxnative.shell", teamID: "TEAM123456",
                                            applicationIdentifier: "TEAM123456.org.nxnative.shell", expires: Date().addingTimeInterval(86400 * 3))
    return f
}

@MainActor
final class ResignerPagesRenderTests: XCTestCase {
    override func setUp() async throws { NSApplication.shared.setActivationPolicy(.accessory) }

    /// Draws the view in a hidden window and returns the size it laid out to. A page that reads an environment object nobody set
    /// crashes here.
    @discardableResult
    func draw<V: View>(_ view: V, _ stores: ResignerStores, file: StaticString = #filePath, line: UInt = #line) -> NSSize {
        let size = NSSize(width: 1120, height: 900)
        let window = HiddenWindow(size: size)
        let host = NSHostingView(rootView: view.environmentObject(stores.loc).environmentObject(stores.padFocus).frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
        XCTAssertNotNil(bitmap, file: file, line: line)
        XCTAssertGreaterThan(host.fittingSize.width, 0, file: file, line: line)
        return host.fittingSize
    }

    func pages(_ stores: ResignerStores) {
        draw(DashboardPage(stores: stores, settings: stores.settings, environment: stores.environment, resign: stores.resign, open: { _ in }), stores)
        draw(DiagnosticsPage(stores: stores, environment: stores.environment, resign: stores.resign, open: { _ in }), stores)
        draw(SettingsPage(stores: stores, settings: stores.settings, environment: stores.environment, resign: stores.resign), stores)
    }

    func testEveryPageDrawsInEveryState() async throws {
        var answer: (ResignRequest, PipelineHooks) -> ResignOutcome = { _, hooks in
            hooks.step(.signing, .failed, LocalText("resigner.fail.memoryCapability", "TEAM123456"))
            var o = ResignOutcome()
            o.failure = ResignFailure(step: .signing, kind: .memoryCapability, message: LocalText("resigner.fail.memoryCapability", "TEAM123456"),
                                      detail: "error: the profile doesn't include the entitlement", remedy: LocalText("resigner.fail.memoryCapabilityFix"))
            return o
        }
        let stores = ResignerStores(defaults: TestDefaults.make("resigner-ui"), launcher: nil, read: { _ in pageFacts() },
                                    perform: { request, hooks in answer(request, hooks) })
        pages(stores)   // before the first check: no facts yet
        await stores.environment.check().value
        XCTAssertFalse(stores.environment.items.isEmpty)
        XCTAssertFalse(stores.environment.blockers.isEmpty, "the made-up Mac has no Xcode account for the team")
        pages(stores)
        try await XCTUnwrap(stores.resign.start()).value
        XCTAssertEqual(stores.resign.outcome?.failure?.kind, .memoryCapability)
        pages(stores)   // the failure card with its question
        answer = { _, hooks in
            for step in ResignStep.allCases { hooks.step(step, .done, nil) }
            var o = ResignOutcome()
            o.ok = true; o.deviceName = "Jane's iPad"; o.firstInstall = true; o.droppedEntitlements = [EntitlementPlanner.memoryLimit]
            o.notes = [LocalText("resigner.note.strict", "invalid destination for symbolic link")]; o.profileExpiry = Date().addingTimeInterval(7 * 86400)
            return o
        }
        try await XCTUnwrap(stores.resign.retryWithoutMemoryLimit()).value
        XCTAssertEqual(stores.resign.outcome?.ok, true)
        pages(stores)   // renewed, with its notes
        draw(ResignerRoot(stores: stores), stores)
    }

    func testEveryLanguageDraws() async throws {
        let stores = ResignerStores(defaults: TestDefaults.make("resigner-ui-lang"), launcher: nil, read: { _ in pageFacts() },
                                    perform: { _, _ in ResignOutcome() })
        await stores.environment.check().value
        for code in ["en", "zh", "de", "fr", "it", "ja", "sv"] {
            let lang = try XCTUnwrap(Lang.find(code), "no \(code).json")
            stores.loc.lang = lang
            pages(stores)
        }
    }
}

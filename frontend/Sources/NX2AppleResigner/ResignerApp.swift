import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher
import ResignerCore
import ResignerModel

/// NX2Apple Resigner: renews the signature of the NX2Apple shell the launcher built and installs it over the copy on an iPhone or
/// iPad (frontend/resigner/README.md). It shares the launcher's code and look and is a separate app.
@main
struct NX2AppleResignerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: ResignerAppDelegate
    @StateObject private var stores = ResignerStores()

    var body: some Scene {
        WindowGroup("NX2Apple Resigner") {
            ResignerRoot(stores: stores)
                .environmentObject(stores.loc)
                .environmentObject(stores.padFocus)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 860)
    }
}

/// `swift run` starts a bare executable that macOS does not treat as a regular app (no Dock icon, a window behind the terminal).
/// Inside the .app bundle this changes nothing.
final class ResignerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The wiring and nothing else, as the launcher's `LauncherStores`: it creates the stores and connects them.
@MainActor
final class ResignerStores: ObservableObject {
    let loc: Localizer
    let settings: ResignerSettings
    let log: ResignLog
    let environment: EnvironmentStore
    let resign: ResignStore
    let padFocus = PadFocus()

    init(defaults: UserDefaults = .standard) {
        loc = Localizer()
        settings = ResignerSettings(defaults: defaults)
        log = ResignLog()
        environment = EnvironmentStore(settings: settings)
        resign = ResignStore(settings: settings, environment: environment, log: log, defaults: defaults)
        let log = log
        environment.log = { line in onMainQueue { log.append(line) } }
    }
}

func onMainQueue(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// The app's version and the source it was built from, from the bundle (build_resigner.sh writes both). `swift run` has neither.
enum ResignerVersion {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var commit: String { Bundle.main.object(forInfoDictionaryKey: "NXResignerCommit") as? String ?? "" }
    static var label: String { commit.isEmpty ? current : current + " (" + commit + ")" }
}

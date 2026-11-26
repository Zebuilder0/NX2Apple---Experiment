import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import ResignerCore
import ResignerModel

/// The choices that stay off the dashboard: the route, the identity and profile, the Xcode, the configuration, the folder, the log.
struct SettingsPage: View {
    let stores: ResignerStores
    @ObservedObject var settings: ResignerSettings
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var resign: ResignStore
    @EnvironmentObject var loc: Localizer
    @State private var importing: URL?
    @State private var password = ""
    @State private var importNote: String?

    private var facts: EnvironmentFacts? { environment.facts }

    var body: some View {
        LauncherPageScroll {
            CardPageHeading(loc.t("resigner.ui.settings.title"), note: loc.t("resigner.ui.settings.note"))
            signingGroup
            deviceGroup
            xcodeGroup
            folderGroup
            diagnosticsGroup
            aboutGroup
        }
        .disabled(resign.running)
        .sheet(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil; password = "" } })) { importSheet }
    }

    // MARK: Signing

    private var signingGroup: some View {
        CardGroup(loc.t("resigner.ui.settings.signing"), footnote: importNote ?? "") {
            CardRow(loc.t("resigner.ui.settings.route"), detail: routeNote) {
                LauncherSegmented(options: routeOptions, selection: settings.route.rawValue) { settings.route = SigningRoute(rawValue: $0) ?? .automatic }
                .frame(width: 300)
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.signing.team"), detail: loc.t("resigner.ui.settings.teamNote")) {
                LauncherDropdown(options: teamOptions, selection: settings.team, label: loc.t("resigner.ui.signing.team")) { settings.team = $0 }
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.signing.certificate"), detail: loc.t("resigner.ui.settings.certificateNote")) {
                LauncherDropdown(options: certificateOptions, selection: settings.identity, label: loc.t("resigner.ui.signing.certificate")) { settings.identity = $0 }
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.signing.profile"), detail: loc.t("resigner.ui.settings.profileNote")) {
                LauncherDropdown(options: profileOptions, selection: settings.profile, label: loc.t("resigner.ui.signing.profile")) { settings.profile = $0 }
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.settings.p12"), detail: loc.t("resigner.ui.settings.p12Note")) {
                Button(loc.t("resigner.ui.settings.p12Choose")) { chooseP12() }
            }
        }
    }

    private var routeOptions: [(value: String, label: String)] {
        SigningRoute.allCases.map { route -> (value: String, label: String) in (value: route.rawValue, label: route.title(loc)) }
    }

    private var configurationOptions: [(value: String, label: String)] {
        ResignerSettings.configurations.map { name -> (value: String, label: String) in (value: name, label: name) }
    }

    private var routeNote: String {
        switch settings.route {
        case .automatic:
            let resolved = facts?.resolvedRoute ?? .xcode
            return String(format: loc.t("resigner.ui.settings.routeAutomatic"), resolved.title(loc))
        case .xcode: return loc.t("resigner.ui.settings.routeXcode")
        case .profile: return loc.t("resigner.ui.settings.routeProfile")
        }
    }

    private var teamOptions: [(value: String, label: String)] {
        var options = (facts?.teams ?? []).map { (value: $0.id, label: $0.label(personalTeam: loc.t("resigner.ui.settings.personalTeam"))) }
        if !settings.team.isEmpty, !options.contains(where: { $0.value == settings.team }) { options.insert((settings.team, settings.team), at: 0) }
        if options.isEmpty { options = [(value: "", label: loc.t("resigner.ui.settings.noTeam"))] }
        return options
    }

    private var certificateOptions: [(value: String, label: String)] {
        let certificates = (facts?.certificates ?? []).filter { settings.team.isEmpty || $0.team == settings.team }
        return [(value: "", label: loc.t("resigner.ui.settings.newestCertificate"))] + certificates.map { c in
            var label = c.commonName
            if let until = c.notAfter { label += " · " + until.shownDay }
            if !c.hasPrivateKey { label += " · " + loc.t("resigner.ui.settings.noKey") }
            return (value: c.sha1, label: label)
        }
    }

    private var profileOptions: [(value: String, label: String)] {
        let bundle = facts?.targetBundleID ?? ""
        let profiles = (facts?.profiles ?? []).filter { bundle.isEmpty || $0.allows(bundleID: bundle) }
        return [(value: "", label: loc.t("resigner.ui.settings.bestProfile"))] + profiles.map { p in
            (value: p.uuid, label: p.name + (p.expires.map { " · " + $0.shownDay } ?? ""))
        }
    }

    private func chooseP12() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p12"), UTType(filenameExtension: "pfx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = loc.t("resigner.ui.settings.p12Note")
        if panel.runModal() == .OK, let url = panel.url { importing = url }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("resigner.ui.p12.title")).font(.manrope(18, .bold))
            Text(String(format: loc.t("resigner.ui.p12.note"), importing?.lastPathComponent ?? "")).font(.manrope(13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(loc.t("resigner.ui.p12.password"), text: $password).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button(loc.t("resigner.ui.cancel")) { importing = nil; password = "" }.keyboardShortcut(.cancelAction)
                Button(loc.t("resigner.ui.p12.import")) { runImport() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(LauncherPalette.surface)
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    private func runImport() {
        guard let url = importing else { return }
        let secret = password
        password = ""   // the field is emptied at once: the password lives only for the import call
        importing = nil
        switch P12Import.run(file: url, password: secret) {
        case .imported(let count): importNote = String(format: loc.t("resigner.ui.p12.done"), String(count))
        case .wrongPassword: importNote = loc.t("resigner.ui.p12.wrongPassword")
        case .noIdentity: importNote = loc.t("resigner.ui.p12.noIdentity")
        case .failed(let why): importNote = String(format: loc.t("resigner.ui.p12.failed"), why)
        }
        stores.log.append("p12: import of \(url.lastPathComponent) finished\n")
        environment.check()
    }

    // MARK: Device and app

    private var deviceGroup: some View {
        CardGroup(loc.t("resigner.ui.settings.deviceApp")) {
            CardRow(loc.t("resigner.ui.device.name"), detail: loc.t("resigner.ui.settings.deviceNote")) {
                LauncherDropdown(options: deviceOptions, selection: settings.device, label: loc.t("resigner.ui.device.name")) { settings.device = $0 }
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.settings.bundle"), detail: loc.t("resigner.ui.settings.bundleNote"), detail2: facts?.targetBundleID ?? "") {
                LauncherDropdown(options: bundleOptions, selection: settings.bundleID, label: loc.t("resigner.ui.settings.bundle")) { settings.bundleID = $0 }
            }
        }
    }

    private var deviceOptions: [(value: String, label: String)] {
        var options = (facts?.devices ?? []).map { d in (value: d.udid, label: d.name + (d.connected ? "" : " · " + loc.t("resigner.ui.device.notConnected"))) }
        if options.isEmpty { options = [(value: settings.device, label: loc.t("resigner.ui.device.noneShort"))] }
        return options
    }

    private var bundleOptions: [(value: String, label: String)] {
        let shell = facts?.shell.bundleID ?? ShellLibrary.defaultBundleID
        var options: [(value: String, label: String)] = [(value: "", label: String(format: loc.t("resigner.ui.settings.bundleShell"), shell))]
        for app in ShellInstall.shellApps(in: facts?.installedApps ?? []) where app.bundle != shell {
            options.append((value: app.bundle, label: String(format: loc.t("resigner.ui.settings.bundleDevice"), app.bundle)))
        }
        if !settings.bundleID.isEmpty, !options.contains(where: { $0.value == settings.bundleID }) { options.append((settings.bundleID, settings.bundleID)) }
        return options
    }

    // MARK: Xcode

    private var xcodeGroup: some View {
        CardGroup(loc.t("resigner.ui.settings.xcode")) {
            CardRow(loc.t("resigner.ui.settings.xcodeChoice"), detail: loc.t("resigner.ui.settings.xcodeNote"), detail2: facts?.activeDeveloperDir ?? "") {
                LauncherDropdown(options: xcodeOptions, selection: settings.developerDir, label: loc.t("resigner.ui.settings.xcodeChoice")) { settings.developerDir = $0 }
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.settings.configuration"), detail: loc.t("resigner.ui.settings.configurationNote")) {
                LauncherSegmented(options: configurationOptions, selection: settings.configuration) { settings.configuration = $0 }
                .frame(width: 184)
            }
        }
    }

    private var xcodeOptions: [(value: String, label: String)] {
        [(value: "", label: loc.t("resigner.ui.settings.xcodeSelected"))] + (facts?.xcodes ?? []).map { x in
            (value: x.developerDir, label: "Xcode " + x.label + " · " + (x.path as NSString).lastPathComponent)
        }
    }

    // MARK: Folder, diagnostics, about

    private var folderGroup: some View {
        CardGroup(loc.t("resigner.ui.settings.folder"), footnote: loc.t("resigner.ui.settings.folderNote")) {
            CardRow(loc.t("resigner.dep.root.name"), detail: (settings.shellRoot as NSString).abbreviatingWithTildeInPath) {
                HStack(spacing: 8) {
                    Button(loc.t("resigner.ui.settings.choose")) { chooseFolder() }
                    Button(loc.t("resigner.action.reveal")) { revealInFinder(settings.shellRoot) }
                        .disabled(!FileManager.default.fileExists(atPath: settings.shellRoot))
                }
            }
            if settings.shellRoot != settings.launcherShellRoot {
                CardDivider()
                CardRow(loc.t("resigner.ui.settings.launcherFolder"), detail: (settings.launcherShellRoot as NSString).abbreviatingWithTildeInPath) {
                    Button(loc.t("resigner.ui.settings.useLauncherFolder")) { settings.useLauncherShellRoot() }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: settings.shellRoot)
        panel.message = loc.t("resigner.ui.settings.folderNote")
        if panel.runModal() == .OK, let url = panel.url { settings.shellRoot = url.path }
    }

    private var diagnosticsGroup: some View {
        CardGroup(loc.t("resigner.ui.settings.diagnostics")) {
            CardRow(loc.t("resigner.ui.settings.verbose"), detail: loc.t("resigner.ui.settings.verboseNote")) {
                Toggle("", isOn: $settings.verboseLog).toggleStyle(LauncherSwitchStyle()).labelsHidden()
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.export"), detail: loc.t("resigner.ui.exportNote")) {
                Button(loc.t("resigner.ui.exportShort")) { exportDiagnostics(resign: resign, loc: loc) }
            }
        }
    }

    private var aboutGroup: some View {
        CardGroup(loc.t("resigner.ui.settings.about")) {
            CardRow(loc.t("resigner.ui.settings.version"), detail: ResignerVersion.label) { EmptyView() }
            CardDivider()
            CardRow(loc.t("resigner.ui.settings.updates"), detail: loc.t("resigner.ui.settings.updatesNote")) { EmptyView() }
        }
    }
}

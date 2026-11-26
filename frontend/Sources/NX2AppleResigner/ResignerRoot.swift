import SwiftUI
import AppKit
import Combine
import NXCore
import NXModel
import NXLauncher
import ResignerCore
import ResignerModel

enum ResignerPage: String, CaseIterable {
    case dashboard, diagnostics, settings

    var symbol: String {
        switch self {
        case .dashboard: return "signature"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }

    func title(_ loc: Localizer) -> String {
        switch self {
        case .dashboard: return loc.t("resigner.ui.nav.dashboard")
        case .diagnostics: return loc.t("resigner.ui.nav.diagnostics")
        case .settings: return loc.t("resigner.ui.nav.settings")
        }
    }
}

/// The window: the launcher's dark background and chrome, a top bar with the name and the pages, and the page.
struct ResignerRoot: View {
    let stores: ResignerStores
    @EnvironmentObject var loc: Localizer
    @State private var page: ResignerPage = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.25)
            Group {
                switch page {
                case .dashboard: DashboardPage(stores: stores, settings: stores.settings, environment: stores.environment,
                                               resign: stores.resign, open: { page = $0 })
                case .diagnostics: DiagnosticsPage(stores: stores, environment: stores.environment, resign: stores.resign, open: { page = $0 })
                case .settings: SettingsPage(stores: stores, settings: stores.settings, environment: stores.environment, resign: stores.resign)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LauncherPalette.background.ignoresSafeArea())
        .background(LauncherWindowChrome())
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .frame(minWidth: 860, minHeight: 640)
        .onAppear { stores.environment.check() }
        // A choice in Settings changes what the check reads
        .onReceive(stores.settings.objectWillChange.debounce(for: .milliseconds(600), scheduler: RunLoop.main)) { _ in
            if !stores.resign.running { stores.environment.check() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: -2) {
                HStack(spacing: 7) {
                    Text("NX2Apple").font(.manrope(27, .bold)).tracking(-0.8)
                    Text("Resigner").font(.manrope(27, .bold)).tracking(-0.8).foregroundStyle(LauncherPalette.cream)
                }
                Text(String(format: loc.t("resigner.ui.byline"), ResignerVersion.current)).font(.manrope(10.5, .medium))
                    .foregroundStyle(LauncherPalette.unbuilt).tracking(0.2)
            }
            .fixedSize()
            HStack(spacing: 6) {
                ForEach(ResignerPage.allCases, id: \.self) { destination in
                    Button { page = destination } label: {
                        ZStack {
                            Label(destination.title(loc), systemImage: destination.symbol).font(.manrope(15, .bold)).hidden()
                            Label(destination.title(loc), systemImage: destination.symbol).font(.manrope(15, page == destination ? .bold : .medium))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(page == destination ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == destination ? .isSelected : [])
                }
            }
            .fixedSize()
            .padding(.leading, 30)
            Spacer(minLength: 8)
            RunIndicator(resign: stores.resign, environment: stores.environment)
        }
        .padding(.leading, 90).padding(.trailing, 24)
        .frame(height: 64)
        .background(TitlebarDoubleClick())
    }
}

/// The top bar's state: a check or a re-sign running.
struct RunIndicator: View {
    @ObservedObject var resign: ResignStore
    @ObservedObject var environment: EnvironmentStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if resign.running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(resign.current.map { $0.title.resolve(loc.t) } ?? loc.t("resigner.ui.running")).font(.manrope(13, .semibold))
            }
            .foregroundStyle(LauncherPalette.building)
        } else if environment.checking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loc.t("resigner.ui.checking")).font(.manrope(13, .semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Shared pieces

extension DependencyStatus {
    var color: Color {
        switch self {
        case .ok: return LauncherPalette.ready
        case .misconfigured, .missing, .outdated: return LauncherPalette.danger
        case .needsAction: return LauncherPalette.building
        case .notChecked, .notApplicable: return LauncherPalette.unbuilt
        }
    }

    func label(_ loc: Localizer) -> String {
        switch self {
        case .ok: return loc.t("resigner.status.ok")
        case .misconfigured: return loc.t("resigner.status.misconfigured")
        case .missing: return loc.t("resigner.status.missing")
        case .outdated: return loc.t("resigner.status.outdated")
        case .needsAction: return loc.t("resigner.status.needsAction")
        case .notChecked: return loc.t("resigner.status.notChecked")
        case .notApplicable: return loc.t("resigner.status.notApplicable")
        }
    }
}

extension DependencyCategory {
    func title(_ loc: Localizer) -> String {
        switch self {
        case .xcode: return loc.t("resigner.category.xcode")
        case .tools: return loc.t("resigner.category.tools")
        case .signing: return loc.t("resigner.category.signing")
        case .provisioning: return loc.t("resigner.category.provisioning")
        case .device: return loc.t("resigner.category.device")
        case .project: return loc.t("resigner.category.project")
        }
    }
}

extension SigningRoute {
    func title(_ loc: Localizer) -> String {
        switch self {
        case .automatic: return loc.t("resigner.route.automatic")
        case .xcode: return loc.t("resigner.route.xcode")
        case .profile: return loc.t("resigner.route.profile")
        }
    }
}

/// A small coloured capsule with the status's word.
struct StatusChip: View {
    let status: DependencyStatus
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Text(status.label(loc)).font(.manrope(11.5, .bold)).foregroundStyle(status.color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(status.color.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}

/// What a row's button does, for the actions the app itself carries out (links, Finder, pages). Tools go through the store.
@MainActor
func perform(_ action: RemediationAction, row: String, environment: EnvironmentStore, open: (ResignerPage) -> Void) {
    switch action {
    case .openURL(let link): if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    case .openApp(let path): NSWorkspace.shared.open(URL(fileURLWithPath: path))
    case .reveal(let path): revealInFinder(path)
    case .openSettings: open(.settings)
    case .recheck: environment.check()
    case .testSign: environment.testSign()
    case .runTool, .runAdmin: environment.fix(action, row: row)
    }
}

extension Date {
    /// The date in the user's own format, for the interface (the logs keep ISO dates).
    var shownDay: String { DateFormatter.localizedString(from: self, dateStyle: .medium, timeStyle: .none) }
    var shownMoment: String { DateFormatter.localizedString(from: self, dateStyle: .medium, timeStyle: .short) }
}

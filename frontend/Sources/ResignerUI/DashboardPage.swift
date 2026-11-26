import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import ResignerCore
import ResignerModel

/// The main page: what is ready, the one action, its steps, and the device, signing and dependency summaries.
struct DashboardPage: View {
    let stores: ResignerStores
    @ObservedObject var settings: ResignerSettings
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var resign: ResignStore
    let open: (ResignerPage) -> Void
    @EnvironmentObject var loc: Localizer
    @State private var logOpen = false

    var body: some View {
        LauncherPageScroll {
            CardPageHeading(loc.t("resigner.ui.dashboard.title"), note: loc.t("resigner.ui.dashboard.note"))
            HeroCard(settings: settings, environment: environment, resign: resign, open: open)
            if resign.running || resign.outcome != nil { StepsCard(resign: resign) }
            if !resign.running, let failure = resign.outcome?.failure, failure.kind != .cancelled {
                FailureCard(failure: failure, resign: resign, open: open)
            }
            DeviceCard(settings: settings, environment: environment)
            SigningCard(environment: environment, resign: resign)
            DependenciesSummaryCard(environment: environment, open: open)
            ResignLogCard(log: stores.log, resign: resign, isOpen: $logOpen)
        }
    }
}

/// The status, the primary button and the progress.
struct HeroCard: View {
    @ObservedObject var settings: ResignerSettings
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var resign: ResignStore
    let open: (ResignerPage) -> Void
    @EnvironmentObject var loc: Localizer

    private var blockers: [DependencyItem] { environment.blockers }

    private var headline: String {
        if resign.running { return resign.current.map { $0.title.resolve(loc.t) } ?? loc.t("resigner.ui.running") }
        if let outcome = resign.outcome {
            if outcome.ok { return loc.t("resigner.ui.hero.renewed") }
            if outcome.failure?.kind == .cancelled { return loc.t("resigner.ui.hero.stopped") }
            return loc.t("resigner.ui.hero.failed")
        }
        if environment.facts == nil { return loc.t("resigner.ui.checking") }
        return blockers.isEmpty ? loc.t("resigner.ui.hero.ready") : String(format: loc.t("resigner.ui.hero.blocked"), String(blockers.count))
    }

    private var subline: String {
        if let outcome = resign.outcome, outcome.ok {
            let until = outcome.profileExpiry.map { String(format: loc.t("resigner.ui.hero.until"), $0.shownDay) } ?? ""
            return [String(format: loc.t("resigner.ui.hero.renewedOn"), outcome.deviceName), until].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        guard let facts = environment.facts else { return "" }
        var parts: [String] = []
        if let device = facts.device { parts.append(device.name) }
        if let expiry = facts.embeddedProfile?.expires {
            parts.append(AppSignature.describe(expiry, loc.t))   // the launcher's own words for the expiry, in every language
        }
        return parts.joined(separator: " · ")
    }

    private var canStart: Bool { resign.canStart && environment.facts != nil && blockers.isEmpty && !environment.checking }

    // The body is cut into small pieces: as one expression it is more than the type checker takes in reasonable time.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 24) {
                status
                Spacer(minLength: 12)
                action
            }
            if resign.running { LauncherProgressBar(value: resign.progress, height: 8) }
            if !resign.running, resign.outcome?.ok != true, !blockers.isEmpty { blockerList }
            if let outcome = resign.outcome, outcome.ok { notes(outcome) }
        }
        .padding(24)
        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.06)))
    }

    private var routeLine: String {
        let route: SigningRoute = environment.facts?.resolvedRoute ?? settings.route
        return String(format: loc.t("resigner.ui.hero.route"), route.title(loc))
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 10, height: 10)
                Text(headline).font(.manrope(26, .bold)).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
            }
            if !subline.isEmpty { Text(subline).font(.manrope(14)).foregroundStyle(.secondary) }
            Text(routeLine).font(.manrope(12.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        if resign.running { stopButton } else { resignButton }
    }

    private var stopButton: some View {
        let help: String = resign.canStop ? loc.t("resigner.ui.stopHelp") : loc.t("resigner.ui.stopInstalling")
        return Button { resign.stop() } label: { Label(loc.t("resigner.ui.stop"), systemImage: "stop.fill") }
            .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.danger))
            .disabled(!resign.canStop)
            .help(help)
    }

    private var resignButton: some View {
        let ready: Bool = canStart
        let title: String = loc.t("resigner.ui.resign")
        let help: String = ready ? loc.t("resigner.ui.resignHelp") : loc.t("resigner.ui.resignBlocked")
        return Button { resign.start() } label: { LauncherHeroActionLabel(title: title, symbol: "signature") }
            .buttonStyle(.plain)
            .disabled(!ready)
            .opacity(ready ? 1 : 0.45)
            .keyboardShortcut(.return, modifiers: .command)
            .help(help)
            .accessibilityLabel(title)
    }

    private var blockerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blockers.prefix(3))) { item in BlockerLine(item: item) }
            Button(loc.t("resigner.ui.openDiagnostics")) { open(.diagnostics) }.buttonStyle(LauncherSecondaryButtonStyle())
        }
    }

    private func notes(_ outcome: ResignOutcome) -> some View {
        let lines: [String] = (outcome.notes + droppedNotes(outcome)).map { $0.resolve(loc.t) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "info.circle").font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if outcome.firstInstall {
                Label(loc.t("resigner.ui.trustDeveloper"), systemImage: "hand.raised").font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func droppedNotes(_ outcome: ResignOutcome) -> [LocalText] {
        outcome.droppedEntitlements.map { LocalText("resigner.dep.entitlements.dropped", $0) }
    }

    private var dotColor: Color {
        if resign.running { return LauncherPalette.building }
        if let outcome = resign.outcome { return outcome.ok ? LauncherPalette.ready : LauncherPalette.danger }
        return blockers.isEmpty && environment.facts != nil ? LauncherPalette.ready : LauncherPalette.building
    }
}

/// One thing that stops a re-sign, under the hero's status.
struct BlockerLine: View {
    let item: DependencyItem
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let text: String = item.name.resolve(loc.t) + ": " + item.explanation.resolve(loc.t)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(item.status.color).font(.system(size: 12))
            Text(text).font(.manrope(13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The nine steps of the run, as the launcher's progress card shows a build's stages.
struct StepsCard: View {
    @ObservedObject var resign: ResignStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        CardGroup(loc.t("resigner.ui.steps")) {
            ForEach(Array(resign.steps.enumerated()), id: \.element.id) { index, row in
                if index > 0 { CardDivider() }
                HStack(spacing: 12) {
                    if row.state == .running { ProgressView().controlSize(.small).frame(width: 14) }
                    else { Circle().fill(row.state.color).frame(width: 7, height: 7).frame(width: 14) }
                    Text(row.step.title.resolve(loc.t)).font(.manrope(14)).foregroundStyle(row.state == .pending ? .secondary : .primary)
                    Spacer(minLength: 12)
                    if let detail = row.detail, row.state == .failed {
                        Text(detail.resolve(loc.t)).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 11)
            }
        }
    }
}

/// Why the run stopped, what to do, and the answers it may ask for.
struct FailureCard: View {
    let failure: ResignFailure
    @ObservedObject var resign: ResignStore
    let open: (ResignerPage) -> Void
    @EnvironmentObject var loc: Localizer

    var body: some View {
        CardGroup(loc.t("resigner.ui.failure.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: loc.t("resigner.ui.failure.at"), failure.step.title.resolve(loc.t))).font(.manrope(12.5, .semibold))
                    .foregroundStyle(LauncherPalette.danger)
                Text(failure.message.resolve(loc.t)).font(.manrope(15, .semibold)).fixedSize(horizontal: false, vertical: true)
                if let remedy = failure.remedy {
                    Text(remedy.resolve(loc.t)).font(.manrope(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !failure.detail.isEmpty {
                    Text(failure.detail).font(.mono(11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if failure.kind == .memoryCapability {
                        Button(loc.t("resigner.ui.withoutMemoryLimit")) { resign.retryWithoutMemoryLimit() }
                            .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.building))
                            .help(loc.t("resigner.ui.withoutMemoryLimitHelp"))
                    }
                    if failure.kind == .firstInstall {
                        Button(loc.t("resigner.ui.firstInstall")) { resign.confirmFirstInstall() }
                            .buttonStyle(LauncherSecondaryButtonStyle(accent: LauncherPalette.building))
                            .help(loc.t("resigner.ui.firstInstallHelp"))
                    }
                    Button(loc.t("resigner.ui.openDiagnostics")) { open(.diagnostics) }.buttonStyle(LauncherSecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The device the renewed app goes to.
struct DeviceCard: View {
    @ObservedObject var settings: ResignerSettings
    @ObservedObject var environment: EnvironmentStore
    @EnvironmentObject var loc: Localizer

    private var device: DeviceStatus? { environment.facts?.device }

    var body: some View {
        CardGroup(loc.t("resigner.ui.device.title")) {
            CardRow(loc.t("resigner.ui.device.name"), detail: summary, dot: device == nil ? LauncherPalette.danger : LauncherPalette.ready) {
                LauncherDropdown(options: options, selection: settings.device, label: loc.t("resigner.ui.device.name")) { settings.device = $0 }
                    .disabled((environment.facts?.devices ?? []).isEmpty)
            }
            if let device { DeviceDetailRows(device: device, installed: environment.items.first { $0.id == "device.installed" }) }
        }
    }

    private var summary: String {
        guard let device else { return loc.t("resigner.dep.device.none") }
        return [device.model, device.deviceType].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var options: [(value: String, label: String)] {
        let devices: [DeviceStatus] = environment.facts?.devices ?? []
        if devices.isEmpty { return [(value: settings.device, label: loc.t("resigner.ui.device.noneShort"))] }
        return devices.map { (value: $0.udid, label: $0.name) }
    }
}

/// The rows of a found device: system, connection, trust, Developer Mode and NX2Apple on it.
struct DeviceDetailRows: View {
    let device: DeviceStatus
    let installed: DependencyItem?
    @EnvironmentObject var loc: Localizer

    private func good(_ ok: Bool) -> Color { ok ? LauncherPalette.ready : LauncherPalette.danger }

    private var connection: String {
        if device.wired { return loc.t("resigner.ui.device.cable") }
        if device.connected { return loc.t("resigner.ui.device.network") }
        return loc.t("resigner.ui.device.notConnected")
    }

    private var developerMode: (text: String, dot: Color) {
        switch device.developerMode {
        case true?: return (loc.t("resigner.ui.device.on"), LauncherPalette.ready)
        case false?: return (loc.t("resigner.ui.device.off"), LauncherPalette.danger)
        case nil: return (loc.t("resigner.ui.device.unknown"), LauncherPalette.unbuilt)
        }
    }

    private var trust: String { loc.t(device.paired ? "resigner.ui.device.trusted" : "resigner.ui.device.untrusted") }

    var body: some View {
        let mode = developerMode
        CardDivider()
        CardRow(loc.t("resigner.ui.device.os"), detail: device.osVersion.isEmpty ? "-" : device.osVersion) { EmptyView() }
        CardDivider()
        CardRow(loc.t("resigner.ui.device.connection"), detail: connection, dot: good(device.connected)) { EmptyView() }
        CardDivider()
        CardRow(loc.t("resigner.ui.device.trust"), detail: trust, dot: good(device.paired)) { EmptyView() }
        CardDivider()
        CardRow(loc.t("resigner.ui.device.developerMode"), detail: mode.text, dot: mode.dot) { EmptyView() }
        if let installed {
            CardDivider()
            CardRow(loc.t("resigner.ui.device.installed"), detail: installed.explanation.resolve(loc.t), detail2: installed.version,
                    dot: installed.status.color) { EmptyView() }
        }
    }
}

/// The certificate, the team, the profile and the last renewal.
struct SigningCard: View {
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var resign: ResignStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let facts = environment.facts
        CardGroup(loc.t("resigner.ui.signing.title")) {
            row("signing.team", loc.t("resigner.ui.signing.team"))
            CardDivider()
            row("signing.identity", loc.t("resigner.ui.signing.certificate"))
            CardDivider()
            row("provisioning.profile", loc.t("resigner.ui.signing.profile"))
            if let expiry = facts?.embeddedProfile?.expires {
                CardDivider()
                CardRow(loc.t("resigner.ui.signing.expiry"),
                        detail: AppSignature.describe(expiry, loc.t),
                        dot: AppSignature.isUrgent(expiry) ? LauncherPalette.danger : LauncherPalette.ready) { EmptyView() }
            }
            CardDivider()
            CardRow(loc.t("resigner.ui.signing.last"), detail: lastText) { EmptyView() }
        }
    }

    private var lastText: String {
        guard let record = resign.lastRecord else { return loc.t("resigner.ui.signing.never") }
        return String(format: loc.t("resigner.ui.signing.lastText"), record.date.shownMoment, record.deviceName, record.route.title(loc))
    }

    @ViewBuilder private func row(_ id: String, _ title: String) -> some View {
        if let item = environment.items.first(where: { $0.id == id }) {
            CardRow(title, detail: item.explanation.resolve(loc.t), detail2: item.version, dot: item.status.color) { StatusChip(status: item.status) }
        } else {
            CardRow(title, detail: loc.t("resigner.ui.checking")) { EmptyView() }
        }
    }
}

/// How many rows are ready, and the way to the diagnostics page.
struct DependenciesSummaryCard: View {
    @ObservedObject var environment: EnvironmentStore
    let open: (ResignerPage) -> Void
    @EnvironmentObject var loc: Localizer

    private var title: String {
        String(format: loc.t("resigner.ui.deps.summary"), String(environment.okCount), String(environment.items.count))
    }

    private var checked: String {
        guard let date = environment.lastChecked else { return loc.t("resigner.ui.checking") }
        return String(format: loc.t("resigner.ui.deps.checkedAt"), date.shownMoment)
    }

    private var dot: Color {
        if environment.items.isEmpty { return LauncherPalette.unbuilt }
        if !environment.blockers.isEmpty { return LauncherPalette.danger }
        return environment.problems.isEmpty ? LauncherPalette.ready : LauncherPalette.building
    }

    var body: some View {
        CardGroup(loc.t("resigner.ui.deps.title")) {
            CardRow(title, detail: checked, dot: dot) {
                HStack(spacing: 10) {
                    Button(loc.t("resigner.action.recheck")) { environment.check() }.disabled(environment.checking)
                    Button(loc.t("resigner.ui.openDiagnostics")) { open(.diagnostics) }
                }
            }
        }
    }
}

/// The log, closed by default, with copy and export.
struct ResignLogCard: View {
    @ObservedObject var log: ResignLog
    @ObservedObject var resign: ResignStore
    @Binding var isOpen: Bool
    @EnvironmentObject var loc: Localizer

    var body: some View {
        CardGroup(loc.t("resigner.ui.log.title"), footnote: loc.t("resigner.ui.log.note")) {
            CardDisclosure(loc.t("resigner.ui.log.show"), detail: log.text.isEmpty ? loc.t("resigner.ui.log.empty") : "", isOpen: isOpen) { isOpen.toggle() }
            if isOpen {
                CardDivider()
                ScrollView {
                    Text(log.text.isEmpty ? " " : log.text).font(.mono(11)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .frame(height: 260)
                CardDivider()
                HStack(spacing: 10) {
                    Spacer()
                    Button(loc.t("resigner.ui.log.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.text, forType: .string)
                    }
                    Button(loc.t("resigner.ui.export")) { exportDiagnostics(resign: resign, loc: loc) }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
    }
}

/// The save panel for the diagnostics export, then the file. Nothing of a key, a certificate or a password is in it.
@MainActor
func exportDiagnostics(resign: ResignStore, loc: Localizer) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = DiagnosticReport.fileName()
    panel.allowedContentTypes = [.plainText]
    panel.message = loc.t("resigner.ui.exportNote")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try resign.exportDiagnostics(to: url, appVersion: ResignerVersion.label, t: loc.t) }
    catch {
        let alert = NSAlert()
        alert.messageText = String(format: loc.t("resigner.ui.exportFailed"), error.localizedDescription)
        alert.runModal()
    }
}

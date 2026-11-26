import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher
import ResignerCore
import ResignerModel

/// Every dependency, grouped: what was found, its state, why, what to do, and the buttons that do it.
struct DiagnosticsPage: View {
    let stores: ResignerStores
    @ObservedObject var environment: EnvironmentStore
    @ObservedObject var resign: ResignStore
    let open: (ResignerPage) -> Void
    @EnvironmentObject var loc: Localizer

    var body: some View {
        LauncherPageScroll {
            CardPageHeading(loc.t("resigner.ui.diag.title"), note: loc.t("resigner.ui.diag.note"))
            HStack(spacing: 12) {
                Button { environment.check() } label: { Label(loc.t("resigner.action.recheck"), systemImage: "arrow.clockwise") }
                    .disabled(environment.checking || resign.running)
                Button { exportDiagnostics(resign: resign, loc: loc) } label: { Label(loc.t("resigner.ui.export"), systemImage: "square.and.arrow.up") }
                if environment.checking { ProgressView().controlSize(.small) }
                Spacer()
                if let checked = environment.lastChecked {
                    Text(String(format: loc.t("resigner.ui.deps.checkedAt"), checked.shownMoment)).font(.manrope(12.5)).foregroundStyle(.secondary)
                }
            }
            if let note = environment.fixNote {
                Label(note.resolve(loc.t), systemImage: "exclamationmark.triangle").font(.manrope(13)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if environment.items.isEmpty {
                CardGroup(loc.t("resigner.ui.diag.title")) { CardRow(loc.t("resigner.ui.checking")) { ProgressView().controlSize(.small) } }
            }
            ForEach(DependencyCategory.allCases, id: \.self) { category in
                let rows = environment.items.filter { $0.category == category }
                if !rows.isEmpty {
                    CardGroup(category.title(loc)) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { CardDivider() }
                            DependencyRowView(item: item, busy: environment.fixing == item.id || (item.id == "signing.test" && environment.testing),
                                              act: { action in perform(action, row: item.id, environment: environment, open: open) })
                        }
                    }
                }
            }
        }
    }
}

/// One dependency, laid out as the launcher's card rows: a status dot, the name with what was found, the explanation, the
/// remediation when there is a problem, then the status and the buttons.
struct DependencyRowView: View {
    let item: DependencyItem
    let busy: Bool
    let act: (RemediationAction) -> Void
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(item.status.color).frame(width: 7, height: 7).padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name.resolve(loc.t)).font(.manrope(14, .semibold))
                    if !item.blocking && item.status.isProblem {
                        Text(loc.t("resigner.ui.diag.advisory")).font(.manrope(11, .medium)).foregroundStyle(.secondary)
                    }
                }
                if !item.version.isEmpty {
                    Text(item.version).font(.mono(11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.version)
                        .textSelection(.enabled)
                }
                Text(item.explanation.resolve(loc.t)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if item.status.isProblem, let fix = item.remediation {
                    Text(fix.resolve(loc.t)).font(.manrope(12.5)).foregroundStyle(Color.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
                if !item.actions.isEmpty && (item.status.isProblem || item.status == .notChecked || item.actions.contains { $0.action == .testSign }) {
                    HStack(spacing: 8) {
                        ForEach(Array(item.actions.enumerated()), id: \.offset) { _, button in
                            Button(button.label.resolve(loc.t)) { act(button.action) }
                                .disabled(busy)
                                .help(help(button.action))
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            StatusChip(status: item.status)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    private func help(_ action: RemediationAction) -> String {
        switch action {
        case .runAdmin: return loc.t("resigner.ui.diag.adminHelp")
        case .runTool: return loc.t("resigner.ui.diag.toolHelp")
        case .openURL(let link): return link
        case .openApp(let path), .reveal(let path): return path
        default: return ""
        }
    }
}

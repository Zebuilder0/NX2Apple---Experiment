import Foundation
import NXCore

package enum DependencyState: String, Equatable, Sendable, CaseIterable {
    /// Installed and working.
    case ok
    /// Installed but set up wrong.
    case misconfigured
    case missing
    /// Installed, but too old.
    case outdated
    /// Present, but waiting for the user (a license, a choice, a tap on the device).
    case needsAction
    /// Not looked at yet (the trial signature runs on request and before a profile signature).
    case notChecked
    /// Not used by the route in use.
    case notApplicable

    package var isProblem: Bool { [.misconfigured, .missing, .outdated, .needsAction].contains(self) }
}

package enum DependencyCategory: String, Equatable, Sendable, CaseIterable {
    case xcode, tools, signing, provisioning, device, project
}

/// What a button next to a row does. Nothing here runs by itself: the app runs an action when the user presses its button, and an
/// action that changes the system (`runAdmin`) goes through macOS's administrator prompt.
package enum RemediationAction: Equatable, Sendable {
    case openURL(String)
    case openApp(String)
    case reveal(String)
    case runAdmin([String])
    case runTool([String])
    case testSign
    case openSettings
    case recheck
}

package struct RemediationButton: Equatable, Sendable {
    package var label: LocalText
    package var action: RemediationAction
    package init(_ label: LocalText, _ action: RemediationAction) { self.label = label; self.action = action }
}

package struct DependencyItem: Equatable, Sendable, Identifiable {
    package var id: String
    package var category: DependencyCategory
    package var name: LocalText
    /// What was found, as found ("27.2 (17C50)", a path, a certificate's name). Not translated.
    package var version: String
    package var status: DependencyState
    package var explanation: LocalText
    package var remediation: LocalText?
    package var actions: [RemediationButton]
    /// A problem here stops a re-sign on the route in use.
    package var blocking: Bool

    package init(id: String, category: DependencyCategory, name: LocalText, version: String = "", status: DependencyState,
                 explanation: LocalText, remediation: LocalText? = nil, actions: [RemediationButton] = [], blocking: Bool = true) {
        self.id = id; self.category = category; self.name = name; self.version = version; self.status = status
        self.explanation = explanation; self.remediation = remediation; self.actions = actions; self.blocking = blocking
    }

    /// Whether this row stops a re-sign now.
    package var stops: Bool { blocking && status.isProblem }
}

/// Turns the facts into the rows of the diagnostics page, as a pure function.
package enum DependencyEvaluator {
    package static func evaluate(_ f: EnvironmentFacts) -> [DependencyItem] {
        xcodeRows(f) + toolRows(f) + signingRows(f) + provisioningRows(f) + deviceRows(f) + projectRows(f)
    }

    package static func blockers(_ items: [DependencyItem]) -> [DependencyItem] { items.filter(\.stops) }

    /// A path that is safe inside the single-quoted shell text of an administrator prompt (`Toolchain.selectXcodeCmd`).
    package static func shellSafe(_ path: String) -> Bool {
        !path.isEmpty && path.hasPrefix("/") && path.range(of: #"^[A-Za-z0-9 ._/+\-]+$"#, options: .regularExpression) != nil
    }

    /// `do shell script "<tool> <args>" with administrator privileges`, for a fixed tool and fixed arguments.
    package static func adminCommand(_ words: [String]) -> [String]? {
        guard let tool = words.first, shellSafe(tool),
              words.dropFirst().allSatisfy({ $0.range(of: #"^[A-Za-z0-9 ._/+\-]+$"#, options: .regularExpression) != nil }) else { return nil }
        let script = words.map { "'" + $0 + "'" }.joined(separator: " ")
        return ["/usr/bin/osascript", "-e", "do shell script \"" + script + "\" with administrator privileges"]
    }

    private static let appStore = RemediationButton(LocalText("resigner.action.appStore"), .openURL(XcodeLocator.appStoreURL))
    private static let downloads = RemediationButton(LocalText("resigner.action.appleDownloads"), .openURL(XcodeLocator.downloadsURL))
    private static let settings = RemediationButton(LocalText("resigner.action.openSettings"), .openSettings)

    // MARK: Xcode

    static func xcodeRows(_ f: EnvironmentFacts) -> [DependencyItem] {
        var rows: [DependencyItem] = []
        let active = f.activeXcode
        let any = active ?? f.xcodes.first
        if let any {
            rows.append(DependencyItem(id: "xcode.app", category: .xcode, name: LocalText("resigner.dep.xcode.name"), version: any.label,
                                       status: .ok, explanation: LocalText("resigner.dep.xcode.found", any.path)))
        } else {
            rows.append(DependencyItem(id: "xcode.app", category: .xcode, name: LocalText("resigner.dep.xcode.name"), status: .missing,
                                       explanation: LocalText("resigner.dep.xcode.missing"), remediation: LocalText("resigner.dep.xcode.missingFix"),
                                       actions: [appStore, downloads]))
        }

        if let xcode = active ?? any {
            let old = (VersionNumber(xcode.version) ?? VersionNumber("0")!) < VersionNumber(XcodeLocator.minimumVersion)!
            rows.append(DependencyItem(id: "xcode.version", category: .xcode, name: LocalText("resigner.dep.version.name"), version: xcode.version,
                                       status: old ? .outdated : .ok,
                                       explanation: old ? LocalText("resigner.dep.version.old", xcode.version, XcodeLocator.minimumVersion)
                                                        : LocalText("resigner.dep.version.ok", XcodeLocator.minimumVersion),
                                       remediation: old ? LocalText("resigner.dep.version.oldFix") : nil, actions: old ? [downloads] : []))
        }

        rows.append(developerDirRow(f))

        if any != nil {
            switch f.licenseAccepted {
            case true?:
                rows.append(DependencyItem(id: "xcode.license", category: .xcode, name: LocalText("resigner.dep.license.name"), status: .ok,
                                           explanation: LocalText("resigner.dep.license.ok")))
            case false?:
                var actions: [RemediationButton] = []
                if let admin = adminCommand(["/usr/bin/xcodebuild", "-license", "accept"]) {
                    actions.append(RemediationButton(LocalText("resigner.action.acceptLicense"), .runAdmin(admin)))
                }
                if let app = (active ?? any)?.path { actions.append(RemediationButton(LocalText("resigner.action.openXcode"), .openApp(app))) }
                rows.append(DependencyItem(id: "xcode.license", category: .xcode, name: LocalText("resigner.dep.license.name"), status: .needsAction,
                                           explanation: LocalText("resigner.dep.license.no"), remediation: LocalText("resigner.dep.license.noFix"),
                                           actions: actions))
            case nil:
                rows.append(DependencyItem(id: "xcode.license", category: .xcode, name: LocalText("resigner.dep.license.name"), status: .notChecked,
                                           explanation: LocalText("resigner.dep.license.unknown"), blocking: false))
            }
            if let done = f.firstLaunchDone {
                var actions: [RemediationButton] = []
                if !done, let admin = adminCommand(["/usr/bin/xcodebuild", "-runFirstLaunch"]) {
                    actions.append(RemediationButton(LocalText("resigner.action.firstLaunch"), .runAdmin(admin)))
                }
                rows.append(DependencyItem(id: "xcode.firstLaunch", category: .xcode, name: LocalText("resigner.dep.firstLaunch.name"),
                                           status: done ? .ok : .needsAction,
                                           explanation: LocalText(done ? "resigner.dep.firstLaunch.ok" : "resigner.dep.firstLaunch.no"),
                                           remediation: done ? nil : LocalText("resigner.dep.firstLaunch.noFix"), actions: actions))
            }
        }

        if let version = f.xcodebuildVersion {
            rows.append(DependencyItem(id: "xcode.xcodebuild", category: .xcode, name: LocalText("resigner.dep.xcodebuild.name"), version: version,
                                       status: .ok, explanation: LocalText("resigner.dep.xcodebuild.ok")))
        } else {
            rows.append(DependencyItem(id: "xcode.xcodebuild", category: .xcode, name: LocalText("resigner.dep.xcodebuild.name"),
                                       status: any == nil ? .missing : .misconfigured,
                                       explanation: LocalText("resigner.dep.xcodebuild.fails", f.xcodebuildError.isEmpty ? "-" : f.xcodebuildError),
                                       remediation: LocalText("resigner.dep.xcodebuild.failsFix")))
        }

        let xcodeRoute = f.resolvedRoute == .xcode
        if let sdk = f.iosSDKVersion {
            rows.append(DependencyItem(id: "xcode.iosSDK", category: .xcode, name: LocalText("resigner.dep.iosSDK.name"), version: sdk, status: .ok,
                                       explanation: LocalText("resigner.dep.iosSDK.ok"), blocking: xcodeRoute))
        } else if f.xcodebuildVersion != nil {
            rows.append(DependencyItem(id: "xcode.iosSDK", category: .xcode, name: LocalText("resigner.dep.iosSDK.name"),
                                       status: xcodeRoute ? .missing : .notApplicable, explanation: LocalText("resigner.dep.iosSDK.missing"),
                                       remediation: LocalText("resigner.dep.iosSDK.missingFix"),
                                       actions: [RemediationButton(LocalText("resigner.action.downloadPlatform"), .runTool(Toolchain.iosPlatformCmd))],
                                       blocking: xcodeRoute))
        }
        return rows
    }

    static func developerDirRow(_ f: EnvironmentFacts) -> DependencyItem {
        let name = LocalText("resigner.dep.developerDir.name")
        if let chosen = f.chosenDeveloperDir {
            let exists = f.xcodes.contains { $0.developerDir == chosen }
            return DependencyItem(id: "xcode.developerDir", category: .xcode, name: name, version: chosen, status: exists ? .ok : .misconfigured,
                                  explanation: LocalText(exists ? "resigner.dep.developerDir.chosen" : "resigner.dep.developerDir.chosenGone", chosen),
                                  actions: exists ? [] : [settings])
        }
        let xcode = f.xcodes.first
        var actions: [RemediationButton] = []
        if let xcode, shellSafe(xcode.path) {
            actions.append(RemediationButton(LocalText("resigner.action.selectXcode"), .runAdmin(Toolchain.selectXcodeCmd(xcode.path))))
        }
        if xcode != nil { actions.append(RemediationButton(LocalText("resigner.action.useForResigner"), .openSettings)) }
        guard let selected = f.selectedDeveloperDir else {
            return DependencyItem(id: "xcode.developerDir", category: .xcode, name: name, status: .missing,
                                  explanation: LocalText("resigner.dep.developerDir.none"),
                                  remediation: LocalText(xcode == nil ? "resigner.dep.xcode.missingFix" : "resigner.dep.developerDir.fix"), actions: actions)
        }
        if ToolPaths.xcodeApp(ofDeveloperDir: selected) == nil {
            return DependencyItem(id: "xcode.developerDir", category: .xcode, name: name, version: selected,
                                  status: xcode == nil ? .missing : .misconfigured,
                                  explanation: LocalText("resigner.dep.developerDir.clt", selected),
                                  remediation: LocalText(xcode == nil ? "resigner.dep.xcode.missingFix" : "resigner.dep.developerDir.fix"),
                                  actions: xcode == nil ? [appStore] : actions)
        }
        return DependencyItem(id: "xcode.developerDir", category: .xcode, name: name, version: selected, status: .ok,
                              explanation: LocalText("resigner.dep.developerDir.ok"))
    }

    // MARK: Command line tools

    static func toolRows(_ f: EnvironmentFacts) -> [DependencyItem] {
        var rows: [DependencyItem] = []
        if f.xcrunWorks {
            rows.append(DependencyItem(id: "tools.xcrun", category: .tools, name: LocalText("resigner.dep.xcrun.name"),
                                       version: f.activeDeveloperDir ?? "", status: .ok,
                                       explanation: LocalText(f.commandLineToolsInstalled ? "resigner.dep.xcrun.okBoth" : "resigner.dep.xcrun.ok")))
        } else {
            rows.append(DependencyItem(id: "tools.xcrun", category: .tools, name: LocalText("resigner.dep.xcrun.name"), status: .missing,
                                       explanation: LocalText("resigner.dep.xcrun.missing"), remediation: LocalText("resigner.dep.xcrun.missingFix"),
                                       actions: [RemediationButton(LocalText("resigner.action.installCLT"), .runTool(["/usr/bin/xcode-select", "--install"]))]))
        }
        rows.append(DependencyItem(id: "tools.codesign", category: .tools, name: LocalText("resigner.dep.codesign.name"), version: "/usr/bin/codesign",
                                   status: f.codesignPresent ? .ok : .missing,
                                   explanation: LocalText(f.codesignPresent ? "resigner.dep.codesign.ok" : "resigner.dep.codesign.missing")))
        rows.append(DependencyItem(id: "tools.security", category: .tools, name: LocalText("resigner.dep.security.name"), version: "/usr/bin/security",
                                   status: f.securityPresent ? .ok : .missing,
                                   explanation: LocalText(f.securityPresent ? "resigner.dep.security.ok" : "resigner.dep.security.missing")))
        if let path = f.devicectlPath {
            rows.append(DependencyItem(id: "tools.devicectl", category: .tools, name: LocalText("resigner.dep.devicectl.name"), version: path,
                                       status: .ok, explanation: LocalText("resigner.dep.devicectl.ok")))
        } else {
            rows.append(DependencyItem(id: "tools.devicectl", category: .tools, name: LocalText("resigner.dep.devicectl.name"),
                                       status: f.xcrunWorks ? .outdated : .missing, explanation: LocalText("resigner.dep.devicectl.missing"),
                                       remediation: LocalText("resigner.dep.version.oldFix"), actions: [downloads]))
        }
        return rows
    }

    // MARK: Signing

    static func signingRows(_ f: EnvironmentFacts) -> [DependencyItem] {
        var rows: [DependencyItem] = []
        let profileRoute = f.resolvedRoute == .profile
        rows.append(teamRow(f))
        if !f.deviceCopyTeam.isEmpty, !f.selectedTeam.isEmpty, f.deviceCopyTeam != f.selectedTeam {
            rows.append(DependencyItem(id: "signing.sameTeam", category: .signing, name: LocalText("resigner.dep.sameTeam.name"),
                                       version: f.selectedTeam, status: .misconfigured,
                                       explanation: LocalText("resigner.dep.sameTeam.differs", f.deviceCopyTeam, f.selectedTeam),
                                       remediation: LocalText("resigner.dep.sameTeam.fix", f.deviceCopyTeam), actions: [settings]))
        }
        rows.append(identityRow(f, profileRoute: profileRoute))
        let tested = f.testSign != nil && f.testSignedIdentity == (f.signingCertificate?.sha1 ?? "")
        switch tested ? f.testSign : nil {
        case nil:
            rows.append(DependencyItem(id: "signing.test", category: .signing, name: LocalText("resigner.dep.testSign.name"), status: .notChecked,
                                       explanation: LocalText("resigner.dep.testSign.notRun"),
                                       actions: f.signingCertificate == nil ? [] : [RemediationButton(LocalText("resigner.action.testSign"), .testSign)],
                                       blocking: false))
        case .signed?:
            rows.append(DependencyItem(id: "signing.test", category: .signing, name: LocalText("resigner.dep.testSign.name"), status: .ok,
                                       explanation: LocalText("resigner.dep.testSign.ok")))
        case let result?:
            let (key, fix): (String, String)
            var detail = ""
            switch result {
            case .keyAccessDenied(let d): key = "resigner.dep.testSign.denied"; fix = "resigner.dep.testSign.deniedFix"; detail = d
            case .noPrivateKey(let d): key = "resigner.dep.testSign.noKey"; fix = "resigner.dep.identity.noKeyFix"; detail = d
            case .notTrusted(let d): key = "resigner.dep.testSign.notTrusted"; fix = "resigner.dep.identity.notTrustedFix"; detail = d
            case .failed(let d): key = "resigner.dep.testSign.failed"; fix = "resigner.dep.testSign.deniedFix"; detail = d
            case .signed: key = "resigner.dep.testSign.ok"; fix = "resigner.dep.testSign.deniedFix"
            }
            rows.append(DependencyItem(id: "signing.test", category: .signing, name: LocalText("resigner.dep.testSign.name"), version: detail,
                                       status: .misconfigured, explanation: LocalText(key), remediation: LocalText(fix),
                                       actions: [RemediationButton(LocalText("resigner.action.testSign"), .testSign)], blocking: profileRoute))
        }
        return rows
    }

    static func teamRow(_ f: EnvironmentFacts) -> DependencyItem {
        let name = LocalText("resigner.dep.team.name")
        guard !f.selectedTeam.isEmpty else {
            return DependencyItem(id: "signing.team", category: .signing, name: name, status: f.teams.isEmpty ? .missing : .needsAction,
                                  explanation: LocalText(f.teams.isEmpty ? "resigner.dep.team.none" : "resigner.dep.team.notChosen"),
                                  remediation: LocalText("resigner.dep.team.noneFix"), actions: [settings])
        }
        let team = f.team
        if f.resolvedRoute == .xcode, !f.xcodeAccountTeams.contains(where: { $0.id == f.selectedTeam }) {
            var actions: [RemediationButton] = []
            if let app = f.activeXcode?.path { actions.append(RemediationButton(LocalText("resigner.action.openXcode"), .openApp(app))) }
            return DependencyItem(id: "signing.team", category: .signing, name: name, version: f.selectedTeam, status: .needsAction,
                                  explanation: LocalText("resigner.dep.team.noAccount", f.selectedTeam),
                                  remediation: LocalText("resigner.dep.team.noAccountFix"), actions: actions)
        }
        let label = team.map { $0.name.isEmpty ? $0.id : $0.name + " · " + $0.id } ?? f.selectedTeam
        return DependencyItem(id: "signing.team", category: .signing, name: name, version: label, status: .ok,
                              explanation: LocalText(team?.personal == true ? "resigner.dep.team.free" : "resigner.dep.team.ok"))
    }

    static func identityRow(_ f: EnvironmentFacts, profileRoute: Bool) -> DependencyItem {
        let name = LocalText("resigner.dep.identity.name")
        let ofTeam = f.certificates.filter { f.selectedTeam.isEmpty || $0.team == f.selectedTeam }
        // The Xcode route can do without a certificate on this Mac: Xcode makes one for a signed-in account at the first signature.
        let blocking = profileRoute
        if let chosen = f.signingCertificate {
            let expiry = chosen.notAfter.map(ResignFormat.day) ?? "-"
            if !chosen.hasPrivateKey {
                return DependencyItem(id: "signing.identity", category: .signing, name: name, version: chosen.commonName, status: .misconfigured,
                                      explanation: LocalText("resigner.dep.identity.noKey"), remediation: LocalText("resigner.dep.identity.noKeyFix"),
                                      actions: [settings], blocking: blocking)
            }
            if chosen.expired(now: f.now) {
                return DependencyItem(id: "signing.identity", category: .signing, name: name, version: chosen.commonName, status: .outdated,
                                      explanation: LocalText("resigner.dep.identity.expired", expiry),
                                      remediation: LocalText("resigner.dep.identity.expiredFix"), blocking: blocking)
            }
            if let problem = chosen.identity?.problem { return invalidIdentity(chosen.commonName, problem, blocking: blocking) }
            if !f.selectedTeam.isEmpty, chosen.team != f.selectedTeam {
                return DependencyItem(id: "signing.identity", category: .signing, name: name, version: chosen.commonName, status: .misconfigured,
                                      explanation: LocalText("resigner.dep.identity.otherTeam", chosen.team, f.selectedTeam),
                                      actions: [settings], blocking: blocking)
            }
            return DependencyItem(id: "signing.identity", category: .signing, name: name, version: chosen.commonName, status: .ok,
                                  explanation: LocalText("resigner.dep.identity.ok", expiry), blocking: blocking)
        }
        if let withoutKey = ofTeam.first(where: { !$0.hasPrivateKey }) {
            return DependencyItem(id: "signing.identity", category: .signing, name: name, version: withoutKey.commonName, status: .misconfigured,
                                  explanation: LocalText("resigner.dep.identity.noKey"), remediation: LocalText("resigner.dep.identity.noKeyFix"),
                                  actions: [settings], blocking: blocking)
        }
        if let invalid = ofTeam.first(where: { $0.identity?.problem != nil }), let problem = invalid.identity?.problem {
            return invalidIdentity(invalid.commonName, problem, blocking: blocking)
        }
        if let expired = ofTeam.first(where: { $0.expired(now: f.now) }) {
            return DependencyItem(id: "signing.identity", category: .signing, name: name, version: expired.commonName, status: .outdated,
                                  explanation: LocalText("resigner.dep.identity.expired", expired.notAfter.map(ResignFormat.day) ?? "-"),
                                  remediation: LocalText("resigner.dep.identity.expiredFix"), blocking: blocking)
        }
        return DependencyItem(id: "signing.identity", category: .signing, name: name, status: profileRoute ? .missing : .notApplicable,
                              explanation: LocalText(profileRoute ? "resigner.dep.identity.none" : "resigner.dep.identity.xcodeMakes"),
                              remediation: profileRoute ? LocalText("resigner.dep.identity.noneFix") : nil,
                              actions: profileRoute ? [settings] : [], blocking: blocking)
    }

    static func invalidIdentity(_ name: String, _ problem: String, blocking: Bool) -> DependencyItem {
        let key: String, fix: String
        var actions: [RemediationButton] = []
        if problem.contains("EXPIRED") { key = "resigner.dep.identity.expiredReason"; fix = "resigner.dep.identity.expiredFix" }
        else if problem.contains("REVOKED") { key = "resigner.dep.identity.revoked"; fix = "resigner.dep.identity.expiredFix" }
        else if problem.contains("NOT_TRUSTED") || problem.contains("TRUST") {
            key = "resigner.dep.identity.notTrusted"; fix = "resigner.dep.identity.notTrustedFix"
            actions.append(RemediationButton(LocalText("resigner.action.appleCA"), .openURL("https://www.apple.com/certificateauthority/")))
        } else { key = "resigner.dep.identity.invalid"; fix = "resigner.dep.identity.expiredFix" }
        return DependencyItem(id: "signing.identity", category: .signing, name: LocalText("resigner.dep.identity.name"), version: name,
                              status: .misconfigured, explanation: LocalText(key, problem), remediation: LocalText(fix), actions: actions, blocking: blocking)
    }

    // MARK: Provisioning

    static func provisioningRows(_ f: EnvironmentFacts) -> [DependencyItem] {
        var rows: [DependencyItem] = []
        let name = LocalText("resigner.dep.profile.name")
        if f.resolvedRoute == .xcode {
            var explanation = LocalText("resigner.dep.profile.xcode")
            var version = ""
            if let embedded = f.embeddedProfile, let expires = embedded.expires {
                version = embedded.name
                explanation = LocalText(expires <= f.now ? "resigner.dep.profile.xcodeExpired" : "resigner.dep.profile.xcodeCurrent", ResignFormat.day(expires))
            }
            rows.append(DependencyItem(id: "provisioning.profile", category: .provisioning, name: name, version: version, status: .ok,
                                       explanation: explanation))
        } else {
            let need = f.profileRequirement
            if let chosen = f.signingProfile ?? f.profileWithoutMemoryLimit {
                let issues = ProfileMatcher.issues(chosen, need)
                let stops = issues.filter(\.blocking)
                let label = chosen.name + (chosen.expires.map { " · " + ResignFormat.day($0) } ?? "")
                if let first = stops.first {
                    let memory = first == .entitlementMissing(EntitlementPlanner.memoryLimit)
                    rows.append(DependencyItem(id: "provisioning.profile", category: .provisioning, name: name, version: label,
                                               status: { if case .expired = first { return .outdated } else { return .misconfigured } }(),
                                               explanation: memory ? LocalText("resigner.dep.entitlements.memory", EntitlementPlanner.memoryLimit) : first.text,
                                               remediation: LocalText(memory ? "resigner.dep.entitlements.memoryFix" : "resigner.dep.profile.fix"),
                                               actions: [settings]))
                } else {
                    let soon = issues.first { !$0.blocking }
                    rows.append(DependencyItem(id: "provisioning.profile", category: .provisioning, name: name, version: label, status: .ok,
                                               explanation: soon?.text ?? LocalText("resigner.dep.profile.ok")))
                }
            } else {
                // Why the closest one does not fit: a profile for this bundle ID first, then any of the team's
                let near = f.profiles.first { $0.allows(bundleID: need.bundleID) && $0.teamID == f.selectedTeam }
                    ?? f.profiles.first { $0.allows(bundleID: need.bundleID) }
                let why = near.flatMap { ProfileMatcher.issues($0, need).first(where: \.blocking)?.text }
                rows.append(DependencyItem(id: "provisioning.profile", category: .provisioning, name: name, version: near?.name ?? "",
                                           status: .missing, explanation: why ?? LocalText("resigner.dep.profile.none", need.bundleID),
                                           remediation: LocalText("resigner.dep.profile.noneFix"), actions: [settings]))
            }
        }
        rows.append(entitlementsRow(f))
        return rows
    }

    static func entitlementsRow(_ f: EnvironmentFacts) -> DependencyItem {
        let name = LocalText("resigner.dep.entitlements.name")
        let required = f.requiredEntitlements
        let list = required.isEmpty ? "-" : required.joined(separator: ", ")
        if f.resolvedRoute == .xcode {
            let memory = required.contains(EntitlementPlanner.memoryLimit)
            return DependencyItem(id: "provisioning.entitlements", category: .provisioning, name: name, version: list,
                                  status: .ok, explanation: LocalText(memory ? "resigner.dep.entitlements.xcodeMemory" : "resigner.dep.entitlements.xcode"),
                                  blocking: false)
        }
        guard let profile = f.signingProfile ?? f.profileWithoutMemoryLimit else {
            return DependencyItem(id: "provisioning.entitlements", category: .provisioning, name: name, version: list, status: .notChecked,
                                  explanation: LocalText("resigner.dep.entitlements.noProfile"), blocking: false)
        }
        let allowDrop: Set<String> = f.allowWithoutMemoryLimit ? [EntitlementPlanner.memoryLimit] : []
        switch EntitlementPlanner.plan(current: f.appEntitlements, profile: profile, bundleID: f.targetBundleID, allowDropping: allowDrop) {
        case .success(let plan):
            return DependencyItem(id: "provisioning.entitlements", category: .provisioning, name: name, version: list, status: .ok,
                                  explanation: plan.dropped.isEmpty ? LocalText("resigner.dep.entitlements.ok")
                                      : LocalText("resigner.dep.entitlements.dropped", plan.dropped.joined(separator: ", ")))
        case .failure(.notGranted(let key)):
            return DependencyItem(id: "provisioning.entitlements", category: .provisioning, name: name, version: list, status: .misconfigured,
                                  explanation: LocalText(key == EntitlementPlanner.memoryLimit ? "resigner.dep.entitlements.memory" : "resigner.dep.entitlements.missing", key),
                                  remediation: LocalText(key == EntitlementPlanner.memoryLimit ? "resigner.dep.entitlements.memoryFix" : "resigner.dep.profile.fix"),
                                  actions: [settings])
        case .failure(.unsupported(let key)):
            return DependencyItem(id: "provisioning.entitlements", category: .provisioning, name: name, version: list, status: .misconfigured,
                                  explanation: LocalText("resigner.dep.entitlements.unsupported", key))
        }
    }

    // MARK: Device

    static func deviceRows(_ f: EnvironmentFacts) -> [DependencyItem] {
        var rows: [DependencyItem] = []
        if f.devicectlPath != nil {
            rows.append(DependencyItem(id: "device.list", category: .device, name: LocalText("resigner.dep.deviceList.name"),
                                       version: String(f.devices.count), status: f.deviceListWorked ? .ok : .misconfigured,
                                       explanation: LocalText(f.deviceListWorked ? "resigner.dep.deviceList.ok" : "resigner.dep.deviceList.fails"),
                                       remediation: f.deviceListWorked ? nil : LocalText("resigner.dep.deviceList.failsFix")))
        }
        let name = LocalText("resigner.dep.device.name")
        guard let device = f.device else {
            let none = f.devices.isEmpty
            rows.append(DependencyItem(id: "device.selected", category: .device, name: name, status: none ? .missing : .needsAction,
                                       explanation: LocalText(none ? "resigner.dep.device.none" : (f.selectedDevice.isEmpty ? "resigner.dep.device.notChosen" : "resigner.dep.device.gone")),
                                       remediation: LocalText("resigner.dep.device.noneFix"),
                                       actions: [RemediationButton(LocalText("resigner.action.recheck"), .recheck)]))
            return rows
        }
        let label = [device.name, device.model, device.osVersion].filter { !$0.isEmpty }.joined(separator: " · ")
        let minimum = f.shell.app?.minimumOS ?? ""
        let issues = DeviceReadiness.issues(device, minimumOS: minimum)
        if let first = issues.first(where: \.blocking) {
            let status: DependencyState = { switch first { case .osTooOld: return .outdated
                                                            case .notConnected: return .missing
                                                            default: return .needsAction } }()
            rows.append(DependencyItem(id: "device.selected", category: .device, name: name, version: label, status: status,
                                       explanation: first.text, remediation: LocalText("resigner.dep.device.fix"),
                                       actions: [RemediationButton(LocalText("resigner.action.recheck"), .recheck)]))
        } else {
            rows.append(DependencyItem(id: "device.selected", category: .device, name: name, version: label, status: .ok,
                                       explanation: issues.first?.text ?? LocalText(device.wired ? "resigner.dep.device.okWired" : "resigner.dep.device.okNetwork")))
        }
        rows.append(installedRow(f, device: device))
        return rows
    }

    static func installedRow(_ f: EnvironmentFacts, device: DeviceStatus) -> DependencyItem {
        let name = LocalText("resigner.dep.installed.name")
        guard let apps = f.installedApps else {
            return DependencyItem(id: "device.installed", category: .device, name: name, status: .notChecked,
                                  explanation: LocalText("resigner.dep.installed.unknown"), blocking: false)
        }
        switch InstallTargetCheck.decide(bundleID: f.targetBundleID, apps: apps) {
        case .upgrade(let app):
            return DependencyItem(id: "device.installed", category: .device, name: name, version: app.bundle, status: .ok,
                                  explanation: LocalText("resigner.dep.installed.upgrade", device.name))
        case .firstInstall:
            return DependencyItem(id: "device.installed", category: .device, name: name, version: f.targetBundleID,
                                  status: f.allowFirstInstall ? .ok : .needsAction,
                                  explanation: LocalText("resigner.dep.installed.none", device.name),
                                  remediation: f.allowFirstInstall ? nil : LocalText("resigner.dep.installed.noneFix"))
        case .otherBundleOnly(let others):
            return DependencyItem(id: "device.installed", category: .device, name: name, version: others.map(\.bundle).joined(separator: ", "),
                                  status: .misconfigured,
                                  explanation: LocalText("resigner.dep.installed.other", others.map(\.bundle).joined(separator: ", "), f.targetBundleID),
                                  remediation: LocalText("resigner.dep.installed.otherFix"), actions: [settings])
        }
    }

    // MARK: Project

    static func projectRows(_ f: EnvironmentFacts) -> [DependencyItem] {
        var rows: [DependencyItem] = []
        let shell = f.shell
        guard shell.rootExists else {
            rows.append(DependencyItem(id: "project.root", category: .project, name: LocalText("resigner.dep.root.name"), version: shell.root,
                                       status: .missing, explanation: LocalText("resigner.dep.root.missing"),
                                       remediation: LocalText("resigner.dep.root.missingFix"), actions: [settings]))
            return rows
        }
        rows.append(DependencyItem(id: "project.root", category: .project, name: LocalText("resigner.dep.root.name"), version: shell.root,
                                   status: .ok, explanation: LocalText("resigner.dep.root.ok"),
                                   actions: [RemediationButton(LocalText("resigner.action.reveal"), .reveal(shell.root))]))
        if let library = shell.library {
            rows.append(DependencyItem(id: "project.library", category: .project, name: LocalText("resigner.dep.library.name"),
                                       version: library.bundleID, status: .ok,
                                       explanation: LocalText("resigner.dep.library.ok", String(library.games.count), library.team.isEmpty ? "-" : library.team)))
        } else {
            rows.append(DependencyItem(id: "project.library", category: .project, name: LocalText("resigner.dep.library.name"), status: .missing,
                                       explanation: LocalText("resigner.dep.library.missing"), remediation: LocalText("resigner.dep.root.missingFix")))
        }
        rows.append(appRow(f))
        rows.append(projectRow(f))
        return rows
    }

    static func appRow(_ f: EnvironmentFacts) -> DependencyItem {
        let name = LocalText("resigner.dep.app.name")
        guard let app = f.shell.app else {
            return DependencyItem(id: "project.app", category: .project, name: name, version: f.shell.appPath, status: .missing,
                                  explanation: LocalText("resigner.dep.app.missing"), remediation: LocalText("resigner.dep.root.missingFix"))
        }
        let label = [app.displayName, app.version].filter { !$0.isEmpty }.joined(separator: " ")
        if app.bundleID != f.targetBundleID, f.resolvedRoute == .profile {
            return DependencyItem(id: "project.app", category: .project, name: name, version: app.bundleID, status: .misconfigured,
                                  explanation: LocalText("resigner.dep.app.bundle", app.bundleID, f.targetBundleID),
                                  remediation: LocalText("resigner.dep.app.bundleFix"), actions: [settings])
        }
        if app.games.isEmpty {
            return DependencyItem(id: "project.app", category: .project, name: name, version: label, status: .misconfigured,
                                  explanation: LocalText("resigner.dep.app.noGames"), remediation: LocalText("resigner.dep.root.missingFix"))
        }
        if let broken = app.games.first(where: { $0.missingFile != nil }) {
            return DependencyItem(id: "project.app", category: .project, name: name, version: label, status: .misconfigured,
                                  explanation: LocalText("resigner.dep.app.incomplete", broken.name.isEmpty ? broken.titleID : broken.name, broken.missingFile ?? ""),
                                  remediation: LocalText("resigner.dep.app.incompleteFix"))
        }
        if !app.nestedBundles.isEmpty, f.resolvedRoute == .profile {
            return DependencyItem(id: "project.app", category: .project, name: name, version: label, status: .misconfigured,
                                  explanation: LocalText("resigner.dep.app.nested", app.nestedBundles.joined(separator: ", ")))
        }
        let games = app.games.map { $0.name.isEmpty ? $0.titleID : $0.name }.joined(separator: ", ")
        return DependencyItem(id: "project.app", category: .project, name: name, version: label, status: .ok,
                              explanation: LocalText("resigner.dep.app.ok", String(app.games.count), games))
    }

    static func projectRow(_ f: EnvironmentFacts) -> DependencyItem {
        let name = LocalText("resigner.dep.project.name")
        let project = f.shell.project
        let xcodeRoute = f.route == .xcode || (f.route == .automatic && project.usable)
        if project.usable {
            return DependencyItem(id: "project.xcode", category: .project, name: name, version: project.path, status: .ok,
                                  explanation: LocalText(project.derivedDataExists ? "resigner.dep.project.ok" : "resigner.dep.project.noDerived"),
                                  blocking: xcodeRoute)
        }
        let status: DependencyState = project.exists ? .misconfigured : .missing
        let explanation: LocalText
        if !project.exists { explanation = LocalText("resigner.dep.project.missing") }
        else if !project.brokenLinks.isEmpty { explanation = LocalText("resigner.dep.project.links", project.brokenLinks.joined(separator: ", ")) }
        else { explanation = LocalText("resigner.dep.project.frameworks", String(project.missingFrameworks.count)) }
        return DependencyItem(id: "project.xcode", category: .project, name: name, version: project.path,
                              status: f.route == .xcode ? status : .notApplicable, explanation: explanation,
                              remediation: LocalText(f.route == .xcode ? "resigner.dep.project.fixXcode" : "resigner.dep.project.fixAuto"),
                              blocking: f.route == .xcode)
    }
}

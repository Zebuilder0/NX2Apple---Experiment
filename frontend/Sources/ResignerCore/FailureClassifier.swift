import Foundation
import NXCore

/// The steps of a re-sign, in the order they run.
package enum ResignStep: Int, CaseIterable, Equatable, Sendable, Comparable {
    case checkingEnvironment, detectingDevice, validatingCredentials, preparingProject, signing, verifyingSignature, installing,
         verifyingInstallation, completed

    package var title: LocalText {
        switch self {
        case .checkingEnvironment: return LocalText("resigner.step.environment")
        case .detectingDevice: return LocalText("resigner.step.device")
        case .validatingCredentials: return LocalText("resigner.step.credentials")
        case .preparingProject: return LocalText("resigner.step.project")
        case .signing: return LocalText("resigner.step.signing")
        case .verifyingSignature: return LocalText("resigner.step.verifySignature")
        case .installing: return LocalText("resigner.step.installing")
        case .verifyingInstallation: return LocalText("resigner.step.verifyInstall")
        case .completed: return LocalText("resigner.step.completed")
        }
    }

    /// Stopping is safe before the install starts. During the install the device is left to finish what it began.
    package var cancellable: Bool { self < .installing }

    package static func < (a: ResignStep, b: ResignStep) -> Bool { a.rawValue < b.rawValue }
}

package enum ResignFailureKind: String, Equatable, Sendable {
    case dependency, device, credentials, project, signing, memoryCapability, teamTaken, teamMismatch, verification, install,
         firstInstall, otherBundle, cancelled
}

/// Why a re-sign stopped, in words for the user, with the tool's own last line kept apart (redacted when it is logged or shown).
package struct ResignFailure: Equatable, Sendable {
    package var step: ResignStep
    package var kind: ResignFailureKind
    package var message: LocalText
    package var detail: String
    package var remedy: LocalText?

    package init(step: ResignStep, kind: ResignFailureKind, message: LocalText, detail: String = "", remedy: LocalText? = nil) {
        self.step = step; self.kind = kind; self.message = message; self.detail = detail; self.remedy = remedy
    }

    /// A failure that names a dependency asks for a fresh dependency check.
    package var recheckDependencies: Bool { [.dependency, .credentials, .device, .signing, .install].contains(kind) }
}

/// Sorts the tools' output into a cause the user can act on. The patterns are stable parts of Apple's messages. When none matches,
/// the tool's last error line is the message, so nothing is ever reported as a bare "failed".
package enum FailureClassifier {
    /// The last line that reads as an error: `error:`, `ERROR:`, `Error:` or `Error Domain`, else the last line.
    package static func lastError(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last { $0.contains("error:") || $0.hasPrefix("ERROR:") || $0.hasPrefix("Error:") || $0.contains("Error Domain") || $0.contains("rror:") }
            ?? lines.last ?? ""
    }

    private static func has(_ output: String, _ needles: [String]) -> Bool {
        let lower = output.lowercased()
        return needles.contains { lower.contains($0.lowercased()) }
    }

    /// xcodebuild on the Xcode route.
    package static func xcodebuild(_ output: String, team: String, bundleID: String) -> ResignFailure {
        let detail = lastError(output)
        func fail(_ kind: ResignFailureKind, _ key: String, _ remedy: String?, _ args: String...) -> ResignFailure {
            ResignFailure(step: .signing, kind: kind, message: LocalText(key, args: args), detail: detail, remedy: remedy.map { LocalText($0) })
        }
        if ShellInstall.memoryCapabilityMissing(output) {
            return fail(.memoryCapability, "resigner.fail.memoryCapability", "resigner.fail.memoryCapabilityFix", team)
        }
        if BuildFailureClassifier.signingTeamTaken(output) || has(output, ["Failed to register bundle identifier"]) {
            return fail(.teamTaken, "resigner.fail.teamTaken", "resigner.fail.teamTakenFix", bundleID, team)
        }
        if has(output, ["No Account for Team", "No accounts", "account was not found"]) {
            return fail(.credentials, "resigner.fail.noAccount", "resigner.dep.team.noAccountFix", team)
        }
        if has(output, ["session has expired", "Unable to log in", "Please sign in", "authentication"]) {
            return fail(.credentials, "resigner.fail.signIn", "resigner.dep.team.noAccountFix", team)
        }
        if has(output, ["You have not agreed to the Xcode license"]) {
            return fail(.dependency, "resigner.dep.license.no", "resigner.dep.license.noFix")
        }
        if has(output, ["Program License Agreement", "PLA Update", "PLA update"]) {
            return fail(.credentials, "resigner.fail.agreement", "resigner.fail.agreementFix", team)
        }
        if has(output, ["maximum number of registered", "device limit"]) {
            return fail(.credentials, "resigner.fail.deviceLimit", "resigner.fail.deviceLimitFix")
        }
        if has(output, ["No signing certificate", "doesn't include signing certificate", "no valid signing identit", "revoked"]) {
            return fail(.credentials, "resigner.fail.noCertificate", "resigner.dep.identity.noneFix", team)
        }
        if has(output, ["requires a provisioning profile", "No profiles for", "doesn't include the currently selected device", "isn't registered in your developer account"]) {
            return fail(.credentials, "resigner.fail.noProfileXcode", "resigner.fail.noProfileXcodeFix", bundleID)
        }
        if has(output, ["Developer Mode"]) { return fail(.device, "resigner.device.developerModeOff", "resigner.dep.device.fix") }
        if has(output, ["Unable to find a destination", "is not available because", "Timed out waiting", "device is locked", "is busy"]) {
            return fail(.device, "resigner.fail.destination", "resigner.dep.device.fix")
        }
        if has(output, ["Communication with Apple failed", "network connection", "offline"]) {
            return fail(.credentials, "resigner.fail.network", "resigner.fail.networkFix")
        }
        if has(output, ["Build input file cannot be found", "No such file or directory", "could not find included file", "Missing package product"]) {
            return fail(.project, "resigner.fail.projectFiles", "resigner.dep.project.fixAuto")
        }
        if has(output, ["No space left on device"]) { return fail(.project, "resigner.fail.diskFull", nil) }
        return fail(.signing, "resigner.fail.xcodebuild", nil, detail)
    }

    /// codesign on the profile route.
    package static func codesign(_ output: String, item: String) -> ResignFailure {
        let detail = lastError(output)
        func fail(_ kind: ResignFailureKind, _ key: String, _ remedy: String?, _ args: String...) -> ResignFailure {
            ResignFailure(step: .signing, kind: kind, message: LocalText(key, args: args), detail: detail, remedy: remedy.map { LocalText($0) })
        }
        switch TestSignResult.classify(status: 1, output: output) {
        case .keyAccessDenied: return fail(.credentials, "resigner.dep.testSign.denied", "resigner.dep.testSign.deniedFix")
        case .noPrivateKey: return fail(.credentials, "resigner.dep.testSign.noKey", "resigner.dep.identity.noKeyFix")
        case .notTrusted: return fail(.credentials, "resigner.dep.testSign.notTrusted", "resigner.dep.identity.notTrustedFix")
        case .signed, .failed: break
        }
        if has(output, ["resource fork, Finder information, or similar detritus"]) { return fail(.project, "resigner.fail.detritus", nil, item) }
        if has(output, ["bundle format unrecognized", "bundle format is ambiguous", "code object is not signed at all"]) {
            return fail(.project, "resigner.fail.bundleFormat", "resigner.dep.app.incompleteFix", item)
        }
        if has(output, ["No space left on device"]) { return fail(.project, "resigner.fail.diskFull", nil) }
        return fail(.signing, "resigner.fail.codesign", nil, item, detail)
    }

    /// devicectl's install.
    package static func install(_ output: String, deviceName: String, team: String) -> ResignFailure {
        let detail = lastError(output)
        func fail(_ kind: ResignFailureKind, _ key: String, _ remedy: String?, _ args: String...) -> ResignFailure {
            ResignFailure(step: .installing, kind: kind, message: LocalText(key, args: args), detail: detail, remedy: remedy.map { LocalText($0) })
        }
        if has(output, ["MismatchedApplicationIdentifierEntitlement", "does not match installed application", "application-identifier entitlement"]) {
            return fail(.teamMismatch, "resigner.fail.installTeam", "resigner.fail.installTeamFix", deviceName, team)
        }
        if has(output, ["valid provisioning profile for this executable was not found", "0xe8008015", "ApplicationVerificationFailed"]) {
            return fail(.install, "resigner.fail.installProfile", "resigner.fail.installProfileFix", deviceName)
        }
        if has(output, ["No code signature found", "0xe800801c", "signature", "0xe8008001"]) && !has(output, ["locked"]) {
            return fail(.install, "resigner.fail.installSignature", nil, deviceName)
        }
        if has(output, ["Developer Mode", "developer mode"]) { return fail(.device, "resigner.device.developerModeOff", "resigner.dep.device.fix") }
        if has(output, ["locked", "passcode"]) { return fail(.device, "resigner.fail.installLocked", nil, deviceName) }
        if has(output, ["pair", "trust"]) { return fail(.device, "resigner.device.notPaired", "resigner.dep.device.fix") }
        if has(output, ["not enough space", "insufficient storage", "No space left"]) { return fail(.install, "resigner.fail.installSpace", nil, deviceName) }
        if has(output, ["timed out", "Timed out", "connection"]) { return fail(.device, "resigner.fail.installConnection", "resigner.dep.device.fix", deviceName) }
        return fail(.install, "resigner.fail.install", nil, deviceName, detail)
    }
}

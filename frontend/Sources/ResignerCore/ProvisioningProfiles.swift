import Foundation
import NXCore

/// One entitlement's value, as far as the Resigner reads and writes them. The shell's entitlements are booleans, strings and lists
/// of strings. Anything else is kept as `unsupported` and stops a profile signature with its name, instead of being dropped.
package enum EntitlementValue: Equatable, Sendable {
    case bool(Bool)
    case string(String)
    case strings([String])
    case number(Int)
    case unsupported

    package init(_ any: Any) {
        if let b = any as? Bool, isPlistBool(any) { self = .bool(b) }
        else if let s = any as? String { self = .string(s) }
        else if let a = any as? [Any], a.allSatisfy({ $0 is String }) { self = .strings(a.compactMap { $0 as? String }) }
        else if let n = any as? Int { self = .number(n) }
        else if let b = any as? Bool { self = .bool(b) }
        else { self = .unsupported }
    }

    /// The value for a property list, nil for `unsupported`.
    package var plistObject: Any? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s
        case .strings(let a): return a
        case .number(let n): return n
        case .unsupported: return nil
        }
    }

    /// Whether a profile's value grants anything: true, a string, a non-empty list.
    package var grants: Bool {
        switch self {
        case .bool(let b): return b
        case .string(let s): return !s.isEmpty
        case .strings(let a): return !a.isEmpty
        case .number: return true
        case .unsupported: return false
        }
    }

    package static func dictionary(_ any: Any?) -> [String: EntitlementValue] {
        guard let dict = any as? [String: Any] else { return [:] }
        return dict.mapValues(EntitlementValue.init)
    }
}

/// A Bool in a property list decodes as NSNumber on Apple platforms, where `as? Bool` also accepts 0 and 1. This tells them apart.
private func isPlistBool(_ any: Any) -> Bool {
    #if canImport(ObjectiveC)
    if let n = any as? NSNumber { return String(cString: n.objCType) == "c" }
    return any is Bool
    #else
    return any is Bool
    #endif
}

/// A provisioning profile, read from its property list (`security cms -D -i <file>`).
package struct ProvisioningProfile: Equatable, Sendable, Identifiable {
    package var uuid: String
    package var name: String
    package var path: String
    package var teamID: String
    package var teamName: String
    package var appIDName: String
    /// `application-identifier` of its entitlements: `<team>.<bundle ID>` or a wildcard (`<team>.*`, `<team>.org.nxnative.*`).
    package var applicationIdentifier: String
    package var created: Date?
    package var expires: Date?
    package var devices: [String]
    package var allDevices: Bool
    /// The SHA-1 of each certificate the profile allows, upper case.
    package var certificates: [String]
    package var entitlements: [String: EntitlementValue]
    package var platforms: [String]
    package var xcodeManaged: Bool

    package init(uuid: String, name: String, path: String = "", teamID: String, teamName: String = "", appIDName: String = "",
                 applicationIdentifier: String, created: Date? = nil, expires: Date?, devices: [String] = [], allDevices: Bool = false,
                 certificates: [String] = [], entitlements: [String: EntitlementValue] = [:], platforms: [String] = ["iOS"], xcodeManaged: Bool = false) {
        self.uuid = uuid; self.name = name; self.path = path; self.teamID = teamID; self.teamName = teamName; self.appIDName = appIDName
        self.applicationIdentifier = applicationIdentifier; self.created = created; self.expires = expires; self.devices = devices
        self.allDevices = allDevices; self.certificates = certificates.map { $0.uppercased() }; self.entitlements = entitlements
        self.platforms = platforms; self.xcodeManaged = xcodeManaged
    }

    package var id: String { uuid }

    package enum Kind: String, Equatable, Sendable { case development, adHoc, enterprise, appStore }

    package var kind: Kind {
        if allDevices { return .enterprise }
        if devices.isEmpty { return .appStore }
        if case .bool(true)? = entitlements["get-task-allow"] { return .development }
        return .adHoc
    }

    /// The bundle ID part of the application identifier (`org.nxnative.shell`, `*`, `org.nxnative.*`).
    package var bundlePattern: String {
        let prefix = teamID + "."
        return applicationIdentifier.hasPrefix(prefix) ? String(applicationIdentifier.dropFirst(prefix.count))
            : applicationIdentifier.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? applicationIdentifier
    }

    package var isWildcard: Bool { bundlePattern.hasSuffix("*") }

    package func allows(bundleID: String) -> Bool {
        let pattern = bundlePattern
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") { return bundleID.hasPrefix(String(pattern.dropLast())) }
        return pattern == bundleID
    }

    package func allowsDevice(_ udid: String) -> Bool {
        allDevices || devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    /// Whether the profile grants an entitlement the app asks for. `keychain-access-groups` and the identifier keys follow the team.
    package func grants(_ key: String) -> Bool {
        switch key {
        case "application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "get-task-allow": return true
        default: return entitlements[key]?.grants ?? false
        }
    }
}

package enum ProvisioningProfiles {
    /// Where Xcode keeps profiles: its own folder since Xcode 16, the MobileDevice folder before.
    package static func folders(home: String = NSHomeDirectory()) -> [String] {
        [home + "/Library/Developer/Xcode/UserData/Provisioning Profiles", home + "/Library/MobileDevice/Provisioning Profiles"]
    }

    package static func parse(plist data: Data, path: String = "") -> ProvisioningProfile? {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let uuid = root["UUID"] as? String else { return nil }
        let entitlements = EntitlementValue.dictionary(root["Entitlements"])
        let team = (root["TeamIdentifier"] as? [String])?.first ?? (root["ApplicationIdentifierPrefix"] as? [String])?.first ?? ""
        var appID = ""
        if case .string(let s)? = entitlements["application-identifier"] { appID = s }
        let certificates = (root["DeveloperCertificates"] as? [Any] ?? []).compactMap { $0 as? Data }.map(SHA1.hex)
        return ProvisioningProfile(uuid: uuid, name: root["Name"] as? String ?? "", path: path, teamID: team,
                                   teamName: root["TeamName"] as? String ?? "", appIDName: root["AppIDName"] as? String ?? "",
                                   applicationIdentifier: appID, created: root["CreationDate"] as? Date, expires: root["ExpirationDate"] as? Date,
                                   devices: root["ProvisionedDevices"] as? [String] ?? [],
                                   allDevices: (root["ProvisionsAllDevices"] as? Bool) ?? false,
                                   certificates: certificates, entitlements: entitlements,
                                   platforms: root["Platform"] as? [String] ?? [],
                                   xcodeManaged: (root["IsXcodeManaged"] as? Bool) ?? false)
    }

    /// Every readable profile in Xcode's folders, newest first, each UUID once (the same profile can sit in both folders).
    package static func load(home: String = NSHomeDirectory(), runner: ProcessRunner = SystemProcessRunner(), tools: ToolPaths = ToolPaths(),
                             fm: FileManager = .default) -> [ProvisioningProfile] {
        var found: [ProvisioningProfile] = []
        for folder in folders(home: home) {
            let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            for name in names where name.hasSuffix(".mobileprovision") || name.hasSuffix(".provisionprofile") {
                let path = folder + "/" + name
                if let profile = read(path, runner: runner, tools: tools), !found.contains(where: { $0.uuid == profile.uuid }) {
                    found.append(profile)
                }
            }
        }
        return found.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    /// One profile file (or an app's embedded.mobileprovision): the CMS envelope is opened by `security cms -D`.
    package static func read(_ path: String, runner: ProcessRunner = SystemProcessRunner(), tools: ToolPaths = ToolPaths()) -> ProvisioningProfile? {
        let r = runner.capture(ProcessLaunch(executable: tools.security, arguments: ["cms", "-D", "-i", path],
                                             environment: tools.environment(), timeout: 20))
        guard r.ok else { return nil }
        return parse(plist: Data(r.out.utf8), path: path)
    }
}

/// What makes a profile unfit for this app, this identity and this device.
package enum ProfileIssue: Equatable, Sendable {
    case expired(Date)
    case expiresSoon(days: Int)
    case wrongTeam(profile: String, expected: String)
    case wrongBundle(pattern: String, bundleID: String)
    case certificateMissing
    case deviceMissing(String)
    case entitlementMissing(String)
    case notIOS
    case appStoreProfile

    /// `expiresSoon` is a warning, the rest stop the signature.
    package var blocking: Bool { if case .expiresSoon = self { return false } else { return true } }

    package var text: LocalText {
        switch self {
        case .expired(let date): return LocalText("resigner.profile.expired", ResignFormat.day(date))
        case .expiresSoon(let days): return LocalText("resigner.profile.expiresSoon", String(days))
        case .wrongTeam(let profile, let expected): return LocalText("resigner.profile.wrongTeam", profile, expected)
        case .wrongBundle(let pattern, let bundleID): return LocalText("resigner.profile.wrongBundle", pattern, bundleID)
        case .certificateMissing: return LocalText("resigner.profile.certificateMissing")
        case .deviceMissing(let device): return LocalText("resigner.profile.deviceMissing", device)
        case .entitlementMissing(let key): return LocalText("resigner.profile.entitlementMissing", key)
        case .notIOS: return LocalText("resigner.profile.notIOS")
        case .appStoreProfile: return LocalText("resigner.profile.appStore")
        }
    }
}

/// What the app, the identity and the device need from a profile.
package struct ProfileRequirement: Equatable, Sendable {
    package var bundleID: String
    package var teamID: String?
    package var certificateSHA1: String?
    package var deviceUDID: String?
    package var deviceName: String = ""
    package var entitlements: [String] = []
    package var now: Date = Date()

    package init(bundleID: String, teamID: String? = nil, certificateSHA1: String? = nil, deviceUDID: String? = nil, deviceName: String = "",
                 entitlements: [String] = [], now: Date = Date()) {
        self.bundleID = bundleID; self.teamID = teamID; self.certificateSHA1 = certificateSHA1; self.deviceUDID = deviceUDID
        self.deviceName = deviceName; self.entitlements = entitlements; self.now = now
    }
}

package enum ProfileMatcher {
    /// Days of validity below which a profile is reported as running out.
    package static let soonDays = 2

    package static func issues(_ profile: ProvisioningProfile, _ need: ProfileRequirement) -> [ProfileIssue] {
        var out: [ProfileIssue] = []
        if !profile.platforms.isEmpty, !profile.platforms.contains("iOS") { out.append(.notIOS) }
        if let expires = profile.expires {
            if expires <= need.now { out.append(.expired(expires)) }
            else {
                let days = AppSignature.daysLeft(to: expires, now: need.now)
                if days <= soonDays { out.append(.expiresSoon(days: days)) }
            }
        }
        if let team = need.teamID, !team.isEmpty, profile.teamID != team { out.append(.wrongTeam(profile: profile.teamID, expected: team)) }
        if !profile.allows(bundleID: need.bundleID) { out.append(.wrongBundle(pattern: profile.bundlePattern, bundleID: need.bundleID)) }
        if let sha = need.certificateSHA1, !sha.isEmpty, !profile.certificates.contains(sha.uppercased()) { out.append(.certificateMissing) }
        if profile.kind == .appStore { out.append(.appStoreProfile) }
        else if let udid = need.deviceUDID, !udid.isEmpty, !profile.allowsDevice(udid) {
            out.append(.deviceMissing(need.deviceName.isEmpty ? LogRedactor.short(udid) : need.deviceName))
        }
        for key in need.entitlements where !profile.grants(key) { out.append(.entitlementMissing(key)) }
        return out
    }

    /// The profiles that fit, best first: no blocking issue, then the one that lasts longest. A wildcard profile comes after an explicit one.
    package static func candidates(_ profiles: [ProvisioningProfile], _ need: ProfileRequirement) -> [ProvisioningProfile] {
        profiles.filter { !issues($0, need).contains(where: \.blocking) }
            .sorted { a, b in
                if a.isWildcard != b.isWildcard { return !a.isWildcard }
                return (a.expires ?? .distantPast) > (b.expires ?? .distantPast)
            }
    }
}

/// The entitlements a profile signature gives the app: the ones the app has now, under the new team, each one granted by the profile.
package enum EntitlementPlanner {
    package static let memoryLimit = "com.apple.developer.kernel.increased-memory-limit"

    package enum Problem: Error, Equatable, Sendable {
        /// The profile does not grant this entitlement the app has.
        case notGranted(String)
        /// The app has an entitlement whose value the Resigner cannot write back faithfully.
        case unsupported(String)
    }

    package struct Plan: Equatable, Sendable {
        package var entitlements: [String: EntitlementValue]
        /// Entitlements the app had and the signature leaves out, by the user's choice (`allowDropping`).
        package var dropped: [String]
    }

    package static func plan(current: [String: EntitlementValue], profile: ProvisioningProfile, bundleID: String,
                             allowDropping: Set<String> = []) -> Result<Plan, Problem> {
        let team = profile.teamID
        var out: [String: EntitlementValue] = [
            "application-identifier": .string(team + "." + bundleID),
            "com.apple.developer.team-identifier": .string(team),
        ]
        if case .bool(let allow)? = profile.entitlements["get-task-allow"] { out["get-task-allow"] = .bool(allow) }
        var dropped: [String] = []
        for key in current.keys.sorted() {
            switch key {
            case "application-identifier", "com.apple.developer.team-identifier", "get-task-allow": continue
            case "keychain-access-groups": out[key] = .strings([team + "." + bundleID]); continue
            default: break
            }
            let value = current[key]!
            if value == .unsupported { return .failure(.unsupported(key)) }
            if profile.grants(key) { out[key] = value; continue }
            if allowDropping.contains(key) { dropped.append(key); continue }
            return .failure(.notGranted(key))
        }
        return .success(Plan(entitlements: out, dropped: dropped))
    }

    /// The plan as an XML property list for `codesign --entitlements`.
    package static func plistData(_ entitlements: [String: EntitlementValue]) throws -> Data {
        let dict = entitlements.compactMapValues { $0.plistObject }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}

/// Dates and numbers in the core's texts, the same in every language (the date in ISO form, so a log reads the same everywhere).
package enum ResignFormat {
    package static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    package static func moment(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

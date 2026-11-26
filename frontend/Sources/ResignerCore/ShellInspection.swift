import Foundation
import NXCore

/// A game inside the built shell: one embedded `DmGame<title ID>.framework` with its manifest.
package struct EmbeddedGame: Equatable, Sendable {
    package var titleID: String
    package var name: String
    package var framework: String
    /// The file the framework lacks (`ShellInstall.missingFile`), nil when it is whole.
    package var missingFile: String?

    package init(titleID: String, name: String, framework: String, missingFile: String? = nil) {
        self.titleID = titleID; self.name = name; self.framework = framework; self.missingFile = missingFile
    }
}

/// The built `DmShell.app` on this Mac.
package struct ShellApp: Equatable, Sendable {
    package var path: String
    package var bundleID: String
    package var displayName: String
    package var version: String
    package var build: String
    package var executable: String
    package var minimumOS: String
    package var games: [EmbeddedGame]
    /// Other frameworks and dylibs in Frameworks/ (signed as they are).
    package var otherCode: [String]
    /// App extensions or nested apps: they need profiles of their own, which the profile route does not make.
    package var nestedBundles: [String]
    package var hasEmbeddedProfile: Bool

    package init(path: String, bundleID: String, displayName: String = "", version: String = "", build: String = "", executable: String = "",
                 minimumOS: String = "", games: [EmbeddedGame] = [], otherCode: [String] = [], nestedBundles: [String] = [], hasEmbeddedProfile: Bool = false) {
        self.path = path; self.bundleID = bundleID; self.displayName = displayName; self.version = version; self.build = build
        self.executable = executable; self.minimumOS = minimumOS; self.games = games; self.otherCode = otherCode
        self.nestedBundles = nestedBundles; self.hasEmbeddedProfile = hasEmbeddedProfile
    }
}

/// The launcher's cached Xcode project of the shell, which the Xcode route signs again.
package struct ShellProject: Equatable, Sendable {
    package var path: String
    package var exists: Bool
    /// The project's links into the engine (`Sources`, `Shell`, `tools`) that point at nothing: the engine tree moved or was replaced.
    package var brokenLinks: [String]
    /// Frameworks the project embeds (frameworks.txt) that are gone.
    package var missingFrameworks: [String]
    package var derivedDataExists: Bool
    /// The project asks for the shell's entitlements file (the Increased Memory Limit).
    package var requestsEntitlements: Bool

    package init(path: String, exists: Bool, brokenLinks: [String] = [], missingFrameworks: [String] = [], derivedDataExists: Bool = false,
                 requestsEntitlements: Bool = false) {
        self.path = path; self.exists = exists; self.brokenLinks = brokenLinks; self.missingFrameworks = missingFrameworks
        self.derivedDataExists = derivedDataExists; self.requestsEntitlements = requestsEntitlements
    }

    package var usable: Bool { exists && brokenLinks.isEmpty && missingFrameworks.isEmpty }
}

/// What the shell root holds, read without changing anything.
package struct ShellInspection: Equatable {
    package var root: String
    package var rootExists: Bool
    /// `shell.json` as the launcher wrote it, nil when there is none or it cannot be read.
    package var library: ShellLibrary?
    package var app: ShellApp?
    package var appPath: String
    package var project: ShellProject

    package init(root: String, rootExists: Bool, library: ShellLibrary?, app: ShellApp?, appPath: String, project: ShellProject) {
        self.root = root; self.rootExists = rootExists; self.library = library; self.app = app; self.appPath = appPath; self.project = project
    }

    /// The bundle ID to install under: the one shell.json keeps (the device's copy has it), else the built app's.
    package var bundleID: String { library?.bundleID ?? app?.bundleID ?? ShellLibrary.defaultBundleID }
    /// The team the launcher last signed with, from shell.json.
    package var team: String { library?.team ?? "" }
}

package enum ShellInspector {
    package static func inspect(root: String, configuration: String = "Release", fm: FileManager = .default) -> ShellInspection {
        var isDir: ObjCBool = false
        let rootExists = fm.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
        var library: ShellLibrary?
        if let data = fm.contents(atPath: ShellLibrary.stateFile(root: root)) { library = try? JSONDecoder().decode(ShellLibrary.self, from: data) }
        let appPath = Self.appPath(root: root, configuration: configuration)
        return ShellInspection(root: root, rootExists: rootExists, library: library, app: readApp(appPath, fm: fm), appPath: appPath,
                               project: readProject(root: root, fm: fm))
    }

    /// `ShellInstall.appPath` for Release, the same folder layout for another configuration.
    package static func appPath(root: String, configuration: String) -> String {
        configuration == "Release" ? ShellInstall.appPath(root: root)
            : ShellInstall.derivedData(root: root) + "/Build/Products/\(configuration)-iphoneos/" + ShellInstall.appName
    }

    package static func readApp(_ path: String, fm: FileManager = .default) -> ShellApp? {
        guard let data = fm.contents(atPath: path + "/Info.plist"),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        var games: [EmbeddedGame] = [], other: [String] = []
        let frameworks = path + "/Frameworks"
        for name in ((try? fm.contentsOfDirectory(atPath: frameworks)) ?? []).sorted() where !name.hasPrefix(".") {
            let item = frameworks + "/" + name
            if name.hasSuffix(".framework"), let manifest = manifest(item + "/game.manifest.json", fm: fm) {
                let titleID = manifest["title_id"] as? String ?? ShellInstall.titleID(ofFramework: name)
                games.append(EmbeddedGame(titleID: titleID, name: manifest["name"] as? String ?? "", framework: name,
                                          missingFile: ShellInstall.missingFile(inFramework: item, titleID: titleID, fm: fm)))
            } else if name.hasSuffix(".framework") || name.hasSuffix(".dylib") {
                other.append(name)
            }
        }
        var nested: [String] = []
        for folder in ["PlugIns", "Extensions", "Watch", "AppClips"] {
            for name in ((try? fm.contentsOfDirectory(atPath: path + "/" + folder)) ?? []) where !name.hasPrefix(".") {
                nested.append(folder + "/" + name)
            }
        }
        return ShellApp(path: path, bundleID: bundleID, displayName: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "",
                        version: info["CFBundleShortVersionString"] as? String ?? "", build: info["CFBundleVersion"] as? String ?? "",
                        executable: info["CFBundleExecutable"] as? String ?? "", minimumOS: info["MinimumOSVersion"] as? String ?? "",
                        games: games, otherCode: other, nestedBundles: nested.sorted(),
                        hasEmbeddedProfile: fm.fileExists(atPath: path + "/" + AppSignature.profileName))
    }

    private static func manifest(_ path: String, fm: FileManager) -> [String: Any]? {
        guard let data = fm.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    package static func readProject(root: String, fm: FileManager = .default) -> ShellProject {
        let folder = ShellInstall.projectFolder(root: root)
        let project = folder + "/" + ShellInstall.projectName
        let exists = fm.fileExists(atPath: project + "/project.pbxproj")
        var broken: [String] = []
        for link in ["Sources", "Shell", "tools"] {
            let path = folder + "/" + link
            guard let target = try? fm.destinationOfSymbolicLink(atPath: path) else {
                if exists && !fm.fileExists(atPath: path) { broken.append(link) }
                continue
            }
            let resolved = target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)
            if !fm.fileExists(atPath: resolved) { broken.append(link) }
        }
        var missing: [String] = []
        if let list = try? String(contentsOfFile: folder + "/frameworks.txt", encoding: .utf8) {
            for row in list.split(separator: "\n") {
                let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
                if fields.count >= 2, !fm.fileExists(atPath: String(fields[1])) { missing.append(String(fields[1])) }
            }
        }
        let xcconfig = (try? String(contentsOfFile: folder + "/Gen/dm.xcconfig", encoding: .utf8)) ?? ""
        return ShellProject(path: project, exists: exists, brokenLinks: broken, missingFrameworks: missing,
                            derivedDataExists: fm.fileExists(atPath: ShellInstall.derivedData(root: root)),
                            requestsEntitlements: xcconfig.contains("CODE_SIGN_ENTITLEMENTS"))
    }
}

/// How the shell is signed again.
package enum SigningRoute: String, CaseIterable, Equatable, Sendable, Codable {
    /// The Xcode route when the launcher's project is usable, the profile route otherwise.
    case automatic
    /// xcodebuild with automatic signing on the launcher's cached project (ShellInstall.buildCommand).
    case xcode
    /// codesign with a chosen identity and an installed provisioning profile, on a copy of the built app.
    case profile

    package func resolved(projectUsable: Bool) -> SigningRoute {
        switch self {
        case .automatic: return projectUsable ? .xcode : .profile
        case .xcode, .profile: return self
        }
    }
}

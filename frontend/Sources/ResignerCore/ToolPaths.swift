import Foundation

/// Where the Resigner's tools are, and the environment they start in. Every tool is a fixed absolute path in the system: nothing is
/// looked up on a PATH the user controls. Xcode's tools go through `xcrun`, which follows `DEVELOPER_DIR` when an Xcode other than
/// the selected one is chosen in Settings, so the system's own choice (`xcode-select`) is never changed for that.
package struct ToolPaths: Equatable, Sendable {
    package var xcrun = "/usr/bin/xcrun"
    package var codesign = "/usr/bin/codesign"
    package var security = "/usr/bin/security"
    package var xcodeSelect = "/usr/bin/xcode-select"
    package var openssl = "/usr/bin/openssl"
    package var swVers = "/usr/bin/sw_vers"
    package var ditto = "/usr/bin/ditto"
    /// `<Xcode>.app/Contents/Developer` of the Xcode chosen in Settings. nil: the one `xcode-select -p` names.
    package var developerDir: String? = nil

    package init(developerDir: String? = nil) { self.developerDir = developerDir }

    /// The environment of every tool: a fixed PATH of system folders, the user's home and name, an English locale (the output is
    /// parsed), and `DEVELOPER_DIR` for a chosen Xcode.
    package func environment(home: String = NSHomeDirectory(), user: String = NSUserName()) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "USER": user, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        if let developerDir, !developerDir.isEmpty { env["DEVELOPER_DIR"] = developerDir }
        return env
    }

    /// The Xcode.app a developer folder belongs to (`/Applications/Xcode.app/Contents/Developer` -> `/Applications/Xcode.app`),
    /// nil for a folder outside an app (the Command Line Tools).
    package static func xcodeApp(ofDeveloperDir dir: String) -> String? {
        guard let range = dir.range(of: ".app/Contents/Developer") else { return nil }
        return String(dir[..<range.lowerBound]) + ".app"
    }
}

/// A dotted version number ("26.1.2"), compared part by part, a missing part counting as 0.
package struct VersionNumber: Comparable, Equatable, Sendable, CustomStringConvertible {
    package let parts: [Int]

    package init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: { !$0.isNumber && $0 != "." }).first else { return nil }
        let parts = first.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    package var description: String { parts.map(String.init).joined(separator: ".") }

    package static func < (a: VersionNumber, b: VersionNumber) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    package static func == (a: VersionNumber, b: VersionNumber) -> Bool { !(a < b) && !(b < a) }
}

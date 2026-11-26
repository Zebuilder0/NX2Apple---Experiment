import Foundation

/// Takes what identifies a person or a device out of a log line before it is kept, shown or exported. The log never receives a
/// password or a key in the first place (a `.p12` password goes from its field to the Security framework only), so this is about
/// what the tools print: paths in the home folder, the user name, email addresses (an Apple ID), certificate holders' names, device
/// identifiers and fingerprints. A team ID stays: it is what a signing failure is about and is not personal.
package struct LogRedactor: Sendable {
    package var home: String
    package var user: String
    /// Names learned while the app runs (a team's name, a certificate holder's name) that are hidden wherever they appear.
    package var names: [String]

    package init(home: String = NSHomeDirectory(), user: String = NSUserName(), names: [String] = []) {
        self.home = home; self.user = user; self.names = names
    }

    private static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let certificate = try! NSRegularExpression(
        pattern: #"(Apple Development|iPhone Developer|Apple Distribution|iPhone Distribution|Developer ID Application|Mac Developer): ([^"()\n]+?) \(([A-Z0-9]{10})\)"#)
    /// A device's UDID (00008110-001A2B3C4D5E6F7A, or 40 hex digits on older devices), a CoreDevice identifier or a profile's UUID
    /// (8-4-4-4-12), and 40-digit fingerprints. All but the last four characters go.
    private static let identifiers = try! NSRegularExpression(
        pattern: #"\b(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{40})\b"#)

    package func redact(_ text: String) -> String {
        var out = text
        if home.count > 1 {
            out = out.replacingOccurrences(of: home + "/", with: "~/")
            if out.hasSuffix(home) { out = String(out.dropLast(home.count)) + "~" }
            out = out.replacingOccurrences(of: home + " ", with: "~ ").replacingOccurrences(of: home + "\"", with: "~\"")
        }
        if user.count >= 2 { out = out.replacingOccurrences(of: "/Users/" + user, with: "/Users/<user>") }
        out = Self.replace(Self.certificate, in: out, template: "$1: <name> ($3)")
        out = Self.replace(Self.email, in: out, template: "<email>")
        for name in names.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: name, with: "<name>")
        }
        if user.count >= 4 { out = Self.replaceWord(user, in: out, with: "<user>") }
        out = Self.maskIdentifiers(out)
        return out
    }

    private static func replace(_ re: NSRegularExpression, in text: String, template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    private static func replaceWord(_ word: String, in text: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let re = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])") else { return text }
        return replace(re, in: text, template: NSRegularExpression.escapedTemplate(for: replacement))
    }

    private static func maskIdentifiers(_ text: String) -> String {
        let ns = text as NSString
        var out = "", last = 0
        for match in identifiers.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let found = ns.substring(with: match.range)
            out += "…" + found.suffix(4)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The last four characters of an identifier, as the redacted log shows it.
    package static func short(_ identifier: String) -> String { identifier.count > 4 ? "…" + identifier.suffix(4) : identifier }
}

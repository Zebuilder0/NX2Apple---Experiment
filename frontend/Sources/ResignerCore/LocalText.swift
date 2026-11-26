import Foundation

/// A text for the interface as a key of `frontend/l10n/*.json` and its arguments. The core never holds a finished sentence: the
/// store or the view resolves it in the chosen language (`Localizer.t`). Arguments fill `%@`, `%1$@`, `%2$@` and so on, and `%%` is a
/// percent sign. Only strings are passed (a number is formatted by the caller), so the result is the same on every platform.
package struct LocalText: Equatable, Sendable, CustomStringConvertible {
    package let key: String
    package let args: [String]

    package init(_ key: String, _ args: String...) { self.key = key; self.args = args }
    package init(_ key: String, args: [String]) { self.key = key; self.args = args }

    package func resolve(_ t: (String) -> String) -> String { Self.format(t(key), args) }

    /// The key and its arguments, for a test failure or a log line written without a language.
    package var description: String { args.isEmpty ? key : key + " " + args.joined(separator: " | ") }

    /// `%@` takes the next argument, `%n$@` the n-th, `%%` is a percent sign. Anything else after a percent sign stays as it is.
    package static func format(_ format: String, _ args: [String]) -> String {
        guard format.contains("%") else { return format }
        var out = "", next = 0
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "%", i + 1 < chars.count else { out.append(c); i += 1; continue }
            if chars[i + 1] == "%" { out.append("%"); i += 2; continue }
            if chars[i + 1] == "@" {
                out += next < args.count ? args[next] : ""
                next += 1; i += 2; continue
            }
            // %n$@
            var j = i + 1, digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if !digits.isEmpty, j + 1 < chars.count, chars[j] == "$", chars[j + 1] == "@", let n = Int(digits), n >= 1 {
                out += n - 1 < args.count ? args[n - 1] : ""
                i = j + 2; continue
            }
            out.append(c); i += 1
        }
        return out
    }
}

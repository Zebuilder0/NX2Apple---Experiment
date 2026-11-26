import Foundation

/// The text the diagnostics export writes: the app and system versions, every dependency row and the log, redacted. It holds no
/// private key, certificate, profile file or password, because none of them is ever part of a row or the log: the export cannot
/// leak what the app never wrote down. The redaction runs over the whole text once more anyway.
package enum DiagnosticReport {
    package static func text(appVersion: String, macOS: String, xcode: String, route: SigningRoute, items: [DependencyItem], log: String,
                             now: Date = Date(), t: (String) -> String, redactor: LogRedactor) -> String {
        var lines: [String] = [
            "NX2Apple Resigner diagnostics",
            "created: " + ResignFormat.moment(now),
            "resigner: " + appVersion,
            "macOS: " + (macOS.isEmpty ? "-" : macOS),
            "Xcode: " + (xcode.isEmpty ? "-" : xcode),
            "route: " + route.rawValue,
            "",
            "== dependencies ==",
        ]
        for category in DependencyCategory.allCases {
            let rows = items.filter { $0.category == category }
            guard !rows.isEmpty else { continue }
            lines.append("")
            lines.append("[" + category.rawValue + "]")
            for item in rows {
                var line = "- " + item.name.resolve(t) + ": " + item.status.rawValue
                if !item.version.isEmpty { line += " (" + item.version + ")" }
                lines.append(line)
                lines.append("  " + item.explanation.resolve(t))
                if let fix = item.remediation, item.status.isProblem { lines.append("  " + fix.resolve(t)) }
            }
        }
        lines += ["", "== log ==", log]
        return redactor.redact(lines.joined(separator: "\n")) + "\n"
    }

    /// The export's file name: the date and time, nothing personal.
    package static func fileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "NX2Apple-Resigner-diagnostics-" + f.string(from: now) + ".txt"
    }
}

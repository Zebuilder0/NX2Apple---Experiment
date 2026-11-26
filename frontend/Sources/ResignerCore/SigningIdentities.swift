import Foundation
import NXCore

/// One identity `security find-identity -p codesigning` lists: a certificate with its private key in a keychain. `problem` is the
/// reason the system gives when the identity cannot sign (CSSMERR_TP_CERT_EXPIRED, CSSMERR_TP_NOT_TRUSTED, ...), nil when it can.
package struct IdentityRecord: Equatable, Sendable, Identifiable {
    package let sha1: String
    package let name: String
    package let problem: String?

    package init(sha1: String, name: String, problem: String? = nil) { self.sha1 = sha1.uppercased(); self.name = name; self.problem = problem }

    package var id: String { sha1 }
    package var valid: Bool { problem == nil }
    package var kind: CertificateKind { CertificateKind(name: name) }
}

package enum CertificateKind: String, Equatable, Sendable {
    case development, distribution, other

    package init(name: String) {
        if name.hasPrefix("Apple Development:") || name.hasPrefix("iPhone Developer:") { self = .development }
        else if name.hasPrefix("Apple Distribution:") || name.hasPrefix("iPhone Distribution:") { self = .distribution }
        else { self = .other }
    }

    /// The names `security find-certificate -c` is asked for: the iOS signing certificates, current and older names.
    package static let searchNames = ["Apple Development", "iPhone Developer", "Apple Distribution", "iPhone Distribution"]
}

/// A signing certificate in a keychain, with or without its private key.
package struct CertificateRecord: Equatable, Sendable, Identifiable {
    package let sha1: String
    package let commonName: String
    package let team: String
    package let notBefore: Date?
    package let notAfter: Date?
    /// The identity's entry when `find-identity` lists this certificate (its private key is in a keychain), nil when it does not.
    package var identity: IdentityRecord?

    package init(sha1: String, commonName: String, team: String, notBefore: Date? = nil, notAfter: Date? = nil, identity: IdentityRecord? = nil) {
        self.sha1 = sha1.uppercased(); self.commonName = commonName; self.team = team; self.notBefore = notBefore; self.notAfter = notAfter
        self.identity = identity
    }

    package var id: String { sha1 }
    package var hasPrivateKey: Bool { identity != nil }
    package var kind: CertificateKind { CertificateKind(name: commonName) }
    package func expired(now: Date) -> Bool { notAfter.map { $0 < now } ?? false }
}

/// The parsers of `security` and `openssl` output, as pure functions.
package enum SigningIdentities {
    /// The "Matching identities" part of `security find-identity -p codesigning` (no `-v`): every identity, valid or not, once each.
    /// The "Valid identities only" part repeats the valid ones and is not read.
    package static func parseIdentities(_ text: String) -> [IdentityRecord] {
        let line = try! NSRegularExpression(pattern: #"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.+)"(?:\s+\(([^()]+)\))?\s*$"#)
        var found: [IdentityRecord] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            if s.contains("Valid identities only") { break }
            let ns = s as NSString
            guard let m = line.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            let sha = ns.substring(with: m.range(at: 1)).uppercased()
            let name = ns.substring(with: m.range(at: 2))
            let problem = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            if !found.contains(where: { $0.sha1 == sha }) { found.append(IdentityRecord(sha1: sha, name: name, problem: problem)) }
        }
        return found
    }

    /// The PEM blocks of `security find-certificate -a -p` (with or without `-Z`), each with the SHA-1 of its DER, computed here.
    package static func parsePEMs(_ text: String) -> [(sha1: String, pem: String)] {
        var out: [(String, String)] = [], block: [String] = [], inside = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s == "-----BEGIN CERTIFICATE-----" { inside = true; block = [s]; continue }
            guard inside else { continue }
            block.append(s)
            if s == "-----END CERTIFICATE-----" {
                inside = false
                let pem = block.joined(separator: "\n") + "\n"
                if let der = der(fromPEM: pem) { out.append((SHA1.hex(der), pem)) }
            }
        }
        return out
    }

    package static func der(fromPEM pem: String) -> Data? {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }

    /// `openssl x509 -noout -subject -startdate -enddate`: the common name, the team (OU) and the dates. Both the older LibreSSL form
    /// (`subject= /UID=.../CN=Apple Development: A B (X)/OU=TEAM/...`) and the newer one (`subject=UID = ..., CN = ..., OU = ...`).
    package static func parseCertificateText(_ text: String) -> (commonName: String, team: String, notBefore: Date?, notAfter: Date?) {
        var cn = "", team = "", before: Date?, after: Date?
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("subject") {
                cn = field("CN", in: s) ?? ""
                team = DeviceTools.team(fromSubject: s) ?? field("OU", in: s) ?? ""
            } else if s.hasPrefix("notBefore=") {
                before = opensslDate(String(s.dropFirst("notBefore=".count)))
            } else if s.hasPrefix("notAfter=") {
                after = opensslDate(String(s.dropFirst("notAfter=".count)))
            }
        }
        return (cn, team, before, after)
    }

    private static func field(_ name: String, in subject: String) -> String? {
        // "/CN=value/OU=" or "CN = value, OU = ": the value runs to the next "/XX=" or ", XX =" or the end
        let pattern = "(?:^|[/,]|subject=)\\s*" + name + "\\s*=\\s*(.+?)(?=\\s*(?:/[A-Za-z]+=|,\\s*[A-Za-z]+\\s*=)|\\s*$)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = subject as NSString
        guard let m = re.firstMatch(in: subject, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    /// "Nov 26 12:00:00 2027 GMT" or "Nov  6 12:00:00 2027 GMT".
    package static func opensslDate(_ text: String) -> Date? {
        let collapsed = text.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        return f.date(from: collapsed)
    }

    /// Certificates joined with the identities: a certificate with no identity has no private key on this Mac.
    package static func join(certificates: [CertificateRecord], identities: [IdentityRecord]) -> [CertificateRecord] {
        var out = certificates.map { c -> CertificateRecord in
            var c = c
            c.identity = identities.first { $0.sha1 == c.sha1 }
            return c
        }
        // An identity whose certificate the search names did not find (a renamed one) still counts
        for identity in identities where !out.contains(where: { $0.sha1 == identity.sha1 }) {
            let team = identity.name.range(of: #"\(([A-Z0-9]{10})\)$"#, options: .regularExpression)
                .map { String(identity.name[$0].dropFirst().dropLast()) } ?? ""
            out.append(CertificateRecord(sha1: identity.sha1, commonName: identity.name, team: team, identity: identity))
        }
        return out
    }

    /// The teams the identities on this Mac can sign for, in the launcher's form (DeviceTools), one per team.
    package static func teams(_ certificates: [CertificateRecord]) -> [SigningTeam] {
        var seen = Set<String>()
        return certificates.compactMap { c in
            guard c.kind == .development, let identity = c.identity, identity.valid, !c.team.isEmpty, seen.insert(c.team).inserted else { return nil }
            return SigningTeam(id: c.team, identity: identity.name)
        }
    }
}

/// What a trial signature with an identity said.
package enum TestSignResult: Equatable, Sendable {
    case signed
    /// The key is in the keychain, but codesign may not use it now: a locked keychain, or access to the key was refused.
    case keyAccessDenied(String)
    /// The keychain has the certificate but not its private key.
    case noPrivateKey(String)
    /// The chain to Apple's root is not there (the Worldwide Developer Relations intermediate is missing) or is not trusted.
    case notTrusted(String)
    case failed(String)

    /// Sorts codesign's own words.
    package static func classify(status: Int32, output: String) -> TestSignResult {
        if status == 0 { return .signed }
        let line = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        if output.contains("errSecInternalComponent") || output.contains("User interaction is not allowed") || output.contains("errSecAuthFailed") {
            return .keyAccessDenied(line)
        }
        if output.contains("could not be found in the keychain") || output.contains("no identity found") { return .noPrivateKey(line) }
        if output.contains("CSSMERR_TP_NOT_TRUSTED") || output.contains("unable to build chain") || output.contains("not trusted") {
            return .notTrusted(line)
        }
        return .failed(line)
    }
}

/// Reads the identities and certificates through `security` and `openssl`, and signs a scratch file to prove an identity works.
package struct IdentityInspector {
    package var runner: ProcessRunner
    package var tools: ToolPaths

    package init(runner: ProcessRunner = SystemProcessRunner(), tools: ToolPaths = ToolPaths()) { self.runner = runner; self.tools = tools }

    package func identities() -> [IdentityRecord] {
        let r = runner.capture(ProcessLaunch(executable: tools.security, arguments: ["find-identity", "-p", "codesigning"],
                                             environment: tools.environment(), timeout: 30))
        return r.ok ? SigningIdentities.parseIdentities(r.out) : []
    }

    package func certificates() -> [CertificateRecord] {
        var seen = Set<String>(), out: [CertificateRecord] = []
        for name in CertificateKind.searchNames {
            let r = runner.capture(ProcessLaunch(executable: tools.security, arguments: ["find-certificate", "-a", "-Z", "-p", "-c", name],
                                                 environment: tools.environment(), timeout: 30))
            guard r.ok else { continue }
            for (sha, pem) in SigningIdentities.parsePEMs(r.out) where seen.insert(sha).inserted {
                let text = runner.capture(ProcessLaunch(executable: tools.openssl, arguments: ["x509", "-noout", "-subject", "-startdate", "-enddate"],
                                                        environment: tools.environment(), timeout: 15, input: pem))
                let parsed = SigningIdentities.parseCertificateText(text.ok ? text.out : "")
                out.append(CertificateRecord(sha1: sha, commonName: parsed.commonName, team: parsed.team,
                                             notBefore: parsed.notBefore, notAfter: parsed.notAfter))
            }
        }
        return out
    }

    /// Signs a small scratch file with the identity (its SHA-1) and verifies it. macOS may ask once whether codesign may use the
    /// key: the answer belongs to the user, so the deadline is long.
    package func testSign(sha1: String, temporaryFolder: String = NSTemporaryDirectory()) -> TestSignResult {
        let fm = FileManager.default
        let dir = (temporaryFolder as NSString).appendingPathComponent("nx2apple-resigner-test-" + UUID().uuidString)
        defer { try? fm.removeItem(atPath: dir) }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return .failed(error.localizedDescription) }
        let file = (dir as NSString).appendingPathComponent("probe")
        guard fm.createFile(atPath: file, contents: Data("NX2Apple Resigner signing check\n".utf8)) else { return .failed(file) }
        let sign = runner.capture(ProcessLaunch(executable: tools.codesign, arguments: ["--force", "--sign", sha1, "--timestamp=none", file],
                                                environment: tools.environment(), mergesErrors: true, timeout: 120))
        if !sign.started { return .failed(sign.out) }
        if sign.timedOut { return .keyAccessDenied("codesign timed out") }
        let result = TestSignResult.classify(status: sign.status, output: sign.out)
        guard result == .signed else { return result }
        let verify = runner.capture(ProcessLaunch(executable: tools.codesign, arguments: ["--verify", file],
                                                  environment: tools.environment(), mergesErrors: true, timeout: 30))
        return verify.ok ? .signed : TestSignResult.classify(status: verify.status == 0 ? 1 : verify.status, output: verify.out)
    }
}

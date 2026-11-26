import Foundation
import Security

/// Imports a `.p12` (a certificate with its private key) into the login keychain with the Security framework. The password goes
/// from the secure field to `SecPKCS12Import` and nowhere else: not to a log, a file, the defaults or a command line (where other
/// processes could read it, as `security import -P` would put it).
///
/// On macOS `SecPKCS12Import` may already put the items in the default keychain. `SecItemAdd` then reports a duplicate, which
/// counts as imported. codesign asks once whether it may use the new key: Always Allow saves the prompts that follow.
enum P12Import {
    enum Outcome: Equatable {
        case imported(identities: Int)
        case wrongPassword
        case noIdentity
        case failed(String)
    }

    static func run(file: URL, password: String) -> Outcome {
        guard let data = try? Data(contentsOf: file) else { return .failed(file.lastPathComponent) }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure { return .wrongPassword }
        guard status == errSecSuccess, let list = items as? [[String: Any]] else { return .failed(message(status)) }
        var count = 0
        for entry in list {
            guard let value = entry[kSecImportItemIdentity as String] else { continue }
            let identity = value as! SecIdentity   // the dictionary's value for this key is a SecIdentity
            let add = SecItemAdd([kSecValueRef as String: identity] as CFDictionary, nil)
            guard add == errSecSuccess || add == errSecDuplicateItem else { return .failed(message(add)) }
            count += 1
        }
        return count == 0 ? .noIdentity : .imported(identities: count)
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

import Foundation
import Security

/// What certificate signed the running app. Developer ID builds get stable identities (Keychain grants and
/// permission grants survive rebuilds); dev builds fall back to file-based secrets.
enum Signing {
    static let isDeveloperID: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else { return false }
        var name: CFString?
        SecCertificateCopyCommonName(leaf, &name)
        return (name as String? ?? "").hasPrefix("Developer ID Application")
    }()

    static var description: String { isDeveloperID ? "Developer ID" : "development" }
}

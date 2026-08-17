import Foundation
import Security

/// How this copy of the app is signed.
///
/// This matters for one specific, very confusing failure: macOS keys an Accessibility grant to the
/// app's code signature. An ad-hoc signature changes on every single build, so after a rebuild the
/// row still sits in System Settings looking switched on while `AXIsProcessTrusted()` returns false.
/// Knowing we are ad-hoc signed lets the UI explain that instead of just repeating "not granted".
enum CodeSigningInfo {

    /// True when the app has no real signing certificate behind it — ad-hoc or unsigned.
    static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return true
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any]
        else { return true }

        // A real identity leaves a certificate chain behind; ad-hoc signing does not.
        let certificates = details[kSecCodeInfoCertificates as String] as? [Any]
        return (certificates?.isEmpty ?? true)
    }
}

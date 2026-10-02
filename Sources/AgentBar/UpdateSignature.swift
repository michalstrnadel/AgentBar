import Foundation
import Security

/// Whether a downloaded update was signed by whoever signed the copy that is running.
///
/// Releases carry the project's own certificate, not Apple's, so "is it signed" says
/// nothing — anyone can sign anything. What does mean something is the running app's
/// *designated requirement*: for a release that is its bundle identifier plus the
/// hash of the certificate that signed it, so a staged bundle that satisfies it was
/// signed with the same key. That is the check an update installed without a click
/// has to pass; nobody is looking at it to notice anything odd.
enum UpdateSignature {
    enum Running: Equatable {
        /// Signed with a real certificate; updates must satisfy this requirement.
        case signed(SecRequirement)
        /// Ad-hoc (`codesign -s -`), as dev builds without the local identity are:
        /// the designated requirement is a cdhash, which no other build can ever
        /// match, so there is nothing an update could be checked against.
        case adHoc
        case unsigned
    }

    /// The signature of the bundle at `url` — by default the one this process was
    /// launched from.
    static func running(_ url: URL = Bundle.main.bundleURL) -> Running {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unsigned }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adHoc }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return .unsigned }
        // Belt and braces: a requirement that is only a cdhash pins one exact build,
        // which is what ad-hoc means whatever the flags said.
        var text: CFString?
        if SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
           let text = text as String?, text.hasPrefix("cdhash") {
            return .adHoc
        }
        return .signed(requirement)
    }

    /// nil when `staged` is validly signed — every architecture, strict — and
    /// satisfies `requirement`; otherwise a reason for Console.
    static func check(_ staged: URL, against requirement: SecRequirement) -> String? {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(staged as CFURL, [], &code)
        guard created == errSecSuccess, let code else {
            return "no code object for \(staged.lastPathComponent) (OSStatus \(created))"
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let result = SecStaticCodeCheckValidity(code, flags, requirement)
        guard result == errSecSuccess else {
            let why = SecCopyErrorMessageString(result, nil) as String? ?? "unknown"
            return "signature does not satisfy the running app's requirement: \(why) (OSStatus \(result))"
        }
        return nil
    }

    /// What every install checks right before the swap. An ad-hoc or unsigned
    /// running copy has nothing to compare against, so it passes the staged bundle
    /// through as before this check existed — which is why such a copy never
    /// installs anything without a click (`UpdateChecker.autoInstallSupported`).
    static func verifyAgainstRunning(_ staged: URL) -> String? {
        guard case .signed(let requirement) = running() else { return nil }
        return check(staged, against: requirement)
    }
}

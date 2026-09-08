import Foundation
import Security

struct SignedBootApplicationScope: BootApplicationScope {
    func currentReleaseID() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            throw BootCustodyError.applicationNotPermitted
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"io.darkbloom.provider\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw BootCustodyError.applicationNotPermitted
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw BootCustodyError.applicationNotPermitted
        }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let flags = info[kSecCodeInfoFlags as String] as? UInt32,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let executable = info[kSecCodeInfoMainExecutable as String] as? URL,
              let hash = info[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
            throw BootCustodyError.applicationNotPermitted
        }
        try BootApplicationPolicy.validate(identifier: identifier, teamID: team,
                                            hardenedRuntime: flags & 0x10000 != 0, // CS_RUNTIME (Security/CSCommon.h)
                                            entitlements: entitlements, executable: executable,
                                            bundle: Bundle.main.bundleURL, bundleExecutable: Bundle.main.executableURL)
        return "cdhash:" + hash.map { String(format: "%02x", $0) }.joined()
    }
}

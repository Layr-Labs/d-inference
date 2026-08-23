import Foundation
import SandboxRuntime
import Security

enum LumeRuntimeCodeSignature {
    static let teamID = "SLDQ2GJ6TL"
    static let signingIdentifier = "io.darkbloom.sandbox.lume"
    static let designatedRequirement =
        "anchor apple generic and identifier \"\(signingIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(teamID)\""

    static func validate(
        executable: URL,
        policy: LumeRuntimeTrustPolicy
    ) throws {
        guard case .production = policy else {
            return
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executable as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
            let staticCode
        else {
            throw unsupported("Lume production signature cannot be inspected")
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            designatedRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
            let requirement
        else {
            throw unsupported("Lume production requirement cannot be created")
        }

        let status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        )
        guard status == errSecSuccess else {
            throw unsupported(
                "Lume does not satisfy the Darkbloom production signature"
            )
        }
    }

    private static func unsupported(_ message: String) -> SandboxRuntimeError {
        .unsupported(message)
    }
}

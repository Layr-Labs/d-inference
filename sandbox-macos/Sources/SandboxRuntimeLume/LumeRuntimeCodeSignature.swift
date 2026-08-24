import Foundation
import SandboxRuntime
import Security

enum LumeRuntimeCodeSignature {
    static let teamID = "SLDQ2GJ6TL"
    static let signingIdentifier = "io.darkbloom.sandbox.lume"
    static let provenanceSigningIdentifier =
        "io.darkbloom.sandbox.lume.provenance"
    static let designatedRequirement =
        "anchor apple generic and identifier \"\(signingIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(teamID)\""
    static let provenanceDesignatedRequirement =
        "anchor apple generic and identifier \"\(provenanceSigningIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(teamID)\""

    static func validate(
        executable: URL,
        provenance: URL,
        policy: LumeRuntimeTrustPolicy
    ) throws {
        guard case .production = policy else {
            return
        }

        try validate(
            executable,
            requirement: designatedRequirement,
            subject: "Lume"
        )
        try validate(
            provenance,
            requirement: provenanceDesignatedRequirement,
            subject: "Lume provenance"
        )
    }

    private static func validate(
        _ url: URL,
        requirement requirementString: String,
        subject: String
    ) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
            let staticCode
        else {
            throw unsupported(
                "\(subject) production signature cannot be inspected"
            )
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
            let requirement
        else {
            throw unsupported(
                "\(subject) production requirement cannot be created"
            )
        }

        let status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        )
        guard status == errSecSuccess else {
            throw unsupported(
                "\(subject) does not satisfy the Darkbloom production signature"
            )
        }
    }

    private static func unsupported(_ message: String) -> SandboxRuntimeError {
        .unsupported(message)
    }
}

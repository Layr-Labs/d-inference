import Darwin
import Foundation
import Security

/// A connected peer whose running code satisfied an add-on identity.
struct AddonPeer: Sendable, Equatable {
    let identifier: String
}

/// Which signed code may hold the provider. The kernel audit token from the
/// socket (including its pidversion), not a peer-supplied PID or path, selects
/// the running code. Same-UID coordination is not a security boundary against
/// the user; the signature check keeps other same-UID programs from holding
/// the Mac.
struct AddonPeerPolicy: Sendable {
    struct Identity: Sendable, Equatable {
        let identifier: String
        let teamID: String
        let requirement: String
    }

    /// The production sandbox add-on: Developer ID Application signed by the
    /// Darkbloom team.
    static let sandbox = Identity(
        identifier: "io.darkbloom.sandbox",
        teamID: "SLDQ2GJ6TL",
        requirement: "anchor apple generic and identifier \"io.darkbloom.sandbox\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\"")

    /// DEBUG builds only: one extra `TEAMID:identifier` identity, for example
    /// `P7373SVQX6:io.darkbloom-test.sandbox`. Release builds never read it.
    static let developmentIdentityVariable = "DARKBLOOM_ADDON_DEV_IDENTITY"

    let identities: [Identity]

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> AddonPeerPolicy {
        var identities = [sandbox]
        #if DEBUG
        if let extra = developmentIdentity(environment[developmentIdentityVariable]) { identities.append(extra) }
        #endif
        return AddonPeerPolicy(identities: identities)
    }

    #if DEBUG
    static func developmentIdentity(_ value: String?) -> Identity? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].count == 10,
              parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              AddonIPC.isBundleIdentifier(parts[1]) else { return nil }
        return Identity(identifier: parts[1], teamID: parts[0],
            requirement: "anchor apple generic and identifier \"\(parts[1])\" and certificate leaf[subject.OU] = \"\(parts[0])\"")
    }
    #endif

    /// Same effective UID, then the running code must satisfy an identity's
    /// requirement, carry its team and identifier, and use the hardened runtime.
    func authenticate(_ token: audit_token_t) -> AddonPeer? {
        guard audit_token_to_euid(token) == geteuid() else { return nil }
        var token = token
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        return identities.first { Self.satisfies(code, $0) }.map { AddonPeer(identifier: $0.identifier) }
    }

    static func satisfies(_ code: SecCode, _ identity: Identity) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(identity.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoTeamIdentifier as String] as? String == identity.teamID,
              values[kSecCodeInfoIdentifier as String] as? String == identity.identifier,
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    /// The peer's audit token as the kernel recorded it at connect time.
    static func peerToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout<audit_token_t>.size else { return nil }
        return token
    }
}

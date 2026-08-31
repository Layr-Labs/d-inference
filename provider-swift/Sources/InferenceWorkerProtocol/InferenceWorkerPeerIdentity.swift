import Foundation
import InferenceWorkerSecurityShim
import Security

public enum InferenceWorkerPeerRole: Sendable {
    case host
    case worker

    public var bundleIdentifier: String {
        switch self {
        case .host: InferenceWorkerContract.hostBundleIdentifier
        case .worker: InferenceWorkerContract.workerBundleIdentifier
        }
    }

    public var designatedRequirement: String {
        switch self {
        case .host: InferenceWorkerContract.hostDesignatedRequirement
        case .worker: InferenceWorkerContract.workerDesignatedRequirement
        }
    }
}

public enum InferenceWorkerPeerIdentityError: Error, Equatable, Sendable {
    case auditTokenUnavailable
    case codeLookupFailed(OSStatus)
    case requirementCreationFailed(OSStatus)
    case requirementRejected(OSStatus)
    case signingInformationFailed(OSStatus)
    case identifierMismatch
    case teamIdentifierMismatch
}

public enum InferenceWorkerPeerIdentity {
    public static func validate(connection: NSXPCConnection, expected: InferenceWorkerPeerRole) throws {
        var token = audit_token_t()
        guard DBInferenceWorkerCopyAuditToken(connection, &token) else {
            throw InferenceWorkerPeerIdentityError.auditTokenUnavailable
        }
        let auditData = withUnsafeBytes(of: &token) { Data($0) }

        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditData as CFData] as CFDictionary
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard lookup == errSecSuccess, let guest else {
            throw InferenceWorkerPeerIdentityError.codeLookupFailed(lookup)
        }
        try validate(code: guest, expected: expected)
    }

    public static func validateCurrentProcess(expected: InferenceWorkerPeerRole) throws {
        var current: SecCode?
        let status = SecCodeCopySelf([], &current)
        guard status == errSecSuccess, let current else {
            throw InferenceWorkerPeerIdentityError.codeLookupFailed(status)
        }
        try validate(code: current, expected: expected)
    }

    private static func validate(code: SecCode, expected: InferenceWorkerPeerRole) throws {
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            expected.designatedRequirement as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw InferenceWorkerPeerIdentityError.requirementCreationFailed(requirementStatus)
        }
        let validity = SecCodeCheckValidity(code, [], requirement)
        guard validity == errSecSuccess else {
            throw InferenceWorkerPeerIdentityError.requirementRejected(validity)
        }
    }
}

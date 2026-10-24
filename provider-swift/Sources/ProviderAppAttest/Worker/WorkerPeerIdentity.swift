import CryptoKit
import Darwin
import Foundation
import Security

struct WorkerAuditIdentity: Equatable, Sendable {
    let bytes: Data
    let pid: pid_t
    let uid: uid_t

    init(_ token: audit_token_t) {
        var token = token
        bytes = withUnsafeBytes(of: &token) { Data($0) }
        pid = audit_token_to_pid(token)
        uid = audit_token_to_euid(token)
    }

    static func current() throws -> Self {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS,
              Int(count) * MemoryLayout<integer_t>.size == MemoryLayout<audit_token_t>.size else {
            throw AppAttestWorkerError.unauthenticatedPeer
        }
        return Self(token)
    }

    static func peer(_ socket: WorkerDescriptor) throws -> Self {
        var token = audit_token_t()
        var count = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket.fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &count) == 0,
              count == MemoryLayout<audit_token_t>.size else { throw AppAttestWorkerError.unauthenticatedPeer }
        return Self(token)
    }

    func code() throws -> SecCode {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: bytes] as CFDictionary, [], &code) == errSecSuccess,
              let code else { throw AppAttestWorkerError.unauthenticatedPeer }
        return code
    }
}

/// The native audit token (including pidversion), not a peer-supplied PID/path,
/// selects the running code. Full file equality additionally pins signed bytes;
/// Code Signing Services validates their relationship to the running image.
struct WorkerCodeIdentity: Sendable, Equatable {
    static let teamID = "SLDQ2GJ6TL"
    static let signingID = "io.darkbloom.provider"
    static let requirement = "anchor apple generic and identifier \"io.darkbloom.provider\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    let cdHash: Data
    let binaryHash: String
    let executable: URL

    static func current() throws -> Self {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw AppAttestWorkerError.unauthenticatedPeer
        }
        return try inspect(code)
    }

    static func inspect(_ code: SecCode) throws -> Self {
        let information = try validate(code)
        guard let cdHash = information[kSecCodeInfoUnique as String] as? Data, !cdHash.isEmpty,
              let executable = information[kSecCodeInfoMainExecutable as String] as? URL else {
            throw AppAttestWorkerError.unauthenticatedPeer
        }
        let file = try FileHandle(forReadingFrom: executable)
        defer { try? file.close() }
        var hasher = SHA256()
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { hasher.update(data: block) }
        _ = try validate(code)
        return Self(cdHash: cdHash, binaryHash: hasher.finalize().map { String(format: "%02x", $0) }.joined(), executable: executable)
    }

    func authenticate(_ peer: WorkerAuditIdentity, expectedPID: pid_t,
                      expectedAudit: Data? = nil, fullMeasurement: Bool = true) throws {
        guard peer.pid == expectedPID, peer.uid == geteuid(),
              expectedAudit == nil || expectedAudit == peer.bytes else { throw AppAttestWorkerError.unauthenticatedPeer }
        let code = try peer.code()
        if fullMeasurement {
            let other = try Self.inspect(code)
            guard other.cdHash == cdHash, other.binaryHash == binaryHash else { throw AppAttestWorkerError.executableChanged }
        } else {
            let information = try Self.validate(code)
            guard information[kSecCodeInfoUnique as String] as? Data == cdHash else {
                throw AppAttestWorkerError.executableChanged
            }
        }
    }

    private static func validate(_ code: SecCode) throws -> [String: Any] {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw AppAttestWorkerError.unauthenticatedPeer
        }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoTeamIdentifier as String] as? String == teamID,
              values[kSecCodeInfoIdentifier as String] as? String == signingID,
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 != 0, flags.uint32Value & 0x2 == 0 else {
            throw AppAttestWorkerError.unauthenticatedPeer
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in ["get-task-allow", "com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory",
                    "com.apple.security.cs.allow-jit"] where (entitlements[key] as? NSNumber)?.boolValue == true {
            throw AppAttestWorkerError.unauthenticatedPeer
        }
        return values
    }
}

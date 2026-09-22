import Darwin
import Foundation
import Security

public struct WorkerIdentity: Sendable, Equatable {
    public let executable: URL
    public let cdHash: Data
    public static let requirement = "anchor apple generic and identifier \"io.darkbloom.provider\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    public static var installedExecutable: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".darkbloom/bin/darkbloom").resolvingSymlinksInPath()
    }

    public static func inspect(_ executable: URL = installedExecutable) throws -> WorkerIdentity {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw ConnectError.untrustedWorker }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw ConnectError.untrustedWorker }
        let hash = try signingHash(code)
        return .init(executable: executable, cdHash: hash)
    }

    private static func signingHash(_ code: SecStaticCode) throws -> Data {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 != 0,
              let hash = info[kSecCodeInfoUnique as String] as? Data else { throw ConnectError.untrustedWorker }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for name in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables"] {
            if entitlements[name] as? Bool == true { throw ConnectError.untrustedWorker }
        }
        return hash
    }

    public func matchesProcess(_ identity: KernelIdentity) -> Bool {
        guard KernelIdentity.read(identity.pid) == identity else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: identity.pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              (try? Self.signingHash(staticCode)) == cdHash else { return false }
        return KernelIdentity.read(identity.pid) == identity
    }
}

public struct KernelIdentity: Codable, Sendable, Equatable {
    public let pid: Int32
    public let start_time_micros: UInt64
    public static func read(_ pid: Int32) -> KernelIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return .init(pid: pid, start_time_micros: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
    }
}

public enum MacHardware {
    public static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    public static var chip: String {
        var length = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0) == 0, length > 0, length < 256 else { return "Apple Silicon" }
        var value = [CChar](repeating: 0, count: length)
        guard sysctlbyname("machdep.cpu.brand_string", &value, &length, nil, 0) == 0 else { return "Apple Silicon" }
        return String(decoding: value.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

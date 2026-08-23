import Foundation
import SandboxCore
import SandboxSecurity
import Security
import SystemConfiguration
import Virtualization

public enum SandboxHostCheckStatus: String, Codable, Equatable, Sendable {
    case pass
    case warning
    case failure
}

public struct SandboxHostCheck: Codable, Sendable {
    public let id: String
    public let status: SandboxHostCheckStatus
    public let summary: String

    public init(id: String, status: SandboxHostCheckStatus, summary: String) {
        self.id = id
        self.status = status
        self.summary = summary
    }
}

public struct SandboxHostReport: Codable, Sendable {
    public let generatedAt: Date
    public let operatingSystem: String
    public let architecture: String
    public let cpuCount: Int
    public let memoryBytes: UInt64
    public let availableDiskBytes: Int64
    public let consoleUser: String?
    public let checks: [SandboxHostCheck]

    public var isEligible: Bool {
        !checks.contains { $0.status == .failure }
    }
}

public struct SandboxHostInspectionPolicy: Sendable {
    public let minimumCPUCount: Int
    public let minimumMemoryBytes: UInt64
    public let minimumAvailableDiskBytes: Int64
    public let requireVirtualizationEntitlement: Bool
    public let requireAquaSession: Bool
    public let requireSecureEnclave: Bool

    public init(
        minimumCPUCount: Int = 10,
        minimumMemoryBytes: UInt64 = 24 * SandboxResourcePolicy.gibibyte,
        minimumAvailableDiskBytes: Int64 = 300 * Int64(SandboxResourcePolicy.gibibyte),
        requireVirtualizationEntitlement: Bool = true,
        requireAquaSession: Bool = true,
        requireSecureEnclave: Bool = true
    ) {
        self.minimumCPUCount = minimumCPUCount
        self.minimumMemoryBytes = minimumMemoryBytes
        self.minimumAvailableDiskBytes = minimumAvailableDiskBytes
        self.requireVirtualizationEntitlement = requireVirtualizationEntitlement
        self.requireAquaSession = requireAquaSession
        self.requireSecureEnclave = requireSecureEnclave
    }
}

public struct SandboxHostInspector: Sendable {
    public init() {}

    public func inspect(
        policy: SandboxHostInspectionPolicy = SandboxHostInspectionPolicy()
    ) -> SandboxHostReport {
        let process = ProcessInfo.processInfo
        let architecture = Self.architecture
        let cpuCount = process.activeProcessorCount
        let memoryBytes = process.physicalMemory
        let availableDiskBytes = Self.availableDiskBytes()
        let consoleUser = Self.consoleUser()

        var checks: [SandboxHostCheck] = []
        checks.append(Self.check(
            id: "apple_silicon",
            condition: architecture == "arm64",
            success: "Apple Silicon architecture detected",
            failure: "macOS sandbox hosts require Apple Silicon"
        ))
        checks.append(Self.check(
            id: "hardware_virtualization",
            condition: Self.hypervisorSupported(),
            success: "Apple hardware virtualization is available",
            failure: "Apple hardware virtualization is unavailable"
        ))
        checks.append(Self.check(
            id: "virtualization_framework",
            condition: VZVirtualMachineConfiguration.maximumAllowedCPUCount > 0
                && VZVirtualMachineConfiguration.maximumAllowedMemorySize > 0,
            success: "Virtualization.framework reports usable VM limits",
            failure: "Virtualization.framework reports no usable VM capacity"
        ))
        checks.append(Self.check(
            id: "cpu_capacity",
            condition: cpuCount >= policy.minimumCPUCount,
            success: "\(cpuCount) logical CPUs satisfy the \(policy.minimumCPUCount)-CPU proof floor",
            failure: "\(cpuCount) logical CPUs are below the \(policy.minimumCPUCount)-CPU proof floor"
        ))
        checks.append(Self.check(
            id: "memory_capacity",
            condition: memoryBytes >= policy.minimumMemoryBytes,
            success: "\(memoryBytes) memory bytes satisfy the proof floor",
            failure: "\(memoryBytes) memory bytes are below the \(policy.minimumMemoryBytes)-byte proof floor"
        ))
        checks.append(Self.check(
            id: "disk_capacity",
            condition: availableDiskBytes >= policy.minimumAvailableDiskBytes,
            success: "\(availableDiskBytes) available disk bytes satisfy the proof floor",
            failure: "\(availableDiskBytes) available disk bytes are below the \(policy.minimumAvailableDiskBytes)-byte proof floor"
        ))

        let hasAquaSession = consoleUser != nil && consoleUser != "loginwindow"
        checks.append(Self.requirementCheck(
            id: "aqua_session",
            condition: hasAquaSession,
            required: policy.requireAquaSession,
            success: "Aqua console session is active for \(consoleUser ?? "unknown")",
            failure: "no logged-in Aqua console session is active"
        ))

        let enclaveResult = Self.secureEnclaveSelfTest()
        checks.append(Self.requirementCheck(
            id: "secure_enclave",
            condition: enclaveResult == nil,
            required: policy.requireSecureEnclave,
            success: "transient Secure Enclave ECIES round trip succeeded",
            failure: enclaveResult ?? "Secure Enclave is unavailable"
        ))

        let hasVirtualizationEntitlement = Self.hasBooleanEntitlement(
            "com.apple.security.virtualization"
        )
        checks.append(Self.requirementCheck(
            id: "virtualization_entitlement",
            condition: hasVirtualizationEntitlement,
            required: policy.requireVirtualizationEntitlement,
            success: "running binary has com.apple.security.virtualization",
            failure: "running binary lacks com.apple.security.virtualization"
        ))

        return SandboxHostReport(
            generatedAt: Date(),
            operatingSystem: process.operatingSystemVersionString,
            architecture: architecture,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            availableDiskBytes: availableDiskBytes,
            consoleUser: consoleUser,
            checks: checks
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func hypervisorSupported() -> Bool {
        var supported: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_support", &supported, &size, nil, 0) == 0
            && supported == 1
    }

    private static func availableDiskBytes() -> Int64 {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let values = try? root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }

    private static func consoleUser() -> String? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?
    }

    private static func secureEnclaveSelfTest() -> String? {
        do {
            let key = try SandboxSecureEnclaveKey.makeTransient()
            try key.selfTest()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private static func hasBooleanEntitlement(_ name: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.executableURL! as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            return false
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [String: Any],
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else {
            return false
        }
        return entitlements[name] as? Bool == true
    }

    private static func check(
        id: String,
        condition: Bool,
        success: String,
        failure: String
    ) -> SandboxHostCheck {
        SandboxHostCheck(
            id: id,
            status: condition ? .pass : .failure,
            summary: condition ? success : failure
        )
    }

    private static func requirementCheck(
        id: String,
        condition: Bool,
        required: Bool,
        success: String,
        failure: String
    ) -> SandboxHostCheck {
        SandboxHostCheck(
            id: id,
            status: condition ? .pass : (required ? .failure : .warning),
            summary: condition ? success : failure
        )
    }
}

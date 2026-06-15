import Foundation

/// Reads the Apple Silicon boot policy exposed by System Profiler.
public enum BootPolicyDiagnostic {
    public struct BootPolicy: Sendable, Equatable {
        public let secureBoot: String
        public let systemIntegrityProtection: String?
        public let signedSystemVolume: String?
        public let kernelCTRR: String?
        public let bootArgumentsFiltering: String?
        public let allowAllKernelExtensions: String?
        public let userApprovedPrivilegedMDMOperations: String?
        public let depApprovedPrivilegedMDMOperations: String?

        public init(
            secureBoot: String,
            systemIntegrityProtection: String?,
            signedSystemVolume: String?,
            kernelCTRR: String?,
            bootArgumentsFiltering: String?,
            allowAllKernelExtensions: String?,
            userApprovedPrivilegedMDMOperations: String?,
            depApprovedPrivilegedMDMOperations: String?
        ) {
            self.secureBoot = secureBoot
            self.systemIntegrityProtection = systemIntegrityProtection
            self.signedSystemVolume = signedSystemVolume
            self.kernelCTRR = kernelCTRR
            self.bootArgumentsFiltering = bootArgumentsFiltering
            self.allowAllKernelExtensions = allowAllKernelExtensions
            self.userApprovedPrivilegedMDMOperations = userApprovedPrivilegedMDMOperations
            self.depApprovedPrivilegedMDMOperations = depApprovedPrivilegedMDMOperations
        }

        public var isFullSecurity: Bool {
            normalized(secureBoot) == "fullsecurity"
        }

        public var allowsKernelExtensions: Bool {
            normalized(allowAllKernelExtensions ?? "") == "yes"
        }
    }

    public static func diagnose(runner: SecurityCommandRunner = .live) -> Diagnostic {
        do {
            let result = try runner.run("/usr/sbin/system_profiler", ["SPiBridgeDataType", "-json"])
            guard result.terminationStatus == 0 else {
                let reason = [result.stdout, result.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return unavailableDiagnostic(reason: reason.isEmpty ? "system_profiler exited with \(result.terminationStatus)" : reason)
            }
            return diagnose(policy: try parseSystemProfilerJSON(result.stdout))
        } catch {
            return unavailableDiagnostic(reason: String(describing: error))
        }
    }

    public static func diagnose(policy: BootPolicy?) -> Diagnostic {
        guard let policy else {
            return unavailableDiagnostic(reason: "SPiBridgeDataType did not include a boot policy")
        }

        if policy.allowsKernelExtensions {
            return Diagnostic(
                section: .security,
                name: "boot policy",
                level: .fail,
                message: "boot policy is \(policy.secureBoot); Allow All Kernel Extensions: \(policy.allowAllKernelExtensions ?? "unknown"). Apple Silicon providers should run with Full Security and third-party kernel extensions disabled.",
                fix: "uninstall third-party kernel extensions, reboot, then use Recovery > Startup Security Utility > Full Security.")
        }

        if !policy.isFullSecurity {
            return Diagnostic(
                section: .security,
                name: "boot policy",
                level: .fail,
                message: "boot policy is \(policy.secureBoot). Apple Silicon providers should run with Full Security.",
                fix: "use Recovery > Startup Security Utility > Full Security.")
        }

        return Diagnostic(
            section: .security,
            name: "boot policy",
            level: .pass,
            message: "boot policy is Full Security.",
            fix: nil)
    }

    public static func parseSystemProfilerJSON(_ json: String) throws -> BootPolicy? {
        let data = Data(json.utf8)
        let report = try JSONDecoder().decode(SystemProfilerBridgeReport.self, from: data)
        return report.SPiBridgeDataType.compactMap { record in
            guard let secureBoot = nonEmpty(record.secureBoot) else {
                return nil
            }
            return BootPolicy(
                secureBoot: secureBoot,
                systemIntegrityProtection: nonEmpty(record.systemIntegrityProtection),
                signedSystemVolume: nonEmpty(record.signedSystemVolume),
                kernelCTRR: nonEmpty(record.kernelCTRR),
                bootArgumentsFiltering: nonEmpty(record.bootArgumentsFiltering),
                allowAllKernelExtensions: nonEmpty(record.allowAllKernelExtensions),
                userApprovedPrivilegedMDMOperations: nonEmpty(record.userApprovedPrivilegedMDMOperations),
                depApprovedPrivilegedMDMOperations: nonEmpty(record.depApprovedPrivilegedMDMOperations))
        }.first
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unavailableDiagnostic(reason: String) -> Diagnostic {
        Diagnostic(
            section: .security,
            name: "boot policy",
            level: .warn,
            message: "could not inspect Apple Silicon boot policy: \(reason)",
            fix: "run `system_profiler SPiBridgeDataType` locally and check Boot Policy > Secure Boot.")
    }

    private struct SystemProfilerBridgeReport: Decodable {
        let SPiBridgeDataType: [SystemProfilerBridgeRecord]
    }

    private struct SystemProfilerBridgeRecord: Decodable {
        let secureBoot: String?
        let systemIntegrityProtection: String?
        let signedSystemVolume: String?
        let kernelCTRR: String?
        let bootArgumentsFiltering: String?
        let allowAllKernelExtensions: String?
        let userApprovedPrivilegedMDMOperations: String?
        let depApprovedPrivilegedMDMOperations: String?

        enum CodingKeys: String, CodingKey {
            case secureBoot = "ibridge_secure_boot"
            case systemIntegrityProtection = "ibridge_sb_sip"
            case signedSystemVolume = "ibridge_sb_ssv"
            case kernelCTRR = "ibridge_sb_ctrr"
            case bootArgumentsFiltering = "ibridge_sb_boot_args"
            case allowAllKernelExtensions = "ibridge_sb_other_kext"
            case userApprovedPrivilegedMDMOperations = "ibridge_sb_manual_mdm"
            case depApprovedPrivilegedMDMOperations = "ibridge_sb_device_mdm"
        }
    }
}

import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

enum GuestTenantCleanup {
    struct Operations: Sendable {
        let removeDomains: @Sendable () async throws -> Void
        let cleanProcesses: @Sendable () async throws -> Void
        let activeProcesses: @Sendable () throws -> Int
        let verifyLoginDomain: @Sendable () async throws -> Void
        let pause: @Sendable () async -> Void
    }

    static func run(executable: URL) async throws {
        try await run(operations: Operations(
            removeDomains: { try await GuestTenantDomains.remove() },
            cleanProcesses: {
                _ = try await SandboxProcessRunner().run(executable: executable,
                    arguments: ["tenant-cleanup"], timeoutSeconds: 3, maximumOutputBytes: 1024)
            },
            activeProcesses: activeTenantProcesses,
            verifyLoginDomain: { try await GuestTenantDomains.verifyLoginDomainAbsent() },
            pause: { try? await Task.sleep(for: .milliseconds(100)) }))
    }

    static func run(operations: Operations) async throws {
        for _ in 0..<5 {
            try await GuestBootstrapDiagnostic.runAsync(.tenantDomainRemoval) {
                try await operations.removeDomains()
            }
            try await GuestBootstrapDiagnostic.runAsync(.tenantCleanupWorker) {
                try await operations.cleanProcesses()
            }
            // The cleanup worker drops to UID2001. That transition can create
            // a user domain even when none existed before the worker started.
            // Retire it after the worker exits, then recheck process quiescence.
            try await GuestBootstrapDiagnostic.runAsync(.tenantDomainRemoval) {
                try await operations.removeDomains()
            }
            if try GuestBootstrapDiagnostic.run(.tenantProcessInventory, operations.activeProcesses) == 0 {
                try await GuestBootstrapDiagnostic.runAsync(.tenantDomainVerification) {
                    try await operations.verifyLoginDomain()
                }
                // Verification must not create a domain; still take the final
                // process snapshot after all launchctl calls have completed.
                if try GuestBootstrapDiagnostic.run(.tenantProcessInventory, operations.activeProcesses) == 0 {
                    return
                }
            }
            await operations.pause()
        }
        try GuestBootstrapDiagnostic.run(.tenantProcessInventory) { throw GuestProtocolError.cleanupUncertain }
    }

    private static func activeTenantProcesses() throws -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, 2001]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size <= 16 * 1_048_576 else { throw GuestProtocolError.cleanupUncertain }
        let stride = MemoryLayout<kinfo_proc>.stride
        var records = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = records.count * stride
        let status = records.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard status == 0, size % stride == 0 else { throw GuestProtocolError.cleanupUncertain }
        return records.prefix(size / stride).filter { Int32($0.kp_proc.p_stat) != SZOMB }.count
    }
}

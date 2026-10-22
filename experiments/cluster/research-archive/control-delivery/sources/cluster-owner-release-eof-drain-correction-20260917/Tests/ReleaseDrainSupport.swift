import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import DarkbloomClusterRemote

enum ReleaseDrainFailure: Error { case invalid(String) }
func drainRequire(_ value: Bool, _ message: String) throws {
    guard value else { throw ReleaseDrainFailure.invalid(message) }
}

func drainStart() throws -> ClusterNativeAuthorizationStart {
    let common = try ClusterNativeAuthorizationCommon(epoch: fixtureIdentity.membershipEpoch,
        membershipGeneration: 1, nativePolicyGeneration: 1,
        membershipTranscriptSHA256: Data(repeating: 1, count: 32),
        approvedNativeBindingSHA256: Data(repeating: 2, count: 32),
        planSHA256: Data(repeating: 0xee, count: 32), artifactSHA256: Data(repeating: 0xaa, count: 32),
        nativeRuntimeSHA256: Data(repeating: 0xcc, count: 32), capabilitySHA256: Data(repeating: 3, count: 32),
        resourcePolicySHA256: Data(repeating: 4, count: 32), profileSHA256: Data(repeating: 5, count: 32),
        schedule: .serial, maximumTransportFrameBytes: 4136,
        limits: .init(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64,
            maximumCumulativePlaintextBytesPerDirection: 262144))
    return try .init(common: common, rank: 0,
        ownerIncarnation: UUID(uuidString: "12345678-1111-2222-3333-444444444444")!,
        leaseID: UUID(uuidString: "12345678-1111-2222-3333-555555555555")!,
        launchID: UUID(uuidString: "12345678-1111-2222-3333-666666666666")!)
}

func drainWrite(_ value: String, _ name: String, in directory: URL) throws {
    try Data(value.utf8).write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
}

func drainPID(_ name: String, in directory: URL) throws -> Int32 {
    let raw = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    guard let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
        throw ReleaseDrainFailure.invalid("Missing actual fixture PID")
    }
    return pid
}

// The native-key relay calls cancellation synchronously from the endpoint reader.
// Hold that callback until this exact fixture owner exits. No signal is sent.
final class ReleaseDrainHold: @unchecked Sendable {
    private let lock = NSLock()
    private var result = false
    private var entered = false
    let directory: URL
    init(directory: URL) { self.directory = directory }
    var ownerExitedBeforeReturn: Bool { lock.withLock { entered && result } }
    func cancel() {
        let first = lock.withLock { if entered { return false }; entered = true; return true }
        guard first else { return }
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        do {
            let pid = try drainPID("owner-pid", in: directory)
            try drainWrite("entered\n", "terminal-callback", in: directory)
            while DispatchTime.now().uptimeNanoseconds < end {
                if Darwin.kill(pid, 0) == -1 && errno == ESRCH {
                    let completed = FileManager.default.fileExists(atPath: directory.appendingPathComponent("service-returned").path)
                    lock.withLock { result = completed }
                    return
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        } catch { }
    }
}

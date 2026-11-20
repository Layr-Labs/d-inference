import Foundation
import Darwin
@testable import ProviderCore

@main enum RotationOwnerCheck {
    static func main() async {
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(60)
        do { try await run() }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data(("Rotation fixture setup failed: \(error)\n").utf8))
            Darwin.exit(1)
        }
        alarm(0)
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, ["normal", "held-response", "missing-ack", "nonzero-owner", "stop-start"].contains(args[0]) else {
            throw RotationCheckError(message: "Expected CASE PROBE OWNER WORKER OUTPUT_DIRECTORY")
        }
        let root = URL(fileURLWithPath: args[4]).appendingPathComponent("fixture")
        try rotationRequire(!FileManager.default.fileExists(atPath: root.path), "Fixture directory already exists")
        let fixture = try InstalledFixture.make(root: root, probe: URL(fileURLWithPath: args[1]),
            owner: URL(fileURLWithPath: args[2]), worker: URL(fileURLWithPath: args[3]))
        let gate = args[0] == "stop-start" ? RotationStartupGate() : nil
        let behavior = args[0] == "missing-ack" ? "drop-release" : args[0] == "nonzero-owner" ? "nonzero-owner" : "normal"
        let owners = try RotationOwners(fixture: fixture, behavior: behavior, startupGate: gate)
        let first = try owners.first(), discovery = RotationDiscovery()
        let host = owners.host(first: first, discovery: discovery)
        var receipts: [RotationHTTPReceipt] = []
        var failure: String?
        do {
            try await host.start()
            switch args[0] {
            case "normal": receipts = try await RotationScenarios.normal(owners, host: host, discovery: discovery)
            case "held-response": receipts = try await RotationScenarios.heldResponse(owners, host: host, discovery: discovery)
            case "missing-ack", "nonzero-owner": receipts = try await RotationScenarios.failedRelease(owners, host: host)
            default: receipts = try await RotationScenarios.stopDuringStart(owners, host: host)
            }
        } catch {
            failure = String(describing: error)
            gate?.open()
            _ = await host.stop(until: rotationDeadline())
        }
        let state = await host.status
        let snapshots: [[String: Any]] = owners.snapshot.map { record in
            ["epoch": record.session.expectedIdentity.membershipEpoch.uuidString.lowercased(),
             "status": record.session.status.rawValue, "canRotate": record.session.canRotate,
             "remainingRequests": record.session.admissionState?.admissionsRemaining as Any? ?? NSNull(),
             "endpoints": record.endpoints.values.map { endpoint -> [String: Any] in
                 ["rank": endpoint.rank, "nativeCleanupObserved": endpoint.nativeCleanupObserved,
                  "ownerReleaseAcknowledged": endpoint.ownerDeviceLeaseReleasedObserved,
                  "ownerTermination": endpoint.ownerTermination.map { String(describing: $0) } as Any? ?? NSNull(),
                  "diagnosticTail": String(decoding: endpoint.diagnosticTail, as: UTF8.self)]
             }]
        }
        let result: [String: Any] = ["schema": "installed_quota_rotation_cpu_check_v1", "case": args[0],
            "success": failure == nil, "failure": failure as Any? ?? NSNull(),
            "hostPhase": state.phase.rawValue, "hostFailed": state.failed, "cleanupComplete": state.cleanupComplete,
            "discoveryWrites": discovery.writeCount, "discoveryRemoved": discovery.value == nil,
            "generations": snapshots, "httpReceipts": try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipts)),
            "actualLocalOwnerChildren": true, "modelPayloadRead": false, "nativeModelExecuted": false,
            "remoteTransportQualified": false, "coordinatorMembershipQualified": false]
        var bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        bytes.append(10)
        try rotationRequire(bytes.count <= 65_536, "Fixture result exceeds bound")
        try bytes.write(to: URL(fileURLWithPath: args[4]).appendingPathComponent("result.json"))
        try FileHandle.standardOutput.write(contentsOf: bytes)
        // SIGALRM remains armed through final output. The outer owned-process
        // runner retains the actual exit/reap result independently.
        if failure != nil { Darwin.exit(1) }
    }
}

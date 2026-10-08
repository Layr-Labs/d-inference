import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

final class LocalSink: @unchecked Sendable {
    let lock = NSLock()
    var tokens: [Int] = [], failed = false
    func receive(_ event: ClusterWorkerRequestEvent) -> Bool {
        lock.withLock {
            switch event { case .token(let id): tokens.append(id); case .failed: failed = true; case .finished: break }
        }
        return true
    }
}

/// Compiled in the Remote module solely to use its existing local-child fixture
/// initializer. The actual controller uses only public configured SSH creation.
@main struct LocalCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw QualificationFailure.invalid("Expected BUILD CONFIG directories") }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(35)
        let build = URL(fileURLWithPath: CommandLine.arguments[1]), configs = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("owner-argv-check-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let names = ["darkbloom-owner-qualification", "native-standin", "libDarkbloomClusterProtocol.dylib",
                     "libDarkbloomClusterProcess.dylib", "libDarkbloomClusterRemote.dylib",
                     "libDarkbloomClusterBootstrap.dylib", "libDarkbloomClusterRuntime.dylib"]
        var owners: [URL] = []
        for rank in 0..<2 {
            let owner = directory.appendingPathComponent("rank\(rank)")
            try fm.createDirectory(at: owner, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: owner.appendingPathComponent("lease"), withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            for name in names { try fm.copyItem(at: build.appendingPathComponent(name), to: owner.appendingPathComponent(name)) }
            let (raw, _) = try readQualificationJSON(configs.appendingPathComponent("owner-rank\(rank).json").path, maximum: 16_384)
            var value = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            value["workerExecutable"] = owner.appendingPathComponent("native-standin").path
            value["leaseDirectory"] = owner.appendingPathComponent("lease").path
            value["modelDirectory"] = owner.appendingPathComponent("missing-model-never-opened").path
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: owner.appendingPathComponent("owner.json"))
            owners.append(owner)
        }
        let (config, _) = try readQualificationJSON(configs.appendingPathComponent("owner-rank0.json").path, maximum: 16_384)
        let object = try JSONSerialization.jsonObject(with: config) as! [String: Any]
        let template = try qualificationTemplate(object["readyTemplateBase64"] as! String)
        for outputCount in [2, 3] {
            let deadline = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
            let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: template.identity.modelID,
                artifactSHA256: template.identity.artifactSHA256, configurationSHA256: template.identity.configurationSHA256,
                peers: template.identity.peers)
            let relay = try ClusterOwnerBootstrapRelay(identity: identity, executionPlanSHA256: template.executionPlanSHA256,
                deadlineUptimeNanoseconds: deadline)
            var endpoints: [ClusterRemoteWorkerEndpoint] = []
            for rank in 0..<2 {
                endpoints.append(try .init(transport: .init(executable: owners[rank].appendingPathComponent("darkbloom-owner-qualification"),
                    arguments: ["cluster", "worker-owner", "--stdio"], environment: [:]), clusterID: "cpu-ssh-qualification",
                    expectedIdentity: identity, profile: template.profile, rank: rank, executionPlanSHA256: template.executionPlanSHA256,
                    lifetimeDeadlineUptimeNanoseconds: deadline, bootstrapRelay: relay))
            }
            var pair: ClusterWorkerPair?, request: ClusterWorkerRequest?, failed = false, failure = ""
            let sink = LocalSink()
            do {
                let value = try ClusterWorkerPair(workers: endpoints, startupDeadline: deadline); pair = value
                guard let ready = value.readiness else { throw QualificationFailure.invalid("Not ready") }
                let active = try value.reserve(requestID: UUID(), reservation: .init(profileID: template.profile.id,
                    promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: outputCount, chunkSize: 2,
                    deadlineUptimeNanoseconds: deadline, capacityLimitBytes: ready.requestCapacityBytes))
                request = active; try active.start { sink.receive($0) }
                await active.waitUntilRetired(); active.releaseResources()
                guard active.bytesInUse == 0, sink.lock.withLock({ sink.tokens == [9, 10] && !sink.failed }) else {
                    throw QualificationFailure.invalid("Unexpected local fixture result")
                }
            } catch { failed = true; failure = String(describing: error); request?.cancel(reason: .runtimeError); for endpoint in endpoints { endpoint.requestNativeCleanup() } }
            if let pair { await pair.shutdown() } else { for endpoint in endpoints { await endpoint.waitUntilNativeCleanup() } }
            let drain = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !endpoints.allSatisfy(\.ownerDeviceLeaseReleasedObserved), DispatchTime.now().uptimeNanoseconds < drain {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try qualificationEmit(["outputCount": outputCount, "failed": failed, "failure": failure,
                "nativeCleanup": endpoints.map(\.nativeCleanupObserved), "leaseReleased": endpoints.map(\.ownerDeviceLeaseReleasedObserved),
                "diagnostics": endpoints.map { String(decoding: $0.diagnosticTail, as: UTF8.self) },
                "tokens": sink.lock.withLock { sink.tokens }, "directory": directory.path])
            guard failed == (outputCount == 3), endpoints.allSatisfy(\.nativeCleanupObserved),
                  outputCount == 3 || endpoints.allSatisfy(\.ownerDeviceLeaseReleasedObserved) else {
                throw QualificationFailure.invalid("Native cleanup or authenticated lease ACK missing; inspect \(directory.path)")
            }
            for (rank, owner) in owners.enumerated() {
                let bytes = try Data(contentsOf: owner.appendingPathComponent("lease/native-device.lease"))
                // Invalid protocol during partial admission may deliberately
                // leave a sticky journal. Only an ACK permits a resolved claim.
                guard !endpoints[rank].ownerDeviceLeaseReleasedObserved || bytes.isEmpty else {
                    throw QualificationFailure.invalid("Release ACK contradicts retained journal")
                }
            }
        }
        print("PASS configured owner/native argv and two tokens with bilateral terminal+lease ACK; partial-admission failure preserves actual cleanup and unresolved journals (2 cases); retained " + directory.path)
        alarm(0)
    }
}

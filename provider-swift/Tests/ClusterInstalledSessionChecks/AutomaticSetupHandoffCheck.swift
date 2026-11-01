import Foundation
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterProcess
@testable import InstalledContract

extension InstalledSessionCheck {
    static func automaticSetupHandoff(_ f: InstalledFixture) throws {
        // The host may discard a proposal after its queue empties. The same
        // generation can retry after the bounded cooldown without an ACK.
        var attempts = DistributedAutomaticBatchAttempt()
        let first = ContinuousClock.now
        try require(attempts.begin(now: first), "initial automatic proposal")
        try require(!attempts.begin(now: first.advanced(by: .seconds(29))), "discarded proposal still throttled")
        try require(attempts.begin(now: first.advanced(by: .seconds(30))), "discarded proposal retries same generation")
        try require(!attempts.begin(now: first.advanced(by: .seconds(31))), "retry resets cooldown")
        try require(attempts.begin(now: first.advanced(by: .seconds(60))), "later same generation retries")

        let folder = f.root.appendingPathComponent("handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f.reference.configuration))) as! [String: Any]
        object["batchLanes"] = 8
        let input = folder.appendingPathComponent("batch.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: input)
        let capFile = try f.paths.capabilityURL(sha256: f.configuration.capabilitySHA256)
        var target: ClusterConfigurationReference?
        _ = try ClusterConfigurationStore(paths: f.paths).save(configurationInput: input, capabilityInput: capFile,
            capabilitySHA256: f.configuration.capabilitySHA256) { target = $0 }
        let replacement = try require(target, "batch setup was not saved")
        let config = try ClusterConfigurationStore(paths: f.paths).load(reference: replacement).configuration
        try ClusterAutomaticSetupHandoff.requireCompatible(f.configuration, config)
        let pid = getpid(), started = try require(ClusterProcessTable.startTime(of: getpid()), "fixture process has no start identity")
        let now = Date().timeIntervalSince1970
        let record = ClusterAutomaticSetupHandoff(id: UUID(), processID: pid, processStartedAt: started,
            previous: f.reference, replacement: replacement, expiresAt: now + 30)
        let oldKey = ClusterLocalServing.partKey(setupSHA256: f.reference.sha256, scope: .publicServing)
        let newKey = ClusterLocalServing.partKey(setupSHA256: replacement.sha256, scope: .publicServing)
        try require(record.matches(processID: pid, startedAt: started, previousKey: oldKey, replacementKey: newKey,
            scope: .publicServing, now: now), "live handoff identity did not match")
        for (pidValue, start, old, new, time) in [
            (pid + 1, started, oldKey, newKey, now), (pid, started + 1, oldKey, newKey, now),
            (pid, started, "cluster:wrong", newKey, now), (pid, started, oldKey, "cluster:wrong", now),
            (pid, started, oldKey, newKey, now + 31), (pid, started, oldKey, newKey, now - 61),
        ] {
            try require(!record.matches(processID: pidValue, startedAt: start, previousKey: old, replacementKey: new,
                scope: .publicServing, now: time), "stale or other process/setup handoff matched")
        }
        try require(!record.matches(processID: pid, startedAt: started, previousKey: oldKey, replacementKey: newKey,
            scope: .localOnly(bind: "127.0.0.1"), now: now), "handoff changed the API exposure")
        let url = ClusterAutomaticSetupHandoff.file(in: folder)
        try ClusterConfigurationFiles.update(url, maximum: 4096) { _ in try JSONEncoder().encode(record) }
        try require(config.selectedPlanSHA256 == f.configuration.selectedPlanSHA256 && replacement.sha256 != f.reference.sha256,
            "width-only change did not preserve the cut and change its full setup identity")
        let device = try ClusterConfigurationFiles.directory(f.paths.deviceDirectory, create: true, privateMode: true)
        defer { close(device.descriptor) }
        try ClusterConfigurationFiles.withLock(device, name: f.paths.deviceLeaseFile.lastPathComponent,
            requireEmpty: true, privateMode: true) {
            try require(ClusterAutomaticSetupHandoff.disposition(directory: folder, paths: f.paths, processID: pid,
                startedAt: started, previousKey: oldKey, replacementKey: newKey, scope: .publicServing, now: now) == .pending,
                "supervisor restarted or acknowledged while setup publication held the device gate")
        }
        var peer = ClusterServiceStatus(role: "follower", serving: true, modelName: f.configuration.publicModelID,
            sessionLeader: false, localRank: 1, setup: "same-cut", child: .init(running: true, starts: 1), session: nil)
        peer.child.configurationSHA256 = f.reference.sha256
        try require(!ClusterAutomaticBatchSetup.peerHasAdopted(peer, sha256: replacement.sha256),
            "a stale running follower passed on an unchanged cut")
        peer.child.configurationSHA256 = replacement.sha256; peer.child.running = false
        try require(!ClusterAutomaticBatchSetup.peerHasAdopted(peer, sha256: replacement.sha256),
            "a selected but not yet launched follower passed")
        peer.child.running = true
        try require(ClusterAutomaticBatchSetup.peerHasAdopted(peer, sha256: replacement.sha256),
            "the exact running follower setup did not pass")
        peer.child.solo = true
        try require(!ClusterAutomaticBatchSetup.peerHasAdopted(peer, sha256: replacement.sha256),
            "a solo child passed as a replacement follower")
        try require(ClusterAutomaticSetupHandoff.accept(directory: folder, paths: f.paths, processID: pid,
            startedAt: started, previousKey: oldKey, replacementKey: newKey, scope: .publicServing, now: now),
            "real immutable saved setup handoff was refused")
        let acknowledged = try JSONDecoder().decode(ClusterAutomaticSetupHandoff.self,
            from: ClusterConfigurationFiles.read(url, maximum: 4096, privateMode: true))
        try require(acknowledged.id == record.id && acknowledged.acknowledged, "supervisor did not acknowledge exact handoff")
        for acknowledged in [false, true] {
            var prior = record; prior.acknowledged = acknowledged
            try require(prior.permitsRollback(processID: pid, startedAt: started, candidate: replacement,
                target: f.reference, now: now), "exact rollback transaction was refused")
            try require(!prior.permitsRollback(processID: pid + 1, startedAt: started, candidate: replacement,
                target: f.reference, now: now), "another process authorized rollback")
            try ClusterConfigurationFiles.update(url, maximum: 4096) { _ in try JSONEncoder().encode(prior) }
            let publication = try ClusterAutomaticSetupHandoff.publish(directory: folder, processID: pid,
                startedAt: started, previous: replacement, replacement: f.reference,
                compensatingUnacknowledged: true, now: now)
            try require(publication.requiresAcknowledgement == acknowledged,
                "reverse handoff lost the atomic prior acknowledgement state")
            // The observer captured old child + candidate desired key before
            // rollback. It may run while publication holds the device gate or
            // just after the pointers were restored and the gate was released.
            try ClusterConfigurationFiles.withLock(device, name: f.paths.deviceLeaseFile.lastPathComponent,
                requireEmpty: true, privateMode: true) {
                try require(ClusterAutomaticSetupHandoff.disposition(directory: folder, paths: f.paths, processID: pid,
                    startedAt: started, previousKey: oldKey, replacementKey: newKey, scope: .publicServing, now: now) == .pending,
                    "reverse publication interval restarted the listener")
            }
            try require(ClusterAutomaticSetupHandoff.disposition(directory: folder, paths: f.paths, processID: pid,
                startedAt: started, previousKey: oldKey, replacementKey: newKey, scope: .publicServing, now: now) == .pending,
                "post-compensation stale desired key restarted the listener")
            try require(ClusterAutomaticSetupHandoff.disposition(directory: folder, paths: f.paths, processID: pid,
                startedAt: started, previousKey: newKey, replacementKey: oldKey, scope: .publicServing, now: now) == .adopted,
                "acknowledged candidate did not adopt the exact reverse handoff")
            for (testPID, key, time) in [(pid + 1, newKey, now), (pid, "cluster:foreign", now), (pid, newKey, now + 61)] {
                try require(ClusterAutomaticSetupHandoff.disposition(directory: folder, paths: f.paths, processID: testPID,
                    startedAt: started, previousKey: key, replacementKey: oldKey, scope: .publicServing, now: time) == .reject,
                    "reverse handoff deferred an unrelated or expired observation")
            }
            let stranded: [String: Any] = ["schema": "darkbloom_native_lease_v1", "clusterID": "fixture", "peerID": "fixture", "rank": 0,
                "membershipEpoch": UUID().uuidString.lowercased(), "leaseID": UUID().uuidString.lowercased(),
                "ownerIncarnation": UUID().uuidString.lowercased(), "nativeLaunchID": UUID().uuidString.lowercased()]
            for journal in [try JSONSerialization.data(withJSONObject: stranded), Data("unreadable".utf8)] {
                try journal.write(to: f.paths.deviceLeaseFile)
                try require(ClusterAutomaticSetupHandoff.disposition(directory: folder, paths: f.paths, processID: pid,
                    startedAt: started, previousKey: newKey, replacementKey: oldKey, scope: .publicServing, now: now) == .reject,
                    "a stranded or unreadable native journal passed the handoff")
                try Data().write(to: f.paths.deviceLeaseFile)
            }
        }
        for (field, value) in [("publicModelID", "other/model"), ("requestTimeoutSeconds", 20), ("chunkTokens", 3)] as [(String, Any)] {
            var changed = object; changed[field] = value
            let bad = try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: changed),
                capability: f.capability, capabilitySHA256: f.configuration.capabilitySHA256)
            try rejected { try ClusterAutomaticSetupHandoff.requireCompatible(config, bad) }
        }
        print("Automatic setup handoff: live process, saved identities, scope, expiry and acknowledgement passed")
    }
}

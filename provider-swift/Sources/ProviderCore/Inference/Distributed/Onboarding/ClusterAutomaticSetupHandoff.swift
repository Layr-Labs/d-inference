import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProcess
import Darwin
import DarkbloomClusterRemote

/// A serving API's bounded handoff of its supervisor key. This changes no
/// worker ownership: the caller must first retire its generation, and the
/// normal configuration store still requires the device journal to be empty.
/// The supervisor independently checks both immutable records and the exact
/// live process incarnation before keeping that one listener through adoption.
struct ClusterAutomaticSetupHandoff: Codable, Equatable, Sendable {
    let id: UUID
    let processID: Int32
    let processStartedAt: Double
    let previous: ClusterConfigurationReference
    let replacement: ClusterConfigurationReference
    let expiresAt: Double
    var acknowledged: Bool = false

    static func file(in directory: URL) -> URL { directory.appendingPathComponent("automatic-setup-handoff.json") }

    static func requireCompatible(_ before: ClusterConfiguration, _ after: ClusterConfiguration,
                                  runtimeModelID: String? = nil) throws {
        guard before.nativeMember == nil, after.nativeMember == nil,
              before.batchLanes != nil || after.batchLanes != nil else {
            throw ClusterConfigurationError.invalid("Automatic replacement requires an ordinary batch-capable setup")
        }
        guard before.tensorAssistant == after.tensorAssistant else {
            throw ClusterConfigurationError.invalid("Automatic replacement changed the resident tensor assistant policy")
        }
        if let runtimeModelID, ClusterPlacementTensorBatchQuote.runtimeModelIDs.contains(runtimeModelID),
           before.selectedGenerationMode == .tensorParallel {
            guard after.selectedGenerationMode == .tensorParallel,
                  (before.tensorShares ?? [1, 1]) == (after.tensorShares ?? [1, 1]) else {
                throw ClusterConfigurationError.invalid("A Qwen TP capacity replacement changed its tensor arithmetic partition")
            }
        }
        func identity(_ configuration: ClusterConfiguration) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
            for field in ["selectedPlanSHA256", "generationMode", "prefillSchedule", "tensorShares", "batchLanes"] {
                object.removeValue(forKey: field)
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        guard try identity(before) == identity(after) else {
            throw ClusterConfigurationError.invalid("Automatic replacement changed the model, peer, trust, rank or request limits")
        }
    }

    func matches(processID: Int32, startedAt: Double, previousKey: String, replacementKey: String,
                 scope: ClusterServingScope, now: Double) -> Bool {
        self.processID == processID && processID > 0 && processStartedAt.isFinite && startedAt.isFinite
            && abs(processStartedAt - startedAt) < 0.001
            && expiresAt.isFinite && expiresAt > now && expiresAt - now <= 60
            && previousKey == ClusterLocalServing.partKey(setupSHA256: previous.sha256, scope: scope)
            && replacementKey == ClusterLocalServing.partKey(setupSHA256: replacement.sha256, scope: scope)
    }

    func permitsRollback(processID: Int32, startedAt: Double,
                         candidate: ClusterConfigurationReference, target: ClusterConfigurationReference,
                         now: Double) -> Bool {
        self.processID == processID && processID > 0 && processStartedAt.isFinite && startedAt.isFinite
            && abs(processStartedAt - startedAt) < 0.001 && expiresAt.isFinite
            && expiresAt > now && expiresAt - now <= 60 && previous == target && replacement == candidate
    }

    struct Publication {
        let record: ClusterAutomaticSetupHandoff
        let requiresAcknowledgement: Bool
    }

    static func publish(directory: URL, processID: Int32, startedAt: Double,
                        previous: ClusterConfigurationReference, replacement: ClusterConfigurationReference,
                        compensatingUnacknowledged: Bool, now: Double = Date().timeIntervalSince1970) throws -> Publication {
        let record = Self(id: UUID(), processID: processID, processStartedAt: startedAt,
            previous: previous, replacement: replacement, expiresAt: now + 60)
        var requiresAcknowledgement = true
        try ClusterConfigurationFiles.update(file(in: directory), maximum: 4096) { current in
            if compensatingUnacknowledged {
                guard let current, let prior = try? JSONDecoder().decode(Self.self, from: current),
                      prior.permitsRollback(processID: processID, startedAt: startedAt, candidate: previous,
                        target: replacement, now: now) else {
                    throw ClusterConfigurationError.invalid("The unacknowledged setup changed before compensation")
                }
                // ACK may precede the supervisor's in-memory key update. If
                // it won this CAS, wait for reverse ACK even when the published
                // child still shows the old key. Otherwise replacing the record
                // prevents any in-flight original ACK from winning afterward.
                requiresAcknowledgement = prior.acknowledged
            }
            return try JSONEncoder().encode(record)
        }
        return .init(record: record, requiresAcknowledgement: requiresAcknowledgement)
    }

    private enum Race: Error { case recordChanged }

    /// Called only when an otherwise running child would be restarted for a
    /// setup-key change. A missing, stale, forged or incompatible record keeps
    /// the existing restart behavior. A scope/address change is never adopted.
    enum Disposition { case reject, pending, adopted }

    static func accept(directory: URL, paths: ClusterUserPaths, processID: Int32, startedAt: Double?,
                       previousKey: String?, replacementKey: String?, scope: ClusterServingScope,
                       now: Double = Date().timeIntervalSince1970) -> Bool {
        disposition(directory: directory, paths: paths, processID: processID, startedAt: startedAt,
            previousKey: previousKey, replacementKey: replacementKey, scope: scope, now: now) == .adopted
    }

    static func disposition(directory: URL, paths: ClusterUserPaths, processID: Int32, startedAt: Double?,
                       previousKey: String?, replacementKey: String?, scope: ClusterServingScope,
                       now: Double = Date().timeIntervalSince1970) -> Disposition {
        guard let startedAt, let previousKey, let replacementKey,
              let actual = ClusterProcessTable.startTime(of: processID), abs(actual - startedAt) < 0.001 else { return .reject }
        do {
            let url = file(in: directory)
            let bytes = try ClusterConfigurationFiles.read(url, maximum: 4096, privateMode: true)
            var record = try JSONDecoder().decode(Self.self, from: bytes)
            let forward = record.matches(processID: processID, startedAt: startedAt, previousKey: previousKey,
                replacementKey: replacementKey, scope: scope, now: now)
            let reversed = record.matches(processID: processID, startedAt: startedAt, previousKey: replacementKey,
                replacementKey: previousKey, scope: scope, now: now)
            guard forward || reversed else { return .reject }
            let store = ClusterConfigurationStore(paths: paths)
            let old = try store.load(reference: record.previous), new = try store.load(reference: record.replacement)
            guard old.configuration.role == .leader, new.configuration.role == .leader,
                  old.capability == new.capability else { return .reject }
            try requireCompatible(old.configuration, new.configuration, runtimeModelID: old.capability.runtimeModelID)
            switch try ClusterDeviceLeaseRecovery.inspect(directoryURL: paths.deviceDirectory) {
            case .absentOrEmpty:
                guard forward else { return .pending }
            // The store holds this gate while publishing the pointers. Keep
            // the valid bounded handoff pending; never acknowledge or restart
            // the listener in that publication interval.
            case .heldByLiveOwner: return .pending
            default: return .reject
            }
            record.acknowledged = true
            try ClusterConfigurationFiles.update(url, maximum: 4096) { current in
                guard current == bytes else { throw Race.recordChanged }
                return try JSONEncoder().encode(record)
            }
            return .adopted
        } catch Race.recordChanged {
            // A concurrent, exact compensation replaced the record after this
            // tick checked it. Re-read the selected pointer next tick instead
            // of stopping a listener using that stale desired key.
            return .pending
        } catch { return .reject }
    }
}

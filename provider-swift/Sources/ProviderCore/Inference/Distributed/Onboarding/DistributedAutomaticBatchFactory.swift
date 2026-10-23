import Foundation
import Darwin
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// The local API's same-model scaling policy. Initial singleton placement is
/// unchanged. Only queued demand can propose a separately priced native batch;
/// every side effect remains inside the host's deferred post-release factory.
public actor DistributedAutomaticBatchFactory {
    private let providerConfiguration: URL
    private let paths: ClusterUserPaths
    private let announce: @Sendable (DistributedInstalledStopNotice) -> Void
    private let environment: [String: String]
    private var attempts = DistributedAutomaticBatchAttempt()

    public init(providerConfiguration: URL,
                stopNotice: @escaping @Sendable (DistributedInstalledStopNotice) -> Void) throws {
        self.providerConfiguration = providerConfiguration
        paths = try ClusterUserPaths(); announce = stopNotice
        environment = ProcessInfo.processInfo.environment
    }

    public func replacement(for demand: DistributedLocalBatchDemand) async throws -> DistributedLocalBatchReplacement? {
        // An explicit diagnostic choice keeps its meaning. This path never
        // changes an installed coordinator-approved native member contract.
        guard environment[DistributedInstalledPlan.batchLanesSwitch] == nil,
              environment[ClusterForcedModeSetting.environmentName] == nil,
              environment[ClusterHandOffModes.environmentName] == nil,
              demand.waitingRequests > 0, demand.currentCapacity < 8,
              let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: demand.runtimeModelID),
              [.qwen35Dense, .qwen35RoutedExperts, .qwen35PrismHadamard, .nemotronH, .gemma4LayerStage, .gptossLayerStage, .mimoV26LayerStage].contains(adapter),
              let child = ClusterService.publishedLive()?.child,
              child.running, child.pid == getpid(), child.configurationSHA256 != nil else { return nil }
        let total = min(8, max(0, demand.activeRequests)) + min(8, demand.waitingRequests)
        let widths = ClusterPlacementBatchScope.candidateWidths(waitingRequests: total)
            .filter { $0 > demand.currentCapacity }
        guard !widths.isEmpty, attempts.begin() else { return nil }
        let planner = DistributedAutomaticBatchPlanner(providerConfiguration: providerConfiguration, paths: paths)
        let reference = try ClusterConfigurationStore.installedReference(providerConfiguration: providerConfiguration)
        guard child.configurationSHA256 == reference.sha256 else { return nil }
        let preview = try await Task.detached {
            try planner.snapshot(reference: reference, demand: demand, widths: widths, requireNow: false)
        }.value
        guard let preview else { return nil }
        clusterObservabilityLog(.info, "cluster.batch_replan proposal lanes=\(preview.lanes)", [
            "requested_lanes": String(preview.lanes), "previous_lanes": String(demand.currentCapacity),
            "previous_setup_sha256": reference.sha256, "generation_id": demand.generationID.uuidString.lowercased(),
            "pid": String(getpid()),
        ])
        let transition = DistributedAutomaticBatchTransition(planner: planner, preview: preview,
            demand: demand, announce: announce)
        return .init(requestedCapacity: preview.lanes,
            makeSession: { try await transition.prepareReplacement() },
            restorePreviousSession: { try await transition.restorePrevious() })
    }
}

/// Pair-control adoption after native release. The host serializes these two
/// closures and independently verifies the returned session before publishing.
/// A follower control client alone owns no native worker; waiting for its exact
/// launched setup digest prevents an old width/cut from entering the new epoch.
private final class DistributedAutomaticBatchTransition: @unchecked Sendable {
    let planner: DistributedAutomaticBatchPlanner
    let preview: DistributedAutomaticBatchPlanner.Snapshot
    let demand: DistributedLocalBatchDemand
    let announce: @Sendable (DistributedInstalledStopNotice) -> Void
    private let lock = NSLock()
    private var attempted: DistributedAutomaticBatchPlanner.Snapshot?

    init(planner: DistributedAutomaticBatchPlanner, preview: DistributedAutomaticBatchPlanner.Snapshot,
         demand: DistributedLocalBatchDemand, announce: @escaping @Sendable (DistributedInstalledStopNotice) -> Void) {
        self.planner = planner; self.preview = preview; self.demand = demand; self.announce = announce
    }

    func prepareReplacement() async throws -> DistributedInstalledSession {
        try await Task.detached {
            try self.withCommandLock {
                // Free memory measured with the old weights still resident is
                // never credited back by arithmetic. Re-probe after release.
                guard let fresh = try self.planner.snapshot(reference: self.preview.reference, demand: self.demand,
                    widths: [self.preview.lanes], requireNow: true) else {
                    throw ClusterConfigurationError.invalid("The queued batch no longer fits both Macs after release")
                }
                self.lock.withLock { self.attempted = fresh }
                let context = self.planner.context(configuration: fresh.configuration)
                let peer = fresh.configuration.peers[1]
                guard let peerBytes = fresh.setup.configurations[peer.id],
                      let localBytes = fresh.setup.configurations[fresh.configuration.memberID] else {
                    throw ClusterConfigurationError.invalid("The batch plan omitted a saved rank")
                }
                let peerReference = try self.sendSetup(context: context, previous: fresh.peerPreviousSHA256, bytes: peerBytes)
                try self.waitForPeer(context: context, sha256: peerReference.sha256)
                let reference = try self.adoptLocal(previous: fresh.reference, bytes: localBytes)
                return try self.prepare(reference: reference, action: "prepared")
            }
        }.value
    }

    func restorePrevious() async throws -> DistributedInstalledSession {
        try await Task.detached {
            try self.withCommandLock {
                let context = self.planner.context(configuration: self.preview.configuration)
                // A lost reply is not proof that the peer kept its old setup.
                // Query its full selected digest and accept only either side
                // of this exact transaction before attempting compensation.
                guard case .reached(let report, _) = context.reachPeer(), let observed = report.saved.setup else {
                    throw ClusterConfigurationError.invalid("The paired setup could not be checked for rollback")
                }
                let attempted = self.lock.withLock { self.attempted }
                let peerID = self.preview.configuration.peers[1].id
                let candidateHash = attempted?.setup.configurations[peerID].map(ClusterConfigurationCodec.sha256)
                guard observed.configurationSHA256 == self.preview.peerPreviousSHA256
                        || observed.configurationSHA256 == candidateHash else {
                    throw ClusterConfigurationError.invalid("The paired setup changed outside this batch transition")
                }
                if observed.configurationSHA256 != self.preview.peerPreviousSHA256 {
                    _ = try self.sendSetup(context: context, previous: observed.configurationSHA256,
                        bytes: self.preview.peerPreviousConfiguration)
                }
                try self.waitForPeer(context: context, sha256: self.preview.peerPreviousSHA256)
                let current = try ClusterConfigurationStore.installedReference(providerConfiguration: self.planner.providerConfiguration)
                let localCandidateHash = attempted?.setup.configurations[self.preview.configuration.memberID].map(ClusterConfigurationCodec.sha256)
                guard current == self.preview.reference || current.sha256 == localCandidateHash else {
                    throw ClusterConfigurationError.invalid("The local setup changed outside this batch transition")
                }
                if current != self.preview.reference {
                    let bytes = try ClusterConfigurationFiles.read(URL(fileURLWithPath: self.preview.reference.configuration),
                        maximum: ClusterConfigurationCodec.maximumBytes, privateMode: true)
                    let restored = try self.adoptLocal(previous: current, bytes: bytes)
                    guard restored == self.preview.reference else {
                        throw ClusterConfigurationError.invalid("Rollback did not restore the exact previous setup")
                    }
                }
                return try self.prepare(reference: self.preview.reference, action: "rollback_prepared")
            }
        }.value
    }

    private func withCommandLock<T>(_ body: () throws -> T) throws -> T {
        let directory = ClusterSetupPaths(paths: planner.paths).directory
        guard let control = ClusterControlCommandLock.acquire(seconds: 5, file: directory.appendingPathComponent("control.lock")) else {
            throw ClusterConfigurationError.invalid("Another cluster operation is changing the setup")
        }
        defer { control.release() }
        return try body()
    }

    private func command(context: LiveContext, _ value: ClusterServiceCommand, seconds: Double) throws -> Data {
        guard let pairing = context.linkPairing() else {
            throw ClusterConfigurationError.invalid("Automatic batching requires the saved paired control link")
        }
        return try ClusterSetupLinkExchange.command(pairing: pairing, selection: context.linkSelection(), peerAddress: nil,
            body: JSONEncoder().encode(value), seconds: seconds).reply
    }

    private func sendSetup(context: LiveContext, previous: String, bytes: Data) throws -> ClusterConfigurationReference {
        var request = ClusterServiceCommand(op: .batchSetup)
        request.batchSetup = .init(previousSHA256: previous, configuration: bytes)
        let result = try JSONDecoder().decode(ClusterConfigurationReference.self, from: command(context: context, request, seconds: 15))
        guard result.sha256 == ClusterConfigurationCodec.sha256(bytes) else {
            throw ClusterConfigurationError.invalid("The paired Mac adopted a different batch setup")
        }
        return result
    }

    private func waitForPeer(context: LiveContext, sha256: String) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            let status = try JSONDecoder().decode(ClusterServiceStatus.self,
                from: command(context: context, .init(op: .status), seconds: 5))
            if ClusterAutomaticBatchSetup.peerHasAdopted(status, sha256: sha256) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ClusterConfigurationError.invalid("The paired Mac did not launch the exact replacement setup")
    }

    private func adoptLocal(previous: ClusterConfigurationReference, bytes: Data) throws -> ClusterConfigurationReference {
        let directory = ClusterSetupPaths(paths: planner.paths).directory
        let targetHash = ClusterConfigurationCodec.sha256(bytes)
        let target = try ClusterConfigurationReference(configuration: planner.paths.configurationURL(sha256: targetHash).path,
            sha256: targetHash)
        guard let service = ClusterService.publishedLive(), service.child.running,
              service.child.pid == getpid(), let started = service.child.startedAt else {
            throw ClusterConfigurationError.invalid("The API supervisor no longer owns this process")
        }
        let normalHandoff = service.child.configurationSHA256 == previous.sha256
        if !normalHandoff {
            guard service.child.configurationSHA256 == target.sha256,
                  let prior = try? JSONDecoder().decode(ClusterAutomaticSetupHandoff.self, from:
                    ClusterConfigurationFiles.read(ClusterAutomaticSetupHandoff.file(in: directory), maximum: 4096, privateMode: true)),
                  prior.permitsRollback(processID: getpid(), startedAt: started, candidate: previous,
                    target: target, now: Date().timeIntervalSince1970) else {
                throw ClusterConfigurationError.invalid("The API supervisor no longer owns this exact setup transition")
            }
        }
        var handoff: ClusterAutomaticSetupHandoff?
        var requiresAcknowledgement = true
        let reference = try ClusterAutomaticBatchSetup(previousSHA256: previous.sha256, configuration: bytes).apply(
            paths: planner.paths, providerConfigurations: [planner.providerConfiguration, try ConfigManager.defaultConfigPath()],
            directory: directory) { old, new in
                let published = try ClusterAutomaticSetupHandoff.publish(directory: directory, processID: getpid(),
                    startedAt: started, previous: old, replacement: new, compensatingUnacknowledged: !normalHandoff)
                handoff = published.record
                requiresAcknowledgement = published.requiresAcknowledgement
            }
        guard let handoff else { return reference }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let ack = try JSONDecoder().decode(ClusterAutomaticSetupHandoff.self, from:
                ClusterConfigurationFiles.read(ClusterAutomaticSetupHandoff.file(in: directory), maximum: 4096, privateMode: true))
            if ack.id == handoff.id, !requiresAcknowledgement || ack.acknowledged,
               ClusterService.publishedLive()?.child.configurationSHA256 == reference.sha256 { return reference }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ClusterConfigurationError.invalid("The API supervisor did not acknowledge the exact batch handoff")
    }

    private func prepare(reference: ClusterConfigurationReference, action: String) throws -> DistributedInstalledSession {
        func requireSelected() throws {
            for file in [planner.providerConfiguration, try ConfigManager.defaultConfigPath()] {
                guard try ClusterConfigurationStore.installedReference(providerConfiguration: file) == reference else {
                    throw ClusterConfigurationError.invalid("The selected and installed-owner setups changed during preparation")
                }
            }
        }
        try requireSelected()
        let session = try DistributedInstalledSession.prepare(reference: reference)
        try requireSelected()
        session.installStopNoticeHandler(announce)
        clusterObservabilityLog(.info, "cluster.batch_replan " + action, [
            "setup_sha256": reference.sha256, "pid": String(getpid()),
        ])
        return session
    }
}

import Foundation
import DarkbloomClusterProtocol

/// The cluster service's half of the derived control leader (`ClusterControlNode`): the lease on its own control
/// listener (pairing-keyed, S07; nothing else is answered there), the claim persisted in this Mac's setup record,
/// what this Mac runs for each mode (its part, degraded serving alone, or nothing), and `darkbloom cluster` commands
/// forwarded from any member to the leader.
extension ClusterService {
    enum PartWant: Equatable {
        /// Leave whatever runs as it is (the leader waits for its members to confirm).
        case keep
        case none
        /// This Mac's part of the saved setup.
        case cluster
        /// Degraded: the model on this Mac alone.
        case solo(String)
    }

    /// The rank lease's own cadence and time-to-live (S03): the control lease renews and expires with it.
    static var leaseRenewSeconds: Double { Double(ClusterWorkerLease.renewNanoseconds) / 1e9 }
    static var leaseTTLSeconds: Double { Double(ClusterWorkerLease.ttlNanoseconds) / 1e9 }

    static func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    func partWanted(serving: Bool, hasSetup: Bool, model: String?) -> PartWant {
        let now = Self.monotonicSeconds()
        guard let mode = lock.withLock({ control?.mode(now: now) }), let node = lock.withLock({ control }) else {
            return serving && hasSetup ? .cluster : .none
        }
        switch mode {
        case .following: return serving && hasSetup && node.leaderRunsCluster ? .cluster : .none
        case .cluster: return serving && hasSetup ? .cluster : .none
        case .confirming: return .keep
        case .idle, .cannotServe: return .none
        case .alone: return serving ? model.map { .solo($0) } ?? .none : .none
        }
    }

    func leadsAndRunsCluster() -> Bool {
        let now = Self.monotonicSeconds()
        return lock.withLock { control.map { $0.leads && $0.mode(now: now) == .cluster } ?? false }
    }

    // MARK: - This Mac's facts

    func localControlMember(pairing: ClusterSetupLinkExchange.Pairing, record: ClusterSetupRecord?) -> ClusterControlMember {
        let hardware: (name: String, memoryBytes: UInt64, gpuCores: Int) = lock.withLock { localHardware } ?? {
            let detected = try? HardwareDetector.detect()
            let value = (ClusterPairingProvider.displayName(chipName: detected?.chipName ?? "Mac"), ProcessInfo.processInfo.physicalMemory,
                         Int(detected?.gpuCores ?? 0))
            lock.withLock { localHardware = value }
            return value
        }()
        let learned = lock.withLock { control?.members[pairing.localMemberID]?.holdsModelAlone }
        let alone = record?.aloneHolders.map { $0.contains(pairing.localMemberID) } ?? learned
        return .init(memberID: pairing.localMemberID, name: hardware.name, memoryBytes: hardware.memoryBytes, gpuCores: hardware.gpuCores,
                     holdsModelAlone: alone)
    }

    /// The saved setup's members in rank order (rank 0 first); nil before a plan is adopted.
    func rankOrder() -> [String]? {
        guard let configuration = context.savedConfiguration().configuration else { return nil }
        return configuration.peers.sorted { $0.rank < $1.rank }.map(\.id)
    }

    // MARK: - The control listener

    func ensureControlResponder(say: @escaping @Sendable (String) -> Void) {
        guard lock.withLock({ controlResponder == nil }), let pairing = try? ClusterSetupLinkExchange.pairing(),
              let selection = try? context.linkSelection() else { return }
        do {
            let created = try ClusterSetupLinkExchange.Responder(pairing: pairing, selection: selection,
                port: ClusterSetupLinkExchange.controlPort, epochLabel: ClusterSetupLinkExchange.controlLabel,
                answer: { throw ClusterSetupFailure("the control listener reports nothing") },
                receive: { _ in throw ClusterSetupFailure("the control listener takes no setup") },
                command: { [weak self] data in
                    guard let self else { throw ClusterSetupFailure("the service is stopping") }
                    return try self.receiveLease(data, pairing: pairing, say: say)
                })
            try created.start()
            lock.withLock { controlResponder = created }
        } catch {
            // Tried again at the next tick.
        }
    }

    private func receiveLease(_ data: Data, pairing: ClusterSetupLinkExchange.Pairing, say: @escaping @Sendable (String) -> Void) throws -> Data {
        let command = try JSONDecoder().decode(ClusterServiceCommand.self, from: data)
        guard command.op == .lease, let offered = command.claim else { throw ClusterSetupFailure("the control listener takes leases only") }
        ensureControl(pairing: pairing)
        let now = Self.monotonicSeconds()
        let facts = command.facts ?? []
        let result: (answer: ClusterControlNode.LeaseAnswer, actions: [ClusterControlNode.Action])? = lock.withLock {
            guard control != nil else { return nil }
            // What the leader knows of this Mac's fit for the model alone (it adopted the plan) is kept here too.
            if var own = control!.members[pairing.localMemberID], let mine = facts.first(where: { $0.memberID == own.memberID }),
               let alone = mine.holdsModelAlone {
                own.holdsModelAlone = alone
                control!.learn(own)
            }
            return control!.receiveLease(from: pairing.peerMemberID, offered: offered, running: command.running ?? false, facts: facts, now: now)
        }
        guard let result else { throw ClusterSetupFailure("this Mac's control is not ready") }
        if facts.contains(where: { $0.holdsModelAlone != nil }) {
            let holders = facts.filter { $0.holdsModelAlone == true }.map(\.memberID).sorted()
            try? store.updateRecord { if $0.aloneHolders != holders { $0.aloneHolders = holders } }
        }
        report(result.actions, say: say)
        persistControl()
        return try JSONEncoder().encode(result.answer)
    }

    // MARK: - Each tick

    func ensureControl(pairing: ClusterSetupLinkExchange.Pairing) {
        guard lock.withLock({ control == nil }), let record = try? store.readRecord(), let leadership = record.leadership,
              leadership.peerPin == pairing.peerPin else { return }
        let local = localControlMember(pairing: pairing, record: record)
        var members = record.control?.members ?? []
        if !members.contains(where: { $0.memberID == pairing.peerMemberID }) {
            members.append(.init(memberID: pairing.peerMemberID, name: leadership.peerName, memoryBytes: 0, gpuCores: 0))
        }
        members.removeAll { $0.memberID == local.memberID }
        members.append(local)
        // Before the service first derived a claim, the Mac that drove the onboarding leads at term 0.
        let leaderID = ClusterSetupMemberFacts.memberID(pin: leadership.leaderPin)
        let claim = record.control?.claim ?? ClusterControlClaim(term: 0, leaderID: leaderID, members: [local.memberID, pairing.peerMemberID],
            reason: "drove the onboarding (no plan adopted yet)")
        let node = ClusterControlNode(localID: local.memberID, members: members, claim: claim, rankOrder: rankOrder(),
                                      now: Self.monotonicSeconds(), ttl: Self.leaseTTLSeconds)
        lock.withLock { if control == nil { control = node } }
    }

    func controlTick(say: @escaping @Sendable (String) -> Void) {
        guard let pairing = try? ClusterSetupLinkExchange.pairing() else { return }
        ensureControl(pairing: pairing)
        let record = try? store.readRecord()
        let local = localControlMember(pairing: pairing, record: record)
        let order = rankOrder()
        let now = Self.monotonicSeconds()
        let due: (actions: [ClusterControlNode.Action], claim: ClusterControlClaim, facts: [ClusterControlMember], running: Bool, line: String)? = lock.withLock {
            guard control != nil else { return nil }
            control!.learn(local)
            control!.rankOrder = order
            let actions = control!.tick(now: now)
            let node = control!
            let names = node.members.mapValues(\.name)
            let line = ClusterControlWords.line(node.mode(now: now), names: names, model: record?.leadership?.modelName)
            let running = node.leads && node.mode(now: now) == .cluster && (record?.leadership?.serving ?? false)
            return (actions, node.claim, Array(node.members.values), running, line)
        }
        guard let due else { return }
        if due.line != lock.withLock({ lastModeLine }) {
            lock.withLock { lastModeLine = due.line }
            say("control (term \(due.claim.term)): " + due.line)
        }
        report(due.actions, say: say)
        for action in due.actions {
            switch action {
            case .lease(let claim, let targets):
                guard now >= lock.withLock({ nextLease }) else { continue }
                lock.withLock { nextLease = now + Self.leaseRenewSeconds }
                for target in targets where target == pairing.peerMemberID {
                    sendLease(claim, running: due.running, facts: due.facts, to: target, pairing: pairing, say: say)
                }
            case .handOver(let claim, let target):
                say("control: handing leadership to \(due.facts.first { $0.memberID == target }?.name ?? target) (term \(claim.term): \(claim.reason))")
                if target == pairing.peerMemberID { sendLease(claim, running: false, facts: due.facts, to: target, pairing: pairing, say: say) }
            case .tookOver, .steppedDown:
                break
            }
        }
        persistControl()
    }

    private func sendLease(_ claim: ClusterControlClaim, running: Bool, facts: [ClusterControlMember], to target: String,
                           pairing: ClusterSetupLinkExchange.Pairing, say: @escaping @Sendable (String) -> Void) {
        let begin: Bool = lock.withLock {
            guard !leaseInFlight, !stopping else { return false }
            leaseInFlight = true
            return true
        }
        guard begin, let selection = try? context.linkSelection() else {
            if begin { lock.withLock { leaseInFlight = false } }
            return
        }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.leaseInFlight = false } }
            let command = ClusterServiceCommand(op: .lease, claim: claim, running: running, facts: facts)
            guard let body = try? JSONEncoder().encode(command),
                  let reply = try? ClusterSetupLinkExchange.lease(pairing: pairing, selection: selection, peerAddress: nil, body: body,
                      seconds: min(4, Self.leaseRenewSeconds)).reply,
                  let answer = try? JSONDecoder().decode(ClusterControlNode.LeaseAnswer.self, from: reply) else { return }
            let now = Self.monotonicSeconds()
            let actions = self.lock.withLock { self.control?.receiveAnswer(from: target, sent: claim, answer: answer, now: now) } ?? []
            self.report(actions, say: say)
            self.persistControl()
        }
    }

    func report(_ actions: [ClusterControlNode.Action], say: @Sendable (String) -> Void) {
        for action in actions {
            switch action {
            case .tookOver(let claim, let from):
                let name = lock.withLock { control?.members[from]?.name } ?? from
                say("control: took over as leader, term \(claim.term) (\(name) stopped renewing its lease for \(Int(Self.leaseTTLSeconds)) s)")
            case .steppedDown(let claim):
                let name = lock.withLock { control?.members[claim.leaderID]?.name } ?? claim.leaderID
                say("control: stepped down; \(name) leads from term \(claim.term) (\(claim.reason))")
            case .lease, .handOver:
                break
            }
        }
    }

    func persistControl() {
        guard let persisted = lock.withLock({ control?.persisted }) else { return }
        try? store.updateRecord { if $0.control != persisted { $0.control = persisted } }
    }

    /// Read under `lock` by `status()`.
    func controlStatusLocked(model: String?) -> ClusterServiceStatus.Control? {
        guard let node = control else { return nil }
        let mode = node.mode(now: Self.monotonicSeconds())
        let word: String
        switch mode {
        case .following: word = "following"
        case .confirming: word = "confirming"
        case .cluster: word = "cluster"
        case .idle: word = "idle"
        case .alone: word = "alone"
        case .cannotServe: word = "cannotServe"
        }
        return .init(leaderID: node.claim.leaderID, leaderName: node.members[node.claim.leaderID]?.name ?? node.claim.leaderID,
                     term: node.claim.term, reason: node.claim.reason, leads: node.leads,
                     line: ClusterControlWords.line(mode, names: node.members.mapValues(\.name), model: model), mode: word)
    }

    // MARK: - Forwarded `darkbloom cluster` commands

    func executeControl(_ request: ClusterControlRequest, pairing: ClusterSetupLinkExchange.Pairing,
                        say: @Sendable (String) -> Void) -> ClusterControlReply {
        ensureControl(pairing: pairing)
        guard let node = lock.withLock({ control }) else { return .init(lines: ["This Mac's cluster service is still starting."], failed: true) }
        if let refusal = ClusterControlRouting.refusal(localID: node.localID, claim: node.claim, names: node.members.mapValues(\.name)) {
            return .init(lines: ["The command did not run: " + refusal + "."], failed: true, leaderID: node.claim.leaderID)
        }
        // One forwarded command at a time: the plan a member chose from is the one it adopts.
        controlCommands.lock()
        defer { controlCommands.unlock() }
        say("control: running `\(request.op.rawValue)` for \(node.members[pairing.peerMemberID]?.name ?? "the other Mac")")
        return controlLive.execute(request, leaderID: node.localID)
    }

    /// This Mac's verify-teardown summary (no cluster process, wired memory at its idle baseline, no journal or bootstrap left).
    static func teardownLines() -> [String] {
        let name = ClusterPairingProvider.displayName(chipName: (try? HardwareDetector.detect().chipName) ?? "Mac")
        do {
            let report = try ClusterOrphanSweep.verify(baselineWiredBytes: nil, samples: 3)
            var line = "\(name): " + (report.passed ? "teardown verified, nothing left" : "teardown NOT clean: " + report.reasons.joined(separator: "; "))
            if let wired = report.wired {
                line += " (wired \((wired.samples.min() ?? 0) >> 20) MiB, baseline \(wired.baselineBytes >> 20) MiB)"
            }
            return [line]
        } catch {
            return ["\(name): teardown check failed: \(ClusterConsoleText.bounded(String(describing: error), maximum: 160))"]
        }
    }
}

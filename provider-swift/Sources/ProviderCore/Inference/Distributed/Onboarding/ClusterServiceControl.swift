import Foundation
import DarkbloomClusterProtocol

/// The cluster service's half of the derived control leader (`ClusterControlNode`): the lease on its own control
/// listener (pairing-keyed, S07; nothing else is answered there), the claim persisted in this Mac's setup record,
/// what this Mac runs for each mode (its part, degraded serving alone, or nothing), and `darkbloom cluster` commands
/// forwarded from any member to the leader.
extension ClusterService {
    typealias PartWant = ClusterControlPartChoice

    /// The rank lease's own cadence and time-to-live (S03): the control lease renews and expires with it.
    static var leaseRenewSeconds: Double { Double(ClusterWorkerLease.renewNanoseconds) / 1e9 }
    static var leaseTTLSeconds: Double { Double(ClusterWorkerLease.ttlNanoseconds) / 1e9 }

    /// The control clock keeps counting through system sleep (a woken leader must not count a member that left
    /// during the sleep as present).
    static func monotonicSeconds() -> Double { ClusterControlClock.seconds() }

    /// Owner decision 6's absence grace before serving alone: 600 s; a DEBUG (developer) build may shorten it for tests.
    static var soloGraceSeconds: Double {
        #if DEBUG
        ClusterControlSoloGrace.seconds(environment: ProcessInfo.processInfo.environment, debugBuild: true)
        #else
        ClusterControlSoloGrace.seconds(environment: [:], debugBuild: false)
        #endif
    }

    func partWanted(serving: Bool, hasSetup: Bool, model: String?, runningSolo: Bool) -> PartWant {
        let now = Self.monotonicSeconds()
        // Until this Mac's control is derived (the first ticks after a start) nothing starts: a restarted leader
        // whose claim was superseded while it was away must not start its part before it learns so.
        guard let node = lock.withLock({ control }) else { return .keep }
        return ClusterControlPartChoice.want(mode: node.mode(now: now), serving: serving, hasSetup: hasSetup,
                                             leaderRunsCluster: node.leaderRunsCluster, runningSolo: runningSolo, model: model)
    }

    /// Whether this Mac may act as the leader now (`ClusterControlNode.leadershipConfirmed`).
    func leadershipConfirmed() -> Bool {
        let now = Self.monotonicSeconds()
        return lock.withLock { control?.leadershipConfirmed(now: now) ?? false }
    }

    func leadsAndRunsCluster() -> Bool {
        let now = Self.monotonicSeconds()
        return lock.withLock { control.map { $0.leads && $0.mode(now: now) == .cluster } ?? false }
    }

    // MARK: - This Mac's facts

    func localControlMember(pairing: ClusterSetupLinkExchange.Pairing, record: ClusterSetupRecord?) -> ClusterControlMember {
        let hardware: (name: String, memoryBytes: UInt64, gpuCores: Int, chipFamily: ChipFamily) = lock.withLock { localHardware } ?? {
            let detected = try? HardwareDetector.detect()
            let value = (ClusterPairingProvider.displayName(chipName: detected?.chipName ?? "Mac"), ProcessInfo.processInfo.physicalMemory,
                         Int(detected?.gpuCores ?? 0), detected?.chipFamily ?? .unknown)
            lock.withLock { localHardware = value }
            return value
        }()
        // Only a verdict recorded for the plan saved now counts (unknown: never serve alone); this Mac's own check
        // narrows it (F14): the solo server runs `start --local`, which refuses a model single-Mac Darkbloom does not
        // serve on this Mac, so a planner verdict on memory alone would restart a solo server every 30 s for ever.
        let configuration = context.savedConfiguration().configuration
        let planned = ClusterControlAloneVerdicts.holds(pairing.localMemberID, holders: record?.aloneHolders,
                                                        forPlan: record?.aloneHoldersPlan, savedPlan: configuration?.selectedPlanSHA256)
        let model = configuration?.publicModelID
        let missing = model.map { Self.soloMissingHardware(modelID: $0, chipFamily: hardware.chipFamily) } ?? []
        let soloKey = Self.soloKey(plan: configuration?.selectedPlanSHA256, model: model ?? "")
        let quickEnds = lock.withLock { soloQuickEnds?.key == soloKey ? soloQuickEnds!.count : 0 }
        let verdict = ClusterControlSoloAdmission.decide(planned: planned, missingHardware: missing, quickEnds: quickEnds)
        return .init(memberID: pairing.localMemberID, name: hardware.name, memoryBytes: hardware.memoryBytes, gpuCores: hardware.gpuCores,
                     holdsModelAlone: verdict.holds, aloneRefusal: verdict.refusal)
    }

    /// The model's runtime requirements as single-Mac Darkbloom applies them (`ModelRuntimeRequirements`, the same gate
    /// `start --local` uses) that this Mac's hardware settles and lacks. The capabilities hardware settles are what the
    /// product's detector grants from the chip family alone, over every family it knows (no chip list here).
    static func soloMissingHardware(modelID: String, chipFamily: ChipFamily) -> [String] {
        let required = ModelRuntimeRequirements.requiredCapabilities(for: modelID)
        guard !required.isEmpty else { return [] }
        func fromChip(_ family: ChipFamily) -> Set<ProviderRuntimeCapability> {
            DistributedServingEligibility.memberCapabilities(chipFamily: family)
        }
        let settled = ChipFamily.allCases.reduce(into: Set<ProviderRuntimeCapability>()) { $0.formUnion(fromChip($1)) }
        return ClusterControlSoloAdmission.missingHardware(required: Set(required.map(\.rawValue)), hardwareSettled: Set(settled.map(\.rawValue)),
                                                           hardware: Set(fromChip(chipFamily).map(\.rawValue)))
    }

    static func soloKey(plan: String?, model: String) -> String { (plan ?? "") + "|" + model }

    /// The saved setup's selected plan (the same signed plan on every member); nil before a plan is adopted.
    func savedPlanSHA256() -> String? { context.savedConfiguration().configuration?.selectedPlanSHA256 }

    /// The saved setup's members in rank order (rank 0 first); nil before a plan is adopted.
    func rankOrder() -> [String]? {
        guard let configuration = context.savedConfiguration().configuration else { return nil }
        return configuration.peers.sorted { $0.rank < $1.rank }.map(\.id)
    }

    // MARK: - The control listener

    func ensureControlResponder(say: @escaping @Sendable (String) -> Void) {
        // The lease listener follows the cable to another port too (`cableMove`), or leases never reach this Mac there.
        if cableMove(of: lock.withLock({ controlResponder }), checked: \.controlCableCheck) != nil {
            lock.withLock { controlResponder }?.stop()
            lock.withLock { controlResponder = nil }
        }
        guard lock.withLock({ controlResponder == nil }), let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore),
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
        // The leader's alone verdicts count only for the plan saved here (a lease that arrives before this Mac applied
        // a new setup, or one for an older plan, carries none that count).
        let savedPlan = savedPlanSHA256()
        let facts = ClusterControlAloneVerdicts.gated(command.facts ?? [], forPlan: command.alonePlan, savedPlan: savedPlan)
        let result: (answer: ClusterControlNode.LeaseAnswer, actions: [ClusterControlNode.Action])? = lock.withLock {
            guard control != nil else { return nil }
            return control!.receiveLease(from: pairing.peerMemberID, offered: offered, running: command.running ?? false, facts: facts, now: now)
        }
        guard let result else { throw ClusterSetupFailure("this Mac's control is not ready") }
        // The leader's serving intent, from an accepted lease only: a start or stop typed on the leader while this Mac
        // was away is what this Mac leads with if control moves here (e.g. handed back to rank 0).
        // A write that fails is a stated failure, never "recorded": the lease is refused at the end, so the leader stops
        // counting this Mac as present (its status says so) instead of both Macs waiting for a part that never starts (F17).
        var unrecorded: ClusterSetupFailure?
        if let intent = ClusterControlIntent.toRecord(answer: result.answer, leaderServing: command.serving,
                                                      recorded: (try? store.readRecord())?.leadership?.serving) {
            unrecorded = ClusterLeaseIntentRecording.record(intent, write: { _ = try store.updateRecord { $0.leadership?.serving = intent } },
                                                            say: say)
        }
        // Recorded only from an accepted lease: a refused (stale) leader never rewrites what this Mac may serve alone.
        if let verdicts = ClusterControlAloneVerdicts.toRecord(answer: result.answer, facts: facts, forPlan: command.alonePlan, savedPlan: savedPlan) {
            try? store.updateRecord {
                if $0.aloneHolders != verdicts.holders || $0.aloneHoldersPlan != verdicts.plan {
                    $0.aloneHolders = verdicts.holders; $0.aloneHoldersPlan = verdicts.plan
                }
            }
            let own = localControlMember(pairing: pairing, record: try? store.readRecord())
            lock.withLock { _ = control?.learn(own) }
        }
        report(result.actions, say: say)
        persistControl()
        if let unrecorded { throw unrecorded }
        return try JSONEncoder().encode(result.answer)
    }

    // MARK: - Each tick

    func ensureControl(pairing: ClusterSetupLinkExchange.Pairing) {
        // A node of an earlier pairing (this Mac was re-paired with another Mac while the service ran) is dropped.
        lock.withLock { if let node = control, !node.claim.members.contains(pairing.peerMemberID) { control = nil } }
        guard lock.withLock({ control == nil }), let record = try? store.readRecord(), let leadership = record.leadership,
              leadership.peerPin == pairing.peerPin else { return }
        let local = localControlMember(pairing: pairing, record: record)
        // Before the service first derived a claim, the Mac that drove the onboarding leads at term 0; a record of an
        // earlier pairing (another Mac) is not carried into this one.
        let start = ClusterControlRestart.start(persisted: record.control, localID: local.memberID, peerID: pairing.peerMemberID,
                                                onboardingLeaderID: ClusterSetupMemberFacts.memberID(pin: leadership.leaderPin))
        var members = start.members
        if !members.contains(where: { $0.memberID == pairing.peerMemberID }) {
            members.append(.init(memberID: pairing.peerMemberID, name: leadership.peerName, memoryBytes: 0, gpuCores: 0))
        }
        members.removeAll { $0.memberID == local.memberID }
        members.append(local)
        let claim = start.claim
        let node = ClusterControlNode(localID: local.memberID, members: members, claim: claim, rankOrder: rankOrder(),
                                      now: Self.monotonicSeconds(), ttl: Self.leaseTTLSeconds, soloGrace: Self.soloGraceSeconds)
        lock.withLock { if control == nil { control = node } }
    }

    func controlTick(say: @escaping @Sendable (String) -> Void) {
        guard let pairing = try? ClusterSetupLinkExchange.pairing(store: pairingStore) else { return }
        ensureControl(pairing: pairing)
        let record = try? store.readRecord()
        let local = localControlMember(pairing: pairing, record: record)
        let order = rankOrder()
        // The verdicts this Mac sends are those recorded for the plan saved now, named by it; none otherwise.
        let savedPlan = savedPlanSHA256()
        let alonePlan = record?.aloneHoldersPlan != nil && record?.aloneHoldersPlan == savedPlan ? savedPlan : nil
        let now = Self.monotonicSeconds()
        let due: (actions: [ClusterControlNode.Action], claim: ClusterControlClaim, facts: [ClusterControlMember], running: Bool, line: String,
                  logKey: String, alonePlan: String?)? = lock.withLock {
            guard control != nil else { return nil }
            control!.learn(local)
            control!.rankOrder = order
            let actions = control!.tick(now: now)
            let node = control!
            let names = node.members.mapValues(\.name)
            let line = ClusterControlWords.line(node.mode(now: now), names: names, model: record?.leadership?.modelName,
                                                aloneRefusal: node.members[node.localID]?.aloneRefusal)
            let logKey = ClusterControlWords.logKey(node.mode(now: now), line: line)
            // Members run their parts while the cluster runs and while the leader waits for a member inside the grace.
            let running = node.leads && ClusterControlPartChoice.leaseSaysRunning(mode: node.mode(now: now), serving: record?.leadership?.serving ?? false)
            // Each member's fit for the model alone, as the plan's adopter recorded it, travels with the lease (the
            // planner's verdicts, which members record; each Mac narrows its own by its own check, F14, and answers
            // with that, so a Mac's solo-server record never rewrites what the other Mac records).
            let facts = node.members.values.map { fact -> ClusterControlMember in
                var fact = fact
                fact.aloneRefusal = nil
                fact.holdsModelAlone = alonePlan == nil ? nil : record?.aloneHolders.map { $0.contains(fact.memberID) }
                return fact
            }
            return (actions, node.claim, facts, running, line, logKey, alonePlan)
        }
        guard let due else { return }
        if due.logKey != lock.withLock({ lastModeLine }) {
            lock.withLock { lastModeLine = due.logKey }
            say("control (term \(due.claim.term)): " + due.line)
        }
        report(due.actions, say: say)
        for action in due.actions {
            switch action {
            case .lease(let claim, let targets):
                guard now >= lock.withLock({ nextLease }) else { continue }
                lock.withLock { nextLease = now + Self.leaseRenewSeconds }
                for target in targets where target == pairing.peerMemberID {
                    sendLease(claim, running: due.running, facts: due.facts, alonePlan: due.alonePlan, to: target, pairing: pairing, say: say)
                }
            case .handOver(let claim, let target):
                // Never while a forwarded command runs here (it would run on a Mac that stops leading midway, and its
                // effect could be undone by the new leader): offered again at the next tick. The command waits for the
                // hand-over's exchange in turn, then finds this Mac no longer leads and is routed to the new leader.
                guard target == pairing.peerMemberID, let held = ClusterControlCommandLock.acquire(seconds: 0) else { continue }
                say("control: handing leadership to \(due.facts.first { $0.memberID == target }?.name ?? target) (term \(claim.term): \(claim.reason))")
                sendLease(claim, running: false, facts: due.facts, alonePlan: due.alonePlan, to: target, pairing: pairing, say: say,
                          done: { held.release() })
            case .tookOver, .steppedDown:
                break
            }
        }
        persistControl()
    }

    /// `done` runs once the exchange is over (or was not started), on whichever thread finished it.
    private func sendLease(_ claim: ClusterControlClaim, running: Bool, facts: [ClusterControlMember], alonePlan: String?, to target: String,
                           pairing: ClusterSetupLinkExchange.Pairing, say: @escaping @Sendable (String) -> Void,
                           done: (@Sendable () -> Void)? = nil) {
        let begin: Bool = lock.withLock {
            guard !leaseInFlight, !stopping else { return false }
            leaseInFlight = true
            return true
        }
        guard begin, let selection = try? context.linkSelection() else {
            if begin { lock.withLock { leaseInFlight = false } }
            done?()
            return
        }
        Thread.detachNewThread { [weak self] in
            defer { done?() }
            guard let self else { return }
            defer { self.lock.withLock { self.leaseInFlight = false } }
            // The serving intent is read as the lease leaves (a hand-over holds the command lock, so no start or stop
            // changes it meanwhile): the Mac that accepts records it, and leads with it if control moves there.
            let intent = (try? self.store.readRecord())?.leadership?.serving
            let command = ClusterServiceCommand(op: .lease, claim: claim, running: running, facts: facts, alonePlan: alonePlan, serving: intent)
            let answer: ClusterControlNode.LeaseAnswer
            do {
                let body = try JSONEncoder().encode(command)
                let reply = try ClusterSetupLinkExchange.lease(pairing: pairing, selection: selection, peerAddress: nil, body: body,
                                                               seconds: min(4, Self.leaseRenewSeconds)).reply
                answer = try JSONDecoder().decode(ClusterControlNode.LeaseAnswer.self, from: reply)
            } catch {
                // Said once per distinct reason (a member that refuses every lease would otherwise fill the log).
                let reason = ClusterConsoleText.bounded(String(describing: (error as? ClusterSetupFailure)?.text ?? String(describing: error)),
                                                        maximum: 200)
                if self.lock.withLock({ self.lastLeaseProblem }) != reason {
                    self.lock.withLock { self.lastLeaseProblem = reason }
                    say("control: the lease to the other Mac did not go through: \(reason)")
                }
                return
            }
            if self.lock.withLock({ self.lastLeaseProblem }) != nil {
                self.lock.withLock { self.lastLeaseProblem = nil }
                say("control: the other Mac takes the lease again")
            }
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
        let now = Self.monotonicSeconds()
        let mode = node.mode(now: now)
        let word: String
        var soloIn: Int?
        switch mode {
        case .following: word = "following"
        case .confirming: word = "confirming"
        case .cluster: word = "cluster"
        case .idle: word = "idle"
        case .waiting(_, let seconds, _): word = "waiting"; soloIn = seconds
        case .alone: word = "alone"
        case .cannotServe: word = "cannotServe"
        }
        return .init(leaderID: node.claim.leaderID, leaderName: node.members[node.claim.leaderID]?.name ?? node.claim.leaderID,
                     term: node.claim.term, reason: node.claim.reason, leads: node.leads,
                     line: ClusterControlWords.line(mode, names: node.members.mapValues(\.name), model: model,
                                                    aloneRefusal: node.members[node.localID]?.aloneRefusal), mode: word,
                     confirmed: node.leadershipConfirmed(now: now), soloInSeconds: soloIn)
    }

    // MARK: - Forwarded `darkbloom cluster` commands

    func executeControl(_ request: ClusterControlRequest, pairing: ClusterSetupLinkExchange.Pairing,
                        say: @Sendable (String) -> Void) -> ClusterControlReply {
        ensureControl(pairing: pairing)
        guard let node = lock.withLock({ control }) else { return .init(lines: ["This Mac's cluster service is still starting."], failed: true) }
        if let refusal = ClusterControlRouting.refusal(localID: node.localID, claim: node.claim, names: node.members.mapValues(\.name)) {
            return .init(lines: ["The command did not run: " + refusal + "."], failed: true, leaderID: node.claim.leaderID, notLeader: true)
        }
        // A command that acts as the leader waits until this Mac's claim is confirmed (a restarted Mac whose saved claim
        // was superseded steps down on the first refusal and refuses instead of acting).
        if Self.actsAsLeader(request.op) {
            let deadline = Self.monotonicSeconds() + Self.leaseTTLSeconds + 5
            while !leadershipConfirmed(), Self.monotonicSeconds() < deadline, lock.withLock({ control?.leads ?? false }) { usleep(250_000) }
            guard let now = lock.withLock({ control }) else { return .init(lines: ["This Mac's cluster service is stopping."], failed: true) }
            if let refusal = ClusterControlRouting.refusal(localID: now.localID, claim: now.claim, names: now.members.mapValues(\.name)) {
                return .init(lines: ["The command did not run: " + refusal + "."], failed: true, leaderID: now.claim.leaderID, notLeader: true)
            }
            guard leadershipConfirmed() else {
                return .init(lines: ["The command did not run: this Mac's leadership is not confirmed yet; run `darkbloom cluster` again."], failed: true,
                             leaderID: now.claim.leaderID)
            }
        }
        // One acting command at a time on this Mac (the plan a member chose from is the one it adopts), never during a
        // hand-over; read-only ones (status, readiness, test) do not wait for a long model change.
        var held: ClusterControlCommandLock?
        if Self.actsAsLeader(request.op) || request.op == .planModels {
            guard let taken = ClusterControlCommandLock.acquire(seconds: 600) else {
                return .init(lines: ["The command did not run: another cluster command is still running on this Mac; run `darkbloom cluster` again."], failed: true)
            }
            held = taken
        }
        defer { held?.release() }
        // Leadership may have moved while the command waited (a hand-over finished): then it does not run here.
        guard let current = lock.withLock({ control }) else { return .init(lines: ["This Mac's cluster service is stopping."], failed: true) }
        if let refusal = ClusterControlRouting.refusal(localID: current.localID, claim: current.claim, names: current.members.mapValues(\.name)) {
            return .init(lines: ["The command did not run: " + refusal + "."], failed: true, leaderID: current.claim.leaderID, notLeader: true)
        }
        if Self.actsAsLeader(request.op), !leadershipConfirmed() {
            return .init(lines: ["The command did not run: this Mac's leadership is not confirmed yet; run `darkbloom cluster` again."], failed: true,
                         leaderID: current.claim.leaderID)
        }
        say("control: running `\(request.op.rawValue)` for \(node.members[pairing.peerMemberID]?.name ?? "the other Mac")")
        return controlLive.execute(request, leaderID: node.localID)
    }

    /// Commands that change what the cluster runs or its setup: run only by a confirmed leader.
    static func actsAsLeader(_ op: ClusterControlRequest.Operation) -> Bool {
        switch op {
        case .reachMembers, .adopt, .serve, .stop, .scope: return true
        case .status, .planModels, .readiness, .test, .verifyTeardown: return false
        }
    }

    /// A sweep reason in plain words: what it is, without process IDs, byte counts or paths.
    static func plainTeardownReason(_ reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("wired") { return "memory a model held is not released yet" }
        if lower.contains("journal") { return "a device record from a run is still open" }
        if lower.contains("bootstrap") { return "files from a run's start are still there" }
        if lower.contains("worker") || lower.contains("owner") || lower.contains("process") { return "a cluster process" }
        return reason.replacingOccurrences(of: #"\s*\(?pid \d+\)?"#, with: "", options: .regularExpression)
    }

    /// This Mac's verify-teardown summary (no cluster process, wired memory at its idle baseline, no journal or bootstrap left).
    static func teardownLines() -> [String] {
        let name = ClusterPairingProvider.displayName(chipName: (try? HardwareDetector.detect().chipName) ?? "Mac")
        do {
            let report = try ClusterOrphanSweep.verify(baselineWiredBytes: nil, samples: 3)
            // The part the cluster service started is a cluster process too, also when it is no cluster worker or owner
            // (the solo server, the rank 0 server process) and when the service that started it is gone.
            var reasons = report.reasons.map(Self.plainTeardownReason)
            if let part = recordedPart(published()) {
                reasons.append("this Mac's \(part.solo ? "single-Mac server" : "part of the model") is still running")
            }
            // Plain words: what is left, never wired/baseline MiB, cluster homes or process IDs.
            return ["\(name): " + (reasons.isEmpty ? "nothing left running" : "still running: " + reasons.joined(separator: "; "))]
        } catch {
            return ["\(name): could not check what is left running (\(ClusterConsoleText.bounded(String(describing: error), maximum: 120)))"]
        }
    }
}

/// What the lease handler does with the leader's serving intent (F17): write it and say "recorded" only when the write
/// went through. A failed write is said with its reason and returned, and the caller refuses the lease with it.
enum ClusterLeaseIntentRecording {
    static func record(_ intent: Bool, write: () throws -> Void, say: (String) -> Void) -> ClusterSetupFailure? {
        let what = intent ? "the leader serves" : "the leader stopped serving"
        do { try write() } catch {
            let reason = ClusterConsoleText.bounded(String(describing: error), maximum: 160)
            say("\(what): could not record it (\(reason))")
            return ClusterSetupFailure("this Mac could not record that \(what) (\(reason))")
        }
        say("\(what): recorded")
        return nil
    }
}

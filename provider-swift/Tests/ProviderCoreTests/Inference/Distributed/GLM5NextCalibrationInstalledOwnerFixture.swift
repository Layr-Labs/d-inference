import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@_spi(OwnerService) import DarkbloomClusterRemote
@testable import ProviderCore

/// UNRUN CPU fixture. Both Completed values come from actual metadata children;
/// both finite authorizations come from their own owner under actual held locks.
/// In-memory callback routing is explicitly NOT authenticated cable evidence.
/// Finite Python children emit synthetic reports and deliberately do NOT satisfy
/// native bootstrap: successfulReport is never enough for owner.completed().
final class GLM5NextCalibrationInstalledOwnerFixture {
    typealias O = GLM5NextCalibrationInstalledOwner
    typealias C = GLM5NextCalibrationInstalledQuote
    typealias P = GLM5NextCalibrationPeerQuote
    typealias F = GLM5NextCalibrationPeerQuoteFixture
    let seed: F
    let localQuote: C.Completed
    let peerQuote: C.Completed
    var local: O!
    weak var droppedOwner: O?
    let peer: O
    let providerLock: URL
    let peerProviderLock: URL
    let matrix: URL
    let root: URL
    let localDevice: String
    private(set) var context: O.CommitContext?
    private let retirement: RetirementCustody

    enum LocalCustody: Equatable { case retained, observerOnly }
    enum CleanupError: Error, Equatable {
        case invalidJoinTimeout
        case unresolvedRanks([Int])
        case lostRetirementEvidence([Int])
    }

    /// Strong scratch custody; the dedicated caller-drop test observes local
    /// weakly so this fixture cannot replace production owner self-retention.
    private final class RetirementCustody: @unchecked Sendable {
        private struct Slot {
            weak var owner: O?
            let retainedOwner: O?
            let rank: Int
            var exit: O.ActualExit?
            var noLaunchRetired = false
            var lost = false
            var hasEvidence: Bool { noLaunchRetired || exit?.localJournalResolved == true }
            init(_ owner: O, retain: Bool) {
                self.owner = owner; retainedOwner = retain ? owner : nil
                rank = owner.status().rank
            }
        }
        let seed: F
        private let lock = NSLock()
        private var slots: [Slot]
        init(seed: F, local: O, peer: O, retainLocal: Bool) {
            self.seed = seed
            slots = [Slot(local, retain: retainLocal), Slot(peer, retain: true)]
        }

        /// Strong weak-reference loads are scoped to this synchronous call.
        /// Only value evidence/ranks escape; no O is held across an await.
        func snapshot() -> (unresolved: [Int], lost: [Int]) {
            lock.lock(); defer { lock.unlock() }
            for index in slots.indices where !slots[index].hasEvidence {
                guard !slots[index].lost else { continue }
                guard let owner = slots[index].owner else {
                    // Weak disappearance is NOT retirement. Preserve scratch
                    // indefinitely and expose the lost-proof failure to cleanup.
                    slots[index].lost = true
                    continue
                }
                let status = owner.status()
                guard status.journalResolved else { continue }
                if status.observedExit {
                    if let exit = owner.actualExit(), exit.localJournalResolved {
                        slots[index].exit = exit
                    }
                } else if owner.actualExit() == nil {
                    // This is the LIVE owner's real Resources retirement flag,
                    // proving its no-launch transition, never a nil-owner guess.
                    slots[index].noLaunchRetired = true
                }
            }
            return (slots.filter { !$0.hasEvidence }.map(\.rank).sorted(),
                    slots.filter(\.lost).map(\.rank).sorted())
        }

        func forEachObservedOwner(_ body: (O) -> Void) {
            lock.lock(); defer { lock.unlock() }
            for slot in slots {
                if let owner = slot.owner { body(owner) }
            }
        }

        func retainUntilSafeRetirement() async {
            while !snapshot().unresolved.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // This synchronous helper returns before any suspension; observer
            // mode never carries a strong local owner in the task's async frame.
            forEachObservedOwner { $0.cancel() }
            withExtendedLifetime(seed) {}
        }
    }

    init(localCustody: LocalCustody = .retained) throws {
        let seed = try F()
        let base = seed.base, root = base.device.deletingLastPathComponent()
        let matrix = root.appendingPathComponent("matrix.json")
        let peerInput = root.appendingPathComponent("opposite-input.json")
        let peerStore = ClusterPairingStore(directory: root.appendingPathComponent("opposite-pair"))
        // The completed-peer fixture does not need interface orientation; this
        // installed-owner fixture does. Reverse exact pair-relative interfaces.
        var records = try F.jsonObject(Data(contentsOf: peerStore.recordsFile))
        var pairings = records["pairings"] as! [[String: Any]]
        var link = pairings[0]["link"] as! [String: Any]
        let oldLocal = link["localInterface"]!; link["localInterface"] = link["peerInterface"]
        link["peerInterface"] = oldLocal; pairings[0]["link"] = link; records["pairings"] = pairings
        try F.json(records).write(to: peerStore.recordsFile)
        let rank = seed.local.authorized.request.selection.rank
        let names = rank == 0 ? ["rdma_en6", "rdma_en1"] : ["rdma_en1", "rdma_en6"]
        try JSONSerialization.data(withJSONObject: [[NSNull(), names[0]], [names[1], NSNull()]])
            .write(to: matrix)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: matrix.path)
        let original = try String(contentsOf: base.worker, encoding: .utf8)
        let finite = """
        #!/usr/bin/python3
        import base64, hashlib, json, os, sys, time
        if '--glm-calibrate' in sys.argv:
            args = sys.argv[1:]
            directory = args[args.index('--model-dir') + 1]
            doc = json.load(open(args[args.index('--glm-qualification') + 1]))
            payload = base64.b64decode(doc['payload'])
            body = json.loads(payload); p = body['selection']; a = body['authorization']; rank = p['rank']
            credential = sys.stdin.buffer.readline()
            if not credential: sys.exit(7)
            del credential
            with open(directory + '/finite-starts-' + str(rank), 'a') as marker: marker.write('started\\n')
            q = {'authorizationSHA256': hashlib.sha256(payload).hexdigest(), 'descriptorSHA256': 'c' * 64,
                'cut': p['cut'], 'rank': rank, 'nativeBytes': 1400, 'hostBytes': 500,
                'loadCapacityBytes': p['loadCapacityBytes'], 'requestCapacityBytes': p['requestCapacityBytes'],
                'inventorySHA256': 'd' * 64, 'configurationSHA256': 'b' * 64, 'numericalPolicySHA256': 'e' * 64,
                'executionEnvironmentSHA256': hashlib.sha256(json.dumps(p['environment'], sort_keys=True,
                    separators=(',', ':'), ensure_ascii=False).encode()).hexdigest(), 'qualifiesMaximumEnvelope': False}
            phases = ['before-load', 'loaded'] + (['committed-token'] * a['outputCount'] if rank == 0 else []) + ['request-finished']
            report = {'nativeHardCapBytes': a['nativeHardCapBytes'], 'hostBudgetBytes': a['hostBudgetBytes'],
                'osHeadroomBytes': a['osHeadroomBytes'], 'quote': q, 'observations': [
                    {'phase': phase, 'nativeActiveBytes': 10, 'nativePeakBytes': 20,
                     'host': {'mallocBytes': 10, 'processFootprintBytes': 20}} for phase in phases],
                'committedTokens': len(a['promptTokenIDs']) + a['outputCount'] - 1,
                'qualifiesMaximumEnvelope': False, 'requiresProcessExit': True}
            os.write(1, json.dumps(report, sort_keys=True, separators=(',', ':')).encode() + b'\\n')
            with open(directory + '/finite-report-' + str(rank), 'w') as marker: marker.write('provisional')
            release = directory + '/finite-release-' + str(rank)
            hold = directory + '/finite-hold-' + str(rank)
            end = time.monotonic() + 20
            while (not os.path.exists(release) or os.path.exists(hold)) and time.monotonic() < end: time.sleep(.005)
            if not os.path.exists(release) or os.path.exists(hold): sys.exit(12)
            sys.exit(int(open(release).read()))
        """
        try Data((finite + "\n" + original.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")).utf8)
            .write(to: base.worker)
        let workerSHA = try F.hash(base.worker)
        let expiry = Int64(Date().timeIntervalSince1970) + 20
        for file in [base.input, peerInput] {
            var input = try F.jsonObject(Data(contentsOf: file))
            var request = input["request"] as! [String: Any]
            var selection = request["selection"] as! [String: Any]
            var facts = selection["environment"] as! [String: Any]
            var environment = input["environment"] as! [String: String]
            environment["JACCL_IBV_DEVICES"] = matrix.path
            facts["binarySHA256"] = workerSHA
            facts["variableSHA256"] = F.variables(environment)
            selection["expiresUnixSeconds"] = expiry; selection["environment"] = facts
            request["selection"] = selection; input["request"] = request
            input["environment"] = environment; input["peerBinarySHA256"] = workerSHA
            try F.json(input).write(to: file)
        }
        let own = try base.complete()
        let other = try C.complete(input: peerInput, installedExecutable: base.app, deviceDirectory: seed.peerDevice,
            quoteTimeoutNanoseconds: base.timeout, loadPair: { cluster, pin in
                try GLM5NextCalibrationInstalledPair.load(clusterID: cluster, peerPin: pin,
                    store: peerStore, loadSigner: { base.pairing.peer })
            })
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        let now = Int64(Date().timeIntervalSince1970)
        let localSummary = try P.outbound(completed: own, now: now, deadline: deadline)
        let peerSummary = try P.outbound(completed: other, now: now, deadline: deadline)
        let ownPeer = try P.admit(completed: own, receiveFromAuthenticatedPair: { pair, _ in
            #expect(pair.record == own.pair.record); return peerSummary
        }, now: now, deadline: deadline)
        let otherPeer = try P.admit(completed: other, receiveFromAuthenticatedPair: { pair, _ in
            #expect(pair.record == other.pair.record); return localSummary
        }, now: now, deadline: deadline)
        let providerLock = root.appendingPathComponent("owner-provider.pid.lock")
        let peerProviderLock = root.appendingPathComponent("peer-owner-provider.pid.lock")
        func environment(_ lock: URL, device: URL, interface: String) -> O.Resources.Environment {
            .isolatedTests(providerLock: lock, deviceDirectory: device, orphanCheck: {},
                linkReady: { #expect($0 == "rdma_" + interface) },
                requirePhysicalInterface: { selected, actual in
                    #expect(selected == "rdma_" + interface); #expect(actual == interface)
                })
        }
        let local = try O.prepare(completed: own, peer: ownPeer,
            environment: environment(providerLock, device: base.device, interface: "en6"),
            requireCurrentAuthenticatedCustody: { try own.pair.requireUnchanged() })
        let peer: O
        do {
            peer = try O.prepare(completed: other, peer: otherPeer,
                environment: environment(peerProviderLock, device: seed.peerDevice, interface: "en1"),
                requireCurrentAuthenticatedCustody: { try other.pair.requireUnchanged() })
        } catch { local.cancel(); throw error }
        self.seed = seed; self.localQuote = own; self.peerQuote = other
        self.local = local; self.peer = peer; self.root = root; self.matrix = matrix
        self.providerLock = providerLock; self.peerProviderLock = peerProviderLock; localDevice = names[rank]
        let retirement = RetirementCustody(seed: seed, local: local, peer: peer,
            retainLocal: localCustody == .retained)
        self.retirement = retirement
        // Start before fixture escape, including callers that never call cleanup.
        Task {
            await retirement.retainUntilSafeRetirement()
            withExtendedLifetime(retirement) {}
        }
    }

    func commit() throws -> O.CommitContext {
        let localStart = try local.admit(peerDocument: peer.outboundDocument)
        let peerStart = try peer.admit(peerDocument: local.outboundDocument)
        let own = try local.commit(peerStart: peerStart)
        let other = try peer.commit(peerStart: localStart)
        #expect(own.starts.map(\.canonicalBytes) == other.starts.map(\.canonicalBytes))
        #expect(own.binding.route.ownerIncarnation == localStart.ownerIncarnation)
        #expect(own.binding.route.leaseID == localStart.leaseID)
        context = own
        return own
    }
    var rank: Int { localQuote.authorized.request.selection.rank }
    func marker(_ kind: String) -> URL { seed.base.model.appendingPathComponent("finite-" + kind + "-" + String(rank)) }
    func release(code: Int = 0) throws { try Data(String(code).utf8).write(to: marker("release")) }
    func wait(_ condition: () -> Bool, seconds: Double = 3) throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { usleep(5_000) }
        try #require(condition())
    }
    func requireLocksHeld() throws {
        #expect(throws: (any Error).self) { try UpdateProcessLock.acquire(at: providerLock, operation: "test-contender") }
        #expect(throws: (any Error).self) { try ClusterDeviceLease(directoryURL: seed.base.device) }
        #expect(try Data(contentsOf: seed.base.device.appendingPathComponent("native-device.lease")).count > 0)
    }
    /// Sample/caches actual local retirement while a weak observer can still
    /// see it, before closing the CPU bootstrap listener may let O deallocate.
    func requireLocalRetirementEvidence() throws {
        let state = retirement.snapshot()
        guard state.lost.isEmpty else { throw CleanupError.lostRetirementEvidence(state.lost) }
        guard !state.unresolved.contains(rank) else { throw CleanupError.unresolvedRanks([rank]) }
    }

    func cleanupObservationFailure() -> CleanupError? {
        let lost = retirement.snapshot().lost
        return lost.isEmpty ? nil : .lostRetirementEvidence(lost)
    }

    func cleanup() {
        do { try cleanup(joinTimeout: 3) }
        catch { Issue.record("Owner fixture cleanup failed: \(error); scratch remains retained") }
    }

    /// The throwing seam exposes an expected bounded join failure to adversarial
    /// tests; ordinary defer cleanup records that same failure as a test Issue.
    func cleanup(joinTimeout: TimeInterval) throws {
        guard joinTimeout.isFinite, (0...3).contains(joinTimeout) else { throw CleanupError.invalidJoinTimeout }
        retirement.forEachObservedOwner { owner in
            let rank = owner.status().rank
            let marker = seed.base.model.appendingPathComponent("finite-release-" + String(rank))
            try? Data("0".utf8).write(to: marker)
            owner.cancel()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(joinTimeout * 1_000_000_000)
        while true {
            let state = retirement.snapshot()
            guard state.lost.isEmpty else { throw CleanupError.lostRetirementEvidence(state.lost) }
            if state.unresolved.isEmpty {
                retirement.forEachObservedOwner { $0.cancel() }
                return
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                // The independent custody task continues retaining BOTH owners
                // and base/scratch after this bounded observation fails.
                throw CleanupError.unresolvedRanks(state.unresolved)
            }
            usleep(5_000)
        }
    }
}

private extension GLM5NextCalibrationPeerQuoteFixture {
    static func jsonObject(_ bytes: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
}

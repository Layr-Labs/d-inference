import DarkbloomClusterProcess
import Foundation
import Testing
@testable import ProviderCore

/// The actual cluster service loop on the leading Mac of a pair whose setup carries a cluster approval. Its parts are
/// the CPU-only service-part fixture process (one role per route), so the route the service chose is the role that
/// started. Nothing here loads a model.
@Suite("Cluster approval at a service start", .serialized)
struct ClusterApprovalServiceStartTests {
    /// The leader's setup saved with an approval ending `endsIn` seconds from now (in the past: ended): a cluster
    /// approval as the guided setup saves it, or (`handSaved`) a pair approval an operator saved by hand. `supervised`:
    /// the service runs under its supervisor (its heartbeat file named in its environment) or not; nil: this process's
    /// environment as it is.
    private func setUp(endsIn: Double, handSaved: Bool = false,
                       supervised: Bool? = nil) throws -> (ClusterApprovalMacs, ClusterService, URL) {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let leader = macs.leader, saved = try macs.saved(leader), facts = try macs.facts()
        let current = try ClusterApprovalAttachment.attachment(for: macs.approval(), saved: saved, paths: leader.paths,
            pairingStore: leader.pairing, edge: nil, now: Date().timeIntervalSince1970, chipClass: ClusterApprovalMacs.chip,
            facts: { _ in facts })
        let attachment: ClusterNativeMemberAttachment
        if handSaved {
            let h = ClusterApprovalMacs.hash
            let end = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + endsIn).rounded(.down)))
            let pair = try ClusterPairApprovalTests.approval(["id": "hand-saved", "model": ClusterApprovalMacs.model, "generation": 1,
                "plan_sha256": h("f"), "artifact_sha256": h("b"), "native_runtime_sha256": h("a"),
                "metallib_sha256": h("3"), "resource_library_sha256": h("4"), "capability_sha256": macs.capabilitySHA256,
                "resource_policy_sha256": h("8"), "profile_sha256": h("e"), "schedule": 1,
                "maximum_transport_frame": 131_112, "maximum_plaintext": 131_072, "maximum_records": 1024,
                "maximum_cumulative_plaintext": 16_777_216, "allowed_chips": ["Apple M3 Ultra"], "not_after": end])
            attachment = ClusterNativeMemberAttachment(ownerSHA256: current.ownerSHA256, metallibPath: current.metallibPath,
                resourceLibraryPath: current.resourceLibraryPath, approval: pair)
        } else {
            attachment = ClusterNativeMemberAttachment(ownerSHA256: current.ownerSHA256, metallibPath: current.metallibPath,
                resourceLibraryPath: current.resourceLibraryPath, clusterApproval: macs.approval(endsIn: endsIn),
                roster: try #require(current.roster), memberPins: try #require(current.memberPins), edges: nil)
        }
        try ClusterApprovalAttachment.save(attachment, saved: saved, paths: leader.paths, providerConfiguration: leader.provider,
                                           scratch: leader.scratch)
        // The loop answers no paired Mac here: only its own part is under test.
        try FileManager.default.moveItem(at: leader.pairing.directory,
                                         to: leader.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
        let helper = leader.home.appendingPathComponent("service-part-fixture")
        try NativePairMemberFixture.helper().write(to: helper, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let parts = leader.home.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environment = supervised.map { underSupervisor -> [String: String] in
            let key = ClusterSupervisionFiles.healthPathEnvironmentKey
            var environment = ProcessInfo.processInfo.environment
            environment[key] = underSupervisor
                ? ClusterServiceAgent.healthPath(serviceDirectory: ClusterSetupPaths(paths: leader.paths).directory).path : nil
            return environment
        }
        let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: leader.provider, darkbloomExecutable: helper,
            sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
        let service = ClusterService(settings: .init(wizard: wizard,
            leaderArguments: ["--service-part-fixture", parts.path, "leader"], followerArguments: [],
            soloArguments: ["--service-part-fixture", parts.path, "replacement"],
            memberArguments: ["--service-part-fixture", parts.path, "member"]), paths: leader.paths, recoveryGraceSeconds: 0.2,
            environment: environment)
        var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: leader.pin, peerPin: macs.follower.pin,
            peerName: "fixture peer", since: "fixture")
        leadership.serving = true; leadership.modelName = ClusterApprovalMacs.model
        _ = try service.store.updateRecord { $0.leadership = leadership }
        // A real control node inside the absence grace of the other Mac: this Mac runs its part of the cluster.
        let local = leader.memberID, peer = macs.follower.memberID
        let node = ClusterControlNode(localID: local,
            members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1, holdsModelAlone: false)],
            claim: .init(term: 1, leaderID: local, members: [local, peer], reason: "fixture"),
            rankOrder: [local, peer], now: ClusterService.monotonicSeconds(), ttl: 1, soloGrace: 3_600)
        service.lock.withLock { service.control = node }
        return (macs, service, parts)
    }

    /// The arguments each part of `role` was started with (the fixture records them, one a line), in order.
    private func arguments(_ parts: URL, _ role: String) -> [[String]] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? []).sorted()
            .filter { $0.hasPrefix(role + "-") && $0.hasSuffix(".args") }
            .compactMap { try? String(contentsOf: parts.appendingPathComponent($0), encoding: .utf8) }
            .map { $0.components(separatedBy: "\n") }
    }

    private func started(_ parts: URL, _ role: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? []).contains { $0.hasPrefix(role + "-") && $0.hasSuffix(".ready") }
    }

    /// How many parts of `role` the fixture recorded with `suffix`: `.ready` started, `.refused` refused for the GPU,
    /// `.term` asked to stop.
    private func count(_ parts: URL, _ role: String, _ suffix: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? []).filter { $0.hasPrefix(role + "-") && $0.hasSuffix(suffix) }.count
    }

    /// The process numbers of those parts (the fixture names each record `<role>-<pid><suffix>`).
    private func pids(_ parts: URL, _ role: String, _ suffix: String) -> [Int32] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? [])
            .filter { $0.hasPrefix(role + "-") && $0.hasSuffix(suffix) }
            .compactMap { Int32($0.dropFirst(role.count + 1).dropLast(suffix.count)) }
    }

    private func run(_ service: ClusterService, parts: URL, until predicate: () -> Bool) -> (Bool, [String]) {
        let stop = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let lines = ClusterApprovalRecorder<String>()
        Thread.detachNewThread {
            _ = try? service.run(stop: stop) { lines.append($0) }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(20)
        var reached = predicate()
        while !reached, Date() < deadline { usleep(20_000); reached = predicate() }
        for role in ["leader", "member", "replacement"] {
            try? Data().write(to: parts.appendingPathComponent("release-\(role)"))
        }
        stop.signal()
        #expect(done.wait(timeout: .now() + 30) == .success, "the service did not stop")
        return (reached, lines.values)
    }

    @Test func aStartWithAnEndedApprovalServesOnTheLeadersLocalAPI() throws {
        let (macs, service, parts) = try setUp(endsIn: -60)
        let (reached, lines) = run(service, parts: parts) { started(parts, "leader") }
        #expect(reached, "the part that serves locally did not start: \(lines)")
        #expect(!started(parts, "member"), "an ended approval was offered to the coordinator")
        // Its local API takes this Mac's own saved port (`LocalAPIPort.thisMac`), as every local API here does.
        let port = String(ClusterApprovalMacs.savedPort)
        #expect(arguments(parts, "leader").contains { zip($0, $0.dropFirst()).contains { $0 == "--port" && $1 == port } },
                "\(arguments(parts, "leader"))")
        #expect(try macs.saved(macs.leader).configuration.nativeMember == nil, "the ended approval stayed saved")
        #expect(lines.contains { $0.contains("expired: saved this Mac's setup without it") }, "\(lines)")
    }

    @Test func aStartWithACurrentApprovalRunsTheCoordinatorFormedMember() throws {
        let (macs, service, parts) = try setUp(endsIn: 14 * 86_400)
        let before = try macs.bytes(macs.leader)
        let (reached, lines) = run(service, parts: parts) { started(parts, "member") }
        #expect(reached, "the member part did not start: \(lines)")
        #expect(!started(parts, "leader"))
        #expect(try macs.bytes(macs.leader) == before, "a current approval was rewritten")
    }

    /// A supervised service beats into the file its supervisor names, and so does a coordinator-paired part (with its
    /// own pid) when it inherits that name. The supervisor's liveness guard reads another pid's beat as no beat, so on
    /// DevNet it restarted a healthy registered service every 15 minutes or so (the pair dropped each time). The part
    /// beats into a file of its own, and still runs as a supervised member (the key stays set).
    @Test func aSupervisedServicesMemberPartNeverBeatsIntoTheServicesHeartbeat() throws {
        // The fixture removes both homes (and `parts`) when it ends: it is kept until the last check.
        let (macs, service, parts) = try setUp(endsIn: 14 * 86_400, supervised: true)
        withExtendedLifetime(macs) {
            let (reached, lines) = run(service, parts: parts) { started(parts, "member") }
            #expect(reached, "the member part did not start: \(lines)")
            let directory = service.store.paths.directory
            #expect(heartbeatFiles(parts, "member") == [ClusterServiceAgent.partHealthPath(serviceDirectory: directory).path],
                    "the part must beat into its own file, never \(ClusterServiceAgent.healthPath(serviceDirectory: directory).path)")
        }
    }

    @Test func anUnsupervisedServicesMemberPartIsToldOfNoHeartbeatFile() throws {
        let (macs, service, parts) = try setUp(endsIn: 14 * 86_400, supervised: false)
        withExtendedLifetime(macs) {
            let (reached, lines) = run(service, parts: parts) { started(parts, "member") }
            #expect(reached, "the member part did not start: \(lines)")
            #expect(heartbeatFiles(parts, "member").isEmpty)
        }
    }

    /// An empty name is no supervisor to the service and to its part alike: it stays empty, never a part's file.
    @Test func anEmptyHeartbeatNameIsPassedOnEmpty() {
        let key = ClusterSupervisionFiles.healthPathEnvironmentKey
        let environment = ClusterService.partEnvironment([key: "", "HOME": "/fixture"],
                                                         serviceDirectory: URL(fileURLWithPath: "/fixture/.darkbloom/cluster-setup"))
        #expect(environment == [key: "", "HOME": "/fixture"])
    }

    /// The heartbeat files the parts of `role` were told of (the fixture records its environment's).
    private func heartbeatFiles(_ parts: URL, _ role: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? [])
            .filter { $0.hasPrefix(role + "-") && $0.hasSuffix(".health") }
            .compactMap { try? String(contentsOf: parts.appendingPathComponent($0), encoding: .utf8) }
    }

    @Test func aHandSavedPairApprovalThatEndedStaysSavedAndIsNeverOffered() throws {
        let (macs, service, parts) = try setUp(endsIn: -60, handSaved: true)
        let before = try macs.bytes(macs.leader)
        // The ordinary part starts (and, on a real Mac, says why it cannot run beside the saved approval).
        let (reached, lines) = run(service, parts: parts) { started(parts, "leader") }
        #expect(reached, "the ordinary part did not start: \(lines)")
        #expect(!started(parts, "member"), "an ended pair approval was offered to the coordinator")
        #expect(try macs.bytes(macs.leader) == before, "the operator's pair approval was removed")
        #expect(try macs.saved(macs.leader).configuration.nativeMember?.approval?.id == "hand-saved")
    }

    /// Re-review of #1846: each start refused because the other Darkbloom app held this Mac's GPU counted as a failing
    /// part, so after three the leader served the pair on its local API for an hour, even once the other app had stopped.
    /// Here the member's own device scope is refused by a held GPU lock the service could not see coming (the other app
    /// took the GPU between the service's check and the part's start): no refusal counts, and the lock's release starts
    /// the part within seconds.
    @Test func refusalsForTheGPUNeverCountAndItsReleaseStartsThePart() throws {
        let (macs, service, parts) = try setUp(endsIn: 14 * 86_400)
        try withExtendedLifetime(macs) {
            try Data(ClusterMachineDeviceLock.heldElsewhere(by: [.dev]).utf8).write(to: parts.appendingPathComponent("gpu.lock.refusal"))
            var held: ClusterDeviceExclusion? = try ClusterDeviceExclusion(
                directoryURL: parts.appendingPathComponent("lease-other-app", isDirectory: true),
                machineLock: .init(file: parts.appendingPathComponent("gpu.lock"), heldElsewhere: "the other app holds it"))
            var mostQuickEnds = 0, polled = Date.distantPast, releasedAt: Date?, startedAt: Date?, refusedEnd: String?
            let (reached, lines) = run(service, parts: parts) {
                if Date().timeIntervalSince(polled) >= 0.2 {
                    polled = Date()
                    mostQuickEnds = max(mostQuickEnds, service.status().memberQuickEnds ?? 0)
                }
                // Four refusals: the service has seen at least three of them end, each as the member ends (exit 76).
                if held != nil, count(parts, "member", ".refused") >= 4 {
                    refusedEnd = service.status().child.lastEnd
                    held = nil; releasedAt = Date()
                }
                if releasedAt != nil, started(parts, "member") { startedAt = Date(); return true }
                return false
            }
            #expect(count(parts, "member", ".refused") >= 4, "the part was not refused for the GPU again and again: \(lines)")
            #expect(mostQuickEnds == 0, "a refusal for the GPU counted as a failing part: \(lines)")
            #expect(refusedEnd == "exit \(ClusterMemberRunEnd.gpuHeldExitCode)", "the refused member's end: \(String(describing: refusedEnd))")
            #expect(try service.store.readRecord().approvalSetAside == nil, "the approval was set aside as failing")
            #expect(try macs.saved(macs.leader).configuration.nativeMember?.clusterApproval != nil, "the pair stopped being offered")
            #expect(reached, "the part did not start once the GPU was let go: \(lines)")
            if let releasedAt, let startedAt {
                #expect(startedAt.timeIntervalSince(releasedAt) < 5, "it started \(startedAt.timeIntervalSince(releasedAt)) s after the release")
            }
            withExtendedLifetime(held) {}
        }
    }

    /// Re-review of #1846: while the other Darkbloom app's pair holds this Mac's GPU lock, this Mac's part is not started
    /// into it. It waits, said once and named in the status (`heldBack`, which the other Mac's start reads too), nothing
    /// counts, and it starts within seconds of the lock's release.
    @Test func aPartWaitsWhileTheOtherAppHoldsTheGPUAndStartsOnceItLetsGo() throws {
        let (macs, service, parts) = try setUp(endsIn: 14 * 86_400)
        try withExtendedLifetime(macs) {
            let paths = macs.leader.paths
            let other = try ClusterUserPaths(homeDirectory: paths.homeDirectory, environment: paths.environment == .prod ? .dev : .prod)
            try FileManager.default.createDirectory(at: other.deviceDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var held: ClusterDeviceExclusion? = try ClusterDeviceExclusion(directoryURL: other.deviceDirectory,
                                                                            machineLock: other.machineDeviceLock)
            var heldBack: String?, heldSince: Date?, polled = Date.distantPast, releasedAt: Date?, startedAt: Date?
            var startedWhileHeld = false
            let (reached, lines) = run(service, parts: parts) {
                guard held != nil else {
                    if started(parts, "member") { startedAt = Date(); return true }
                    return false
                }
                if started(parts, "member") { startedWhileHeld = true; return true }
                if heldSince == nil, Date().timeIntervalSince(polled) >= 0.1 {
                    polled = Date()
                    if let reason = service.status().heldBack { heldBack = reason; heldSince = Date() }
                }
                if let heldSince, Date().timeIntervalSince(heldSince) >= 3 { held = nil; releasedAt = Date() }
                return false
            }
            #expect(!startedWhileHeld, "this Mac's part started on the GPU the other app holds: \(lines)")
            #expect(ClusterMachineDeviceLock.isRefusal(heldBack), "the status did not name the hold: \(String(describing: heldBack))")
            #expect(lines.filter { $0.contains("This Mac's part waits for it.") }.count == 1, "said once: \(lines)")
            #expect(reached, "the part did not start once the other app let the GPU go: \(lines)")
            if let releasedAt, let startedAt {
                #expect(startedAt.timeIntervalSince(releasedAt) < 5, "it started \(startedAt.timeIntervalSince(releasedAt)) s after the release")
            }
            #expect((service.status().memberQuickEnds ?? 0) == 0)
        }
    }

    /// Re-review of #1846: production before 0.10.11 takes no GPU lock, so outside production's build this Mac's part
    /// steps aside once production serves here (its pair started after this one, both at login say). The part stops,
    /// nothing counts, the status names production, and the part starts again once production stops serving here.
    /// Final review: the part's GPU work is fenced at once, before the part's own stop (which could take 300 s).
    @Test func aPartStepsAsideWhileProductionServesAndStartsAgainOnceItStops() throws {
        let (macs, service, parts) = try setUp(endsIn: 14 * 86_400)
        try withExtendedLifetime(macs) {
            let production = ClusterApprovalRecorder<Bool>()
            let words = ClusterMachineDeviceLock.productionServes("it is serving (process 4242)")
            service.productionServes = { production.values.last == true ? words : nil }
            let fenced = ClusterApprovalRecorder<Int32>()
            service.fenceGPUWork = { part in fenced.append(part); return 1 }
            var fencedBeforeTheStop: [Int32]?, askedToStop: [Int32]?
            var phase = 0, heldBack: String?, polled = Date.distantPast, servingSince: Date?, stoppedAt: Date?, startedAt: Date?
            var restartedWhileServing = false
            let (reached, lines) = run(service, parts: parts) {
                switch phase {
                case 0:  // this Mac's part runs; then production starts serving here
                    guard started(parts, "member") else { return false }
                    production.append(true); phase = 1
                case 1:  // the service fences the part's GPU work and asks it to stop; the fixture then ends
                    guard count(parts, "member", ".term") >= 1 else { return false }
                    fencedBeforeTheStop = fenced.values
                    askedToStop = pids(parts, "member", ".term")
                    try? Data().write(to: parts.appendingPathComponent("release-member"))
                    servingSince = Date(); phase = 2
                case 2:  // the part stays stopped while production serves; then production stops
                    if count(parts, "member", ".ready") > 1 { restartedWhileServing = true; return true }
                    if heldBack == nil, Date().timeIntervalSince(polled) >= 0.1 { polled = Date(); heldBack = service.status().heldBack }
                    guard let servingSince, Date().timeIntervalSince(servingSince) >= 3 else { return false }
                    production.append(false); stoppedAt = Date(); phase = 3
                default:
                    guard count(parts, "member", ".ready") > 1 else { return false }
                    startedAt = Date()
                    return true
                }
                return false
            }
            #expect(phase >= 2, "this Mac's part did not step aside for production: \(lines)")
            #expect(fencedBeforeTheStop != nil && fencedBeforeTheStop == askedToStop,
                    "the part's GPU work was not fenced before its stop: \(String(describing: fencedBeforeTheStop))")
            #expect(lines.contains { $0.contains("asked this part's worker owner to release the GPU now") }, "\(lines)")
            #expect(!restartedWhileServing, "this Mac's part started again while production served: \(lines)")
            #expect(heldBack == words, "the status did not name production: \(String(describing: heldBack))")
            #expect(lines.contains { $0.contains("This Mac's part stops and waits for it.") }, "\(lines)")
            #expect(reached, "the part did not start again once production stopped serving: \(lines)")
            if let stoppedAt, let startedAt {
                #expect(startedAt.timeIntervalSince(stoppedAt) < 5, "it started \(startedAt.timeIntervalSince(stoppedAt)) s after production stopped")
            }
            #expect((service.status().memberQuickEnds ?? 0) == 0)
        }
    }
}

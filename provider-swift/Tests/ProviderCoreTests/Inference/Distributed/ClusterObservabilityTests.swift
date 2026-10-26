import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

// S24: per-request pair telemetry from the engine's own observations and the
// ranks' reports, and incidents recorded redacted and classified. Fabricated
// owner and files under a temporary home; no model, no peer.

private final class TelemetryObservationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [DistributedRequestObservation] = []
    var values: [DistributedRequestObservation] { lock.withLock { observations } }
    func record(_ value: DistributedRequestObservation) { lock.withLock { observations.append(value) } }
    func waitFor(_ phase: DistributedRequestObservation.Phase) async -> DistributedRequestObservation? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let value = values.first(where: { $0.phase == phase }) { return value }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }
}

private func temporaryHome() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s24-observability-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.timeLimit(.minutes(1)))
struct ClusterObservabilityTests {
    @Test func rankTelemetryKeepsTheSlowerHandOffAndTheDraftingRank() {
        let merged = DistributedRankTelemetry(
            rank0: .init(handoffNanoseconds: 70_000_000, handoffBytes: 80_000_000),
            rank1: .init(handoffNanoseconds: 81_250_000, handoffBytes: 80_507_332, mtpDrafted: 120, mtpAccepted: 93))
        #expect(merged.handoffMilliseconds == 81.25)
        #expect(merged.handoffBytes == 80_507_332)
        #expect(merged.mtpDrafted == 120 && merged.mtpAccepted == 93)
        let none = DistributedRankTelemetry(rank0: nil, rank1: .init(prefillNanoseconds: 5))
        #expect(none.handoffMilliseconds == nil && none.mtpDrafted == nil)
    }

    @Test func retiredRequestBecomesOnePairTelemetryRecord() async throws {
        let owner = DistributedTestOwner(), clock = DistributedTestClock(), capture = TelemetryObservationCapture()
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            detokenizers: DistributedTestDetokenizers(), clock: clock.clock, requestObserver: capture.record)
        let origin = clock.now
        let stream = try engine.submit(distributedTestRequest(maxTokens: 3), deadlineContext: .init(
            generationDeadline: origin.advanced(by: .seconds(30)), firstTokenDeadline: origin.advanced(by: .seconds(10))))
        clock.advance(.milliseconds(400))
        #expect(owner.last.send(.token(4)))
        clock.advance(.milliseconds(100))
        #expect(owner.last.send(.token(5)))
        clock.advance(.milliseconds(100))
        #expect(!owner.last.send(.token(6)))
        // After the last token: the prefix report and the ranks' telemetry.
        owner.last.send(.promptCache(reused: 2, stored: [2]))
        owner.last.send(.telemetry(.init(rank0: .init(handoffNanoseconds: 60_000_000),
            rank1: .init(handoffNanoseconds: 75_000_000, handoffBytes: 1_000, mtpDrafted: 10, mtpAccepted: 8))))
        owner.last.acknowledge()
        _ = await distributedCollect(stream)
        let retired = try #require(await capture.waitFor(.retired))
        await engine.shutdown()
        #expect(retired.firstTokenMilliseconds == 400)
        #expect(retired.decodeTokensPerSecond == 10)      // two tokens after the first, in 200 ms
        #expect(retired.reusedPromptTokens == 2)
        #expect(retired.rankTelemetry?.handoffMilliseconds == 75)

        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = ClusterPairTelemetryLog(file: ClusterPairTelemetryLog.defaultFile(homeDirectory: home), sessionID: "epoch-1")
        let context = DistributedPairTelemetryContext(modelID: "fabricated-qwen-9b", mode: "phase_split_mtp_v1",
                                                      cut: "0-16|16-32", log: log)
        #expect(context.record(capture.values[0]) == nil)          // only retired requests become records
        let made = context.record(retired, now: { 1_000 })
        let record = try #require(made)
        log.record(record)
        #expect(record.mode == "phase_split_mtp_v1" && record.cut == "0-16|16-32" && record.outcome == "length")
        #expect(record.promptTokens == 3 && record.cachedTokens == 2 && record.completionTokens == 3)
        #expect(record.firstTokenMilliseconds == 400 && record.decodeTokensPerSecond == 10)
        #expect(record.handoffMilliseconds == 75 && record.handoffBytes == 1_000)
        #expect(record.mtpAcceptance == 0.8)
        let file = try #require(ClusterPairTelemetryLog.read(ClusterPairTelemetryLog.defaultFile(homeDirectory: home)))
        #expect(file.records == [record] && file.summary.mtpAcceptance == 0.8)
        let status = ClusterObservabilitySnapshot.read(homeDirectory: home)
        #expect(status.telemetry?.recent.first == record)
    }

    /// Time-sliced lanes serve several requests at once: each one's speed is then a share of the pair's, and its
    /// record must not be taken for the pair's speed (2026-10-22: eight lanes at 12 tok/s each, where one request
    /// alone decodes 90, made the next plan predict tensor parallel slower than a pipeline).
    @Test func requestsThatSharedThePairAreNoSpeedRecords() {
        let overlap = DistributedPairOverlap(clock: { 1_000 })
        let a = UUID(), b = UUID(), c = UUID()
        #expect(overlap.note(a, phase: .reserved) == nil)
        #expect(overlap.note(a, phase: .firstToken) == nil)
        #expect(overlap.note(a, phase: .terminal) == nil)
        #expect(overlap.note(a, phase: .retired) == 0)                   // alone: a speed record
        _ = overlap.note(b, phase: .reserved)
        _ = overlap.note(c, phase: .reserved)                            // c starts while b runs
        _ = overlap.note(c, phase: .terminal)
        #expect(overlap.note(c, phase: .retired) == 1)
        _ = overlap.note(b, phase: .terminal)
        #expect(overlap.note(b, phase: .retired) == 1)                   // b shared the pair with c
        #expect(overlap.note(UUID(), phase: .retired) == nil)            // never seen to start: not counted
        let shared = ClusterPairRequestTelemetry(requestID: "s", finishedAt: 1, modelID: "m", mode: "tensor_parallel_v1",
            cut: "0-45|0-45", promptTokens: 30, cachedTokens: 0, completionTokens: 256, firstTokenMilliseconds: 500,
            decodeTokensPerSecond: 12, handoffMilliseconds: nil, handoffBytes: nil, mtpDrafted: nil, mtpAccepted: nil,
            outcome: "length", concurrentRequests: 7)
        #expect(!shared.isSpeedRecord && ClusterServedSpeedFile.adding(shared, to: []).isEmpty)
    }

    /// A request whose end was lost (an overflowing sink drops observations) stops counting against later ones.
    @Test func aLostEndDoesNotMarkEveryLaterRequest() {
        let now = LockedClock(1_000)
        let overlap = DistributedPairOverlap(clock: { now.value })
        _ = overlap.note(UUID(), phase: .reserved)                       // its terminal and retired never arrive
        now.value += DistributedPairOverlap.staleSeconds + 1
        let later = UUID()
        _ = overlap.note(later, phase: .reserved)
        _ = overlap.note(later, phase: .terminal)
        #expect(overlap.note(later, phase: .retired) == 0)
    }

    @Test func failureIncidentIsClassifiedAndRedacted() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let observability = ClusterObservability(homeDirectory: home, hostNames: ["studio-of-alex"], userNames: ["alexander"])
        let facts = DistributedSessionFacts(clusterID: "pair one", memberID: "leader", modelID: "fabricated-qwen-9b",
            mode: "pipeline_v1", cut: "0-16|16-32", membershipEpoch: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
            diagnostics: ["ssh: connect to host peer-mac-b port 22: Connection refused"], terminations: [],
            peerHosts: ["peer-mac-b"], peerUsers: ["bobby"])
        let incident = try #require(observability.recordFailure(.activationLaunchFailed, source: "leader",
            error: "Native owner did not establish bilateral readiness (\(home.path)/x, alexander@studio-of-alex, bobby, 192.168.2.7)",
            facts: facts))
        #expect(incident.stateCode == "activation_launch_failed" && incident.reasonCode == "peer_unreachable")
        #expect(incident.guidanceCode == "peer_unreachable" && incident.deploymentID == "pairone")
        #expect(incident.jobID == facts.membershipEpoch && incident.modelID == "fabricated-qwen-9b")
        for secret in [home.path, "alexander", "studio-of-alex", "bobby", "192.168.2.7", "peer-mac-b"] {
            #expect(!incident.message.contains(secret), "the incident message still carries \(secret)")
        }
        #expect(incident.message.contains("Connection refused"))
        let lines = observability.incidentLines(since: 0, includeClosed: false)
        #expect(lines.contains { $0.contains("activation_launch_failed reason=peer_unreachable") })
        #expect(lines.contains { $0.contains("What to do (peer_unreachable)") })
        #expect(try observability.dismissIncident(id: incident.id))
        #expect(observability.incidents.feed().open.isEmpty)
        #expect(try observability.incidentFeedJSON(since: 0).contains("\"dismissed_at\""))
    }

    @Test func diagnosticsReportCarriesTheObservabilitySection() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let observability = ClusterObservability(homeDirectory: home, hostNames: [], userNames: [])
        observability.recordFailure(.sessionFailed, source: "leader", error: "rank 1 ended: its owner exited with status 75",
                                    facts: nil)
        let snapshot = ClusterObservabilitySnapshot.read(homeDirectory: home)
        #expect(snapshot.incidents?.open == 1 && snapshot.incidents?.recent.first?.reasonCode == "collective_stall")
        #expect(snapshot.lines.contains { $0.contains("collective_stall") })
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(encoded.contains("\"guidance\""))
    }
}

/// A settable clock for `DistributedPairOverlap`.
private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double
    init(_ value: Double) { current = value }
    var value: Double {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

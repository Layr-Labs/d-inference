import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// Round-2 production fixes on the runtime side: a reservation refused for one
// request leaves the rank idle and available; a reservation the owner cancels
// before it starts is given back; a running request asks the host memory gate
// only for what it still needs; the speculative head's history travels with
// the prefix cache. Constructed observations and small arrays only.

@Suite("Request-scoped refusal, continuing request check and MTP prefix history")
struct RequestScopedRefusalTests {
    private typealias Mac = ConstructedMac
    private static let gib = ConstructedMac.gib, mib = ConstructedMac.mib

    // MARK: the rank's own control

    @Test func aRefusedReservationLeavesTheOwnerIdleForTheNextRequest() throws {
        let control = QwenResidentControl(deadline: .max)
        try control.loaded()
        let first = UUID(), second = UUID()
        try control.reserve(first)
        // A gate refusal inside the reservation's checks: given back, refused alone.
        #expect(throws: ClusterResidentRequestRefusal.self) {
            try control.reserving(first, rank: 1, deadline: .max) { () -> Int in
                throw ProbeError("Resident request needs 11.90 GiB of admissible memory and has 11.39 GiB")
            }
        }
        #expect(control.available)
        // The replay window still refuses the refused ID; a new one is admitted.
        #expect(throws: ProbeError.self) { try control.reserve(first) }
        try control.reserve(second)
        #expect(try control.reserving(second, rank: 1, deadline: .max) { 7 } == 7)
        try control.start(second); try control.completed(second)
        #expect(control.available)
    }

    @Test func aRefusalPastTheDeadlineSaysDeadline() throws {
        let control = QwenResidentControl(deadline: .max)
        try control.loaded()
        let id = UUID()
        try control.reserve(id)
        do {
            _ = try control.reserving(id, rank: 0, deadline: 1) { () -> Int in throw ProbeError("past") }
            Issue.record("Expected a refusal")
        } catch let refusal as ClusterResidentRequestRefusal {
            #expect(refusal.reason == .deadline)
        }
        #expect(control.available)
    }

    @Test func aCancelledOwnerStillFailsInsteadOfRefusing() throws {
        let control = QwenResidentControl(deadline: .max)
        try control.loaded()
        let id = UUID()
        try control.reserve(id)
        control.cancel(id)
        #expect(throws: ProbeError.self) {
            try control.reserving(id, rank: 0, deadline: .max) { () -> Int in throw ProbeError("cancelled meanwhile") }
        }
        #expect(!control.available)
    }

    @Test func aReservationCancelledBeforeStartIsGivenBack() throws {
        let control = QwenResidentControl(deadline: .max)
        try control.loaded()
        let id = UUID()
        try control.reserve(id)
        control.cancel(id)
        #expect(control.withdraw(id))
        #expect(control.available)
        // Not once it runs.
        let running = UUID()
        try control.reserve(running); try control.start(running)
        #expect(!control.withdraw(running) && !control.release(running))
    }

    // MARK: the running request's live check

    @Test func aRunningRequestAsksOnlyForWhatItStillNeeds() throws {
        let need = QwenResidentRequestAllowance.continuingRequirement
        #expect(try need(8 * Self.gib, 1 * Self.gib, 0) == 9 * Self.gib)
        #expect(try need(8 * Self.gib, 1 * Self.gib, 6 * Self.gib) == 3 * Self.gib)
        #expect(try need(8 * Self.gib, 0, 9 * Self.gib) == 0)
        #expect(try need(8 * Self.gib, 0, -2 * Self.gib) == 8 * Self.gib)   // shrank: still the whole charge
        #expect(throws: ProbeError.self) { try need(-1, 0, 0) }
    }

    /// Mac B in round 2: 6.29 GiB free and 5.09 GiB of cache counted, a
    /// 7.90 GiB reservation. Admission asks for it plus the 4 GiB headroom and
    /// refuses; a request admitted earlier that still needs it all asks for the
    /// 7.90 GiB alone and goes on; the harm guard still stops it.
    @Test func theContinuingFloorIsTheTrulyFreeTripwire() throws {
        // 46.8 GiB file-backed: 6.8 GiB above the 40 GiB reserve, 5.1 GiB counted.
        let fileBacked = (40 * Self.gib + 6 * Self.gib + 819 * Self.mib) / ConstructedMac.page
        let observation = Mac.observation(freeBytes: 6 * Self.gib + 300 * Self.mib, anonymousGiB: 55,
            inactiveFileBackedBytes: 30 * Self.gib, fileBackedPages: fileBacked)
        let reserved = 7 * Self.gib + 921 * Self.mib
        let admission = try QwenDenseStageLoadPolicy.decide(observation,
            requiredBytes: reserved + QwenDenseStageLoadPolicy.loadingHeadroomBytes, purpose: "Resident request", now: Mac.now)
        let running = try QwenDenseStageLoadPolicy.decide(observation, requiredBytes: reserved, purpose: "Resident request",
            now: Mac.now, floor: QwenDenseStageLoadPolicy.minimumTrulyFreeBytes)
        #expect(!admission.admitted && running.admitted)
        #expect(running.requiredBytes == reserved && admission.requiredBytes == reserved + 4 * Self.gib)
        // Almost all allocated: a load or reservation floor (6 GiB) would refuse; continuing does not.
        let tail = try QwenDenseStageLoadPolicy.decide(Mac.observation(freeBytes: 512 * Self.mib, fileBackedGiB: 20,
            anonymousGiB: 70, inactiveFileBackedBytes: 0), requiredBytes: 100 * Self.mib, purpose: "Resident request",
            now: Mac.now, floor: QwenDenseStageLoadPolicy.minimumTrulyFreeBytes)
        #expect(tail.admitted)
        // Harm since the request's first sample still withdraws the cache.
        let first = QwenDenseStageLoadBaseline(observation)
        let harmed = try QwenDenseStageLoadPolicy.decide(Mac.observation(freeBytes: 6 * Self.gib + 300 * Self.mib,
            anonymousGiB: 55, inactiveFileBackedBytes: 30 * Self.gib,
            compressedBytes: QwenDenseStageLoadPolicy.maximumCompressedSinceFirstSampleBytes + 16_384,
            fileBackedPages: fileBacked),
            requiredBytes: reserved, purpose: "Resident request", now: Mac.now, since: first,
            floor: QwenDenseStageLoadPolicy.minimumTrulyFreeBytes)
        #expect(!harmed.admitted && harmed.stoppedByCompressionOrSwap)
    }

    // MARK: the speculative head's history with the prefix cache

    @Test func headHistoryViewsAreThePromptsRowsUpToTheFrontier() throws {
        let prompt = 6, width = 4
        let hidden = MLXArray((0..<((prompt - 1) * width)).map { Float($0) }, [1, prompt - 1, width])
        let tokens = MLXArray((1..<prompt).map { Int32($0 * 10) }, [1, prompt - 1])
        let last = MLXArray((0..<width).map { Float(100 + $0) }, [1, 1, width])
        let whole = try #require(QwenMTPPrefixHistory.view(hidden: hidden, tokens: tokens, last: last, prompt: prompt, frontier: prompt))
        #expect(whole.hidden.shape == [1, 5, 4] && whole.last.asArray(Float.self) == [100, 101, 102, 103])
        let at4 = try #require(QwenMTPPrefixHistory.view(hidden: hidden, tokens: tokens, last: last, prompt: prompt, frontier: 4))
        #expect(at4.frontier == 4 && at4.hidden.shape == [1, 3, 4] && at4.tokens.shape == [1, 3])
        #expect(at4.tokens.asArray(Int32.self) == [10, 20, 30])
        // The row of position f-1 pairs with the first token after the frontier.
        #expect(at4.last.asArray(Float.self) == [12, 13, 14, 15])
        #expect(QwenMTPPrefixHistory.view(hidden: hidden, tokens: tokens, last: last, prompt: prompt, frontier: 1) == nil)
        #expect(QwenMTPPrefixHistory.view(hidden: hidden, tokens: tokens, last: last, prompt: prompt, frontier: 7) == nil)
    }

    @Test func thePrefixCacheKeepsTheHeadHistoryWithItsEntry() throws {
        let cache = QwenStagePrefixCache(enabled: true, entryLimit: 4, strideTokens: 2)
        let tokens = [5, 6, 7, 8, 9]
        let history = QwenMTPPrefixHistory(frontier: 4, hidden: MLXArray.zeros([1, 3, 2]),
            tokens: MLXArray([Int32(6), 7, 8], [1, 3]), last: MLXArray.ones([1, 1, 2]))
        var state = QwenStagePrefixState(committedTokens: 4, attention: [:], recurrent: [:])
        state.speculativeHistory = history
        cache.insert(scope: "s", tokens: tokens, states: [state])
        let restored = try #require(cache.state(scope: "s", tokens: tokens, frontier: 4))
        #expect(restored.speculativeHistory?.frontier == 4)
        #expect(restored.speculativeHistory?.tokens.asArray(Int32.self) == [6, 7, 8])
    }
}

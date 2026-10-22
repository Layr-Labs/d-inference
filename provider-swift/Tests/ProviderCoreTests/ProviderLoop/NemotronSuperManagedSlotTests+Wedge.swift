// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A confirmed wedge on the managed Super slot. The fixture's tokenizer holds
/// the engine thread inside the first token's detokenization (the request
/// carries a stop string, so the engine detokenizes on its own thread): the
/// admitted request never shows a token and the engine never steps again.
/// The liveness pass returns at once with the slot out of serving; the slot
/// retires within its bound, or as a retained fault past it, and reloads
/// wait out the recovery cooldown.
extension NemotronSuperManagedSlotTests {
    /// Holds every detokenization while closed.
    final class DecodeGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var closed = false
        private var held = 0

        func close() { condition.withLock { closed = true } }
        func open() {
            condition.withLock {
                closed = false
                condition.broadcast()
            }
        }
        /// A detokenization is waiting at the gate.
        var holding: Bool { condition.withLock { held > 0 } }

        func pass() {
            condition.withLock {
                while closed {
                    held += 1
                    condition.wait()
                    held -= 1
                }
            }
        }
    }

    /// `base`, with every decode passing `gate` first.
    struct GatedTokenizer: MLXLMCommon.Tokenizer {
        let base: any MLXLMCommon.Tokenizer
        let gate: DecodeGate
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            base.encode(text: text, addSpecialTokens: addSpecialTokens)
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            gate.pass()
            return base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }
        func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
        var bosToken: String? { base.bosToken }
        var eosToken: String? { base.eosToken }
        var unknownToken: String? { base.unknownToken }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        }
        func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] {
            try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate)
        }
        func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                               tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws
            -> [Int] {
            try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate, tools: tools,
                                       additionalContext: additionalContext)
        }
    }

    static func eventually(within limit: Duration, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// The loaded slot's owner, with its idle calibration stopped so the
    /// wedging request is the engine's only work.
    static func loadQuietOwner(_ fixture: Fixture) async throws -> NemotronSuperSlotOwner {
        try await fixture.loop.ensureModelLoaded(modelId: modelID, allowEviction: false,
                                                 revisionDirectory: fixture.directory)
        let owner = try #require(await fixture.loop.nemotronSuperOwnerForTesting(modelId: modelID))
        await owner.bridge.stopModelCalibration()
        return owner
    }

    /// One token under a stop string, which the engine detokenizes on its own thread.
    static func wedgingBody(_ script: SuperOutputScript) throws -> Data {
        try body(["a"], script: script, ["stop": ["zzz"]])
    }

    /// Once the gate holds the engine, takes the heartbeat's step sample and
    /// returns an instant past the 120 s stall and step flatline, at which the
    /// wedge is confirmed; nil (gate opened) when the engine never got there.
    static func confirmWedge(_ bridge: EngineV2Bridge, gate: DecodeGate) async -> ContinuousClock.Instant? {
        guard await eventually(within: .seconds(30), { gate.holding }) else {
            Issue.record("the engine never reached the gated detokenization")
            gate.open()
            return nil
        }
        let sampled = ContinuousClock.now
        _ = await bridge.backendSlotCapacity(now: sampled)
        let confirmed = sampled.advanced(by: .seconds(130))
        #expect(await bridge.confirmedWedgeForRecovery(now: confirmed))
        return confirmed
    }

    /// One liveness pass at `now`; false when it did not return promptly, in
    /// which case it was waiting on the wedged owner and the gate is opened
    /// so it can finish.
    static func livenessPassReturnsPromptly(_ loop: ProviderLoop, at now: ContinuousClock.Instant,
                                            gate: DecodeGate) async -> Bool {
        let returned = Box<Bool>()
        let pass = Task {
            await loop.recoverWedgedEngineV2SlotsForTesting(now: now)
            returned.set(true)
        }
        let prompt = await eventually(within: .seconds(2)) { returned.value == true }
        if !prompt {
            gate.open()
            await pass.value
        }
        return prompt
    }

    static func ownerReservations(_ budget: GlobalKVCacheBudget) async -> [String: UInt64] {
        await budget.reservationBytesSnapshot().filter {
            NemotronSuperLocalPrefill.isLaneReservationID($0.key)
                || NemotronSuperLocalKVBackend.isDecodeRowsReservationID($0.key)
                || NemotronSuperLocalMTP.isRoundReservationID($0.key)
                || NemotronSuperLocalPrefixCache.isBankReservationID($0.key)
        }
    }

    /// The liveness pass leaves the wedged slot's join to a task of its own;
    /// the engine force-finishes within its shutdown timeout, the owner
    /// retires completely, and reloads wait out the recovery cooldown. Until
    /// it ends, new requests are refused before they are accepted, also while
    /// the slot, still resident, retires.
    @Test(.timeLimit(.minutes(2)))
    func confirmedWedgeRetiresTheSlotOffTheCapacityTick() async throws {
        let gate = DecodeGate()
        let fixture = try await Self.fixture(mode: .off, decodeGate: gate)
        defer {
            gate.open()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let loop = fixture.loop
        let owner = try await Self.loadQuietOwner(fixture)
        #expect(await Self.ownerReservations(fixture.budget).count == 3, "lane, decode rows and bank")
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        gate.close()
        let wedged = try await Self.send(Self.wedgingBody(fixture.script), to: loop, recorder: recorder,
                                         consumer: consumer) { _ in
            guard let confirmed = await Self.confirmWedge(owner.bridge, gate: gate) else { return }
            #expect(await Self.livenessPassReturnsPromptly(loop, at: confirmed, gate: gate),
                    "the capacity tick never waits for the wedged owner")
            // Out of serving at once: the heartbeat drops the slot, and the
            // slot, resident until its owner retires, admits no new request.
            #expect(await loop.engineV2Runtime.bridge(forModel: Self.modelID) == nil)
            #expect(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) != nil)
            #expect(await loop.fastAdmissionReject(modelId: Self.modelID))
        }
        #expect(Self.failure(wedged.terminal) != nil, "\(wedged.terminal)")
        // Bridge shutdown cancelled the pumps first; the engine gave up its
        // rows at its shutdown timeout and the owner retired within the bound.
        #expect(await Self.eventually(within: .seconds(30)) {
            await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) == nil
        })
        #expect(await !loop.modelsUnloading.contains(Self.modelID))
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
        #expect(await Self.ownerReservations(fixture.budget).isEmpty)
        gate.open()
        #expect(await Self.eventually(within: .seconds(30)) { await fixture.budget.outstandingReservedBytes() == 0 })

        // A request inside the recovery cooldown is refused before it is
        // accepted, a reload as transient (503)...
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID))
        var refusal: Error?
        do {
            try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                             revisionDirectory: fixture.directory)
        } catch { refusal = error }
        let error = try #require(refusal)
        #expect(ProviderLoop.loadErrorStatusCode(for: error) == 503)
        #expect(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) == nil)
        // ...and loads once it has passed.
        await loop.setEngineV2LastRecoveryAtForTesting(
            modelId: Self.modelID, at: ContinuousClock.now - ProviderLoop.engineV2RecoveryCooldown)
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID) == false)
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    /// A wedged retirement still running at its bound (here the engine's own
    /// shutdown timeout outlasts it) is a retained fault: the slot leaves,
    /// its weights, reservations and bank stay charged and later Super loads
    /// are refused. A late retirement that completes releases the ledger and
    /// that charge, and Super loads again without a restart.
    @Test(.timeLimit(.minutes(2)))
    func wedgedRetirementPastItsBoundIsARetainedFault() async throws {
        let gate = DecodeGate()
        let fixture = try await Self.fixture(mode: .off, decodeGate: gate)
        defer {
            gate.open()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let loop = fixture.loop
        let owner = try await Self.loadQuietOwner(fixture)
        let reservations = await Self.ownerReservations(fixture.budget)
        let retained = UInt64(owner.sizing.weightsBytes) + reservations.values.reduce(0, +)
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        gate.close()
        let wedged = try await Self.send(Self.wedgingBody(fixture.script), to: loop, recorder: recorder,
                                         consumer: consumer) { _ in
            guard let confirmed = await Self.confirmWedge(owner.bridge, gate: gate) else { return }
            await loop.retireWedgedNemotronSuperSlot(Self.modelID, now: confirmed, bound: .milliseconds(500))
        }
        #expect(Self.failure(wedged.terminal) != nil, "\(wedged.terminal)")
        #expect(await Self.eventually(within: .seconds(5)) {
            await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) == nil
        })
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == retained)
        #expect(await Self.ownerReservations(fixture.budget) == reservations)
        await loop.setEngineV2LastRecoveryAtForTesting(
            modelId: Self.modelID, at: ContinuousClock.now - ProviderLoop.engineV2RecoveryCooldown)
        var refusal: Error?
        do {
            try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                             revisionDirectory: fixture.directory)
        } catch { refusal = error }
        #expect("\(String(describing: refusal))".contains("retained native work"))
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID))
        gate.open()
        #expect(await Self.eventually(within: .seconds(30)) { await fixture.budget.outstandingReservedBytes() == 0 })
        #expect(await Self.eventually(within: .seconds(30)) {
            await loop.nemotronSuperRetainedWeightBytesForTesting() == 0
        })
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }
}

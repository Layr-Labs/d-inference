import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// GLM tensor parallel's one-token steps (`GLM5NextTensorParallelStepLoop`)
/// on two ranks without a model: each step's agreement crosses an in-process
/// all-sum (`FakeLink`) when the loop reads or evaluates it, as it does every
/// step it builds, in order; rank 0 reads the owner's answers late as the
/// runtime does, and both ranks then cross the end-of-request agreement and
/// reconcile (`QwenTensorParallelStopRule.reconcile`). Every case must end
/// both ranks after the same step, through the same collectives.
@Suite("GLM tensor-parallel one-token steps")
struct GLM5NextTensorParallelStepLoopTests {
    static let stopToken = 2
    /// The agreed token at each output index; the stop token is at 4.
    static let script = [11, 12, 13, 14, stopToken, 15, 16, 17, 18, 19]

    struct Case {
        var sampled = false
        /// The owner answers stop to this token (and to the stop token).
        var ownerStopsAt: Int?
        /// This rank stops on its own (cancel, deadline, memory) once it holds this many tokens.
        var localStopAfter: [Int: Int] = [:]
    }

    struct Ended: Equatable {
        var tokens: [Int]
        var finish: QwenTensorParallelStopRule.Finish
        var published: [Int]
    }

    /// One rank's request state, as the runtime's `generate` holds it.
    final class Rank {
        struct Step { let index: Int; let stop: Float }
        let rank: Int, link: FakeLink, spec: Case
        var tokens: [Int] = [], published: [Int] = []
        var stopKeep: Float = 0, clientStopped = false, unanswered = false

        init(rank: Int, link: FakeLink, spec: Case) { self.rank = rank; self.link = link; self.spec = spec }

        func wanted(_ ordinal: Int) -> Bool {
            ordinal < (spec.ownerStopsAt ?? .max) && script[ordinal] != stopToken
        }

        /// A step's agreement: each rank puts its own token and stop flag
        /// (rank 1 puts no token for a sampled request).
        func agree(_ step: Step) throws -> [Float] {
            var values: [Float] = [0, 0, 0, 0]
            values[rank] = spec.sampled && rank == 1 ? 0 : Float(script[step.index])
            values[2 + rank] = step.stop
            return try link.exchange(rank: rank, kind: "step", values)
        }

        func run() throws -> Ended {
            let outputCount = script.count
            let loop = GLM5NextTensorParallelStepLoop<Step>(outputCount: outputCount, promptCount: 3,
                stopTokenIDs: [stopToken], pipelined: !spec.sampled,
                step: { Step(index: $0.index + 1, stop: $1) }, agreement: agree, evaluate: { _ = try self.agree($0) },
                growPages: { _ in }, pagesRefused: { false },
                stopKeep: { self.stopKeep }, setStopKeep: { self.stopKeep = $0 },
                readAnswer: {
                    guard self.unanswered else { return }
                    self.unanswered = false
                    if !self.wanted(self.published.count - 1), self.stopKeep == 0 {
                        self.clientStopped = true; self.stopKeep = Float(self.tokens.count)
                    }
                },
                committed: { self.tokens.count }, keep: { self.tokens = Array(self.tokens.prefix($0)) },
                commit: { value in
                    self.tokens.append(value)
                    if self.rank == 0 { self.published.append(value); self.unanswered = true }
                    switch QwenTensorParallelStopRule.outcome(isStopToken: value == stopToken,
                        committed: self.tokens.count, outputCount: outputCount, wanted: true) {
                    case .eos: return .eos
                    case .length: return .length
                    case .clientStop, .proceed: return nil
                    }
                },
                localStop: { self.spec.localStopAfter[self.rank] == self.tokens.count })
            // The end of a request, as the runtime's `generate` ends one.
            var finish = try loop.run(first: Step(index: 0, stop: 0)) ?? .length
            if unanswered {
                unanswered = false
                if !wanted(published.count - 1), finish == .clientStop { clientStopped = true }
            }
            if clientStopped || (stopKeep > 0 && stopKeep < QwenTensorParallelStopRule.lengthStopBase) { finish = .clientStop }
            let local: QwenTensorParallelStopRule.Finish = finish == .eos ? .eos : finish == .length ? .length : .clientStop
            let end = try link.exchange(rank: rank, kind: "end", rank == 0 ? [Float(tokens.count), Float(local.code)] : [0, 0])
            let rank0Finish = try #require(QwenTensorParallelStopRule.Finish(code: Int32(end[1])))
            let ended = QwenTensorParallelStopRule.reconcile(rank: rank, localFinish: local, localCount: tokens.count,
                localStopped: stopKeep > 0 && !clientStopped, rank0Finish: rank0Finish, rank0Count: Int(end[0]))
            return .init(tokens: Array(tokens.prefix(ended.count)), finish: ended.finish, published: published)
        }
    }

    /// Both ranks on threads of their own; their results, and the collectives rank 0 ran.
    static func pair(_ spec: Case) throws -> (ended: [Ended], kinds: [String]) {
        final class Results: @unchecked Sendable {
            let lock = NSLock(); var values: [Result<Ended, Error>?] = [nil, nil]
        }
        let link = FakeLink(), results = Results(), done = DispatchGroup()
        for rank in 0 ..< 2 {
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                let result = Result { try Rank(rank: rank, link: link, spec: spec).run() }
                if case .failure(let error) = result { link.fail("rank \(rank): \(error)") }
                results.lock.withLock { results.values[rank] = result }
            }
        }
        guard done.wait(timeout: .now() + 60) == .success else { throw ProbeError("the ranks did not finish") }
        if let mismatch = link.mismatch { throw ProbeError("the ranks ran different collectives: \(mismatch)") }
        return (try results.lock.withLock { try results.values.map { try #require($0).get() } }, link.kinds)
    }

    /// Plain runs end both ranks together: at the stop token, and through the
    /// flag of an owner's stop that a later step carries.
    @Test(arguments: [false, true])
    func bothRanksEndAfterTheSameStep(sampled: Bool) throws {
        let plain = try Self.pair(.init(sampled: sampled))
        for ended in plain.ended { #expect(ended.tokens == Array(Self.script.prefix(5)) && ended.finish == .eos) }
        #expect(plain.ended[0].published == Array(Self.script.prefix(5)))
        let stopped = try Self.pair(.init(sampled: sampled, ownerStopsAt: 1))
        for ended in stopped.ended { #expect(ended.tokens == Array(Self.script.prefix(2)) && ended.finish == .clientStop) }
        #expect(stopped.ended[0].published == Array(Self.script.prefix(2)))
        #expect(stopped.kinds.last == "end")
    }

    /// The owner stops one token before a stop token, or two on greedy steps
    /// (built one ahead). Rank 0 reads that answer only after the next step
    /// was built, so its flag rides a step rank 1 never reads: rank 1 commits
    /// the stop token and ends, and rank 0 must end there too instead of
    /// building a step alone (on the pair, a collective its peer never
    /// joins). Both then keep the tokens up to the owner's stop, as a client stop.
    @Test(arguments: zip([false, false, true], [3, 2, 3]))
    func anOwnersStopJustBeforeAStopTokenEndsBothRanksThere(sampled: Bool, ownerStopsAt: Int) throws {
        let race = try Self.pair(.init(sampled: sampled, ownerStopsAt: ownerStopsAt))
        let kept = Array(Self.script.prefix(ownerStopsAt + 1))
        for ended in race.ended { #expect(ended.tokens == kept && ended.finish == .clientStop) }
        #expect(race.ended[0].published == kept)
        #expect(race.kinds.last == "end")
    }

    /// A greedy rank that stops on its own just before a stop token (its
    /// flag rides the step after the one already built) ends at the stop
    /// token its peer commits, as the owner's stop does. Both report one
    /// finish, or the owner fails the request and the pair: rank 0's own stop,
    /// which rank 1 adopts; or, when rank 1 stopped, the stop token rank 0
    /// ended at, since rank 1's stop came too late to change it (D6: a memory
    /// refusal there ends nothing but the request).
    @Test(arguments: [0, 1])
    func aRanksOwnStopJustBeforeAStopTokenEndsBothRanksThere(stopping: Int) throws {
        let race = try Self.pair(.init(localStopAfter: [stopping: 4]))
        #expect(race.kinds.last == "end")
        // The stopping rank keeps what it held; its peer what it committed.
        #expect(race.ended[stopping].tokens == Array(Self.script.prefix(4)))
        #expect(race.ended[1 - stopping].tokens == Array(Self.script.prefix(stopping == 0 ? 4 : 5)))
        let finish: QwenTensorParallelStopRule.Finish = stopping == 0 ? .clientStop : .eos
        #expect(race.ended[0].finish == finish && race.ended[1].finish == finish)
        #expect(race.ended[0].published == race.ended[0].tokens)
    }
}

import Foundation

// `TensorParallelOneTokenLoop` (Gemma tensor parallel's decode, GLM's step
// order) on two ranks without a model: each step's agreement crosses an
// in-process all-sum when the loop reads or evaluates it, rank 0 reads the
// owner's answers late, and both ranks then cross the end-of-request
// agreement and reconcile. Greedy steps must be built one ahead (step k+1
// submitted before step k is read); every case must end both ranks after the
// same step, through the same collectives, with the tokens and finish the
// read-then-build order gives.

/// Two ranks' all-sum, in order: a mismatch in kind is recorded.
final class OneTokenLink: @unchecked Sendable {
    private let condition = NSCondition()
    private var slots: [[Float]?] = [nil, nil], kinds: [String?] = [nil, nil], result: [Float] = []
    private var leaving = 0
    private(set) var mismatch: String?
    private(set) var order: [String] = []
    func exchange(rank: Int, kind: String, _ values: [Float]) -> [Float] {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while leaving > 0 { guard condition.wait(until: deadline) else { mismatch = "timeout"; return values } }
        slots[rank] = values; kinds[rank] = kind
        if slots.allSatisfy({ $0 != nil }) {
            if kinds[0] != kinds[1] || slots[0]!.count != slots[1]!.count { mismatch = "\(kinds[0]!) vs \(kinds[1]!)" }
            result = zip(slots[0]!, slots[1]!).map(+); order.append(kind); leaving = 2; condition.broadcast()
        } else {
            while slots[rank] != nil && leaving == 0 {
                guard condition.wait(until: deadline) else { mismatch = "timeout at \(kind)"; return values }
            }
        }
        let output = result
        leaving -= 1
        if leaving == 0 { slots = [nil, nil]; kinds = [nil, nil]; condition.broadcast() }
        return output
    }
}

struct OneTokenCase {
    var pipelined: Bool
    var script: [Int] = [11, 12, 13, 14, 2, 15, 16, 17, 18, 19]
    var ownerStopsAt: Int?
    var localStopAfter: [Int: Int] = [:]
    var refusePagesAfter: [Int: Int] = [:]
}

struct OneTokenEnded: Equatable {
    var tokens: [Int]
    var finish: QwenTensorParallelStopRule.Finish
    var published: [Int]
    var events: [String]
    var agreedSteps: Int
}

final class OneTokenRank {
    struct Step { let index: Int; let stop: Float }
    static let stopToken = 2
    let rank: Int, link: OneTokenLink, spec: OneTokenCase
    var tokens: [Int] = [], published: [Int] = [], events: [String] = []
    var stopKeep: Float = 0, clientStopped = false, unanswered = false, refused = false, agreedSteps = 0

    init(rank: Int, link: OneTokenLink, spec: OneTokenCase) { self.rank = rank; self.link = link; self.spec = spec }

    func wanted(_ ordinal: Int) -> Bool { ordinal < (spec.ownerStopsAt ?? .max) && spec.script[ordinal] != Self.stopToken }

    func agree(_ step: Step) -> (token: Int, flags: [Float]) {
        var values: [Float] = [0, 0]
        values[rank] = step.stop
        let flags = link.exchange(rank: rank, kind: "step \(step.index)", values)
        return (spec.script[step.index], flags)
    }

    func run() throws -> OneTokenEnded {
        let outputCount = spec.script.count
        let loop = TensorParallelOneTokenLoop<Step>(outputCount: outputCount, stopTokenIDs: [Self.stopToken],
            pipelined: spec.pipelined,
            step: { self.events.append("build \($0.index + 1)"); return Step(index: $0.index + 1, stop: $1) },
            read: { self.events.append("read \($0.index)"); return self.agree($0) },
            evaluate: { self.events.append("evaluate \($0.index)"); _ = self.agree($0) },
            growPages: { if let after = self.spec.refusePagesAfter[self.rank], self.tokens.count >= after { self.refused = true } },
            pagesRefused: { self.refused },
            stopKeep: { self.stopKeep }, setStopKeep: { self.stopKeep = $0 },
            readAnswer: {
                guard self.unanswered else { return }
                self.unanswered = false
                if !self.wanted(self.published.count - 1), self.stopKeep == 0 {
                    self.clientStopped = true; self.stopKeep = Float(self.tokens.count)
                }
            },
            committed: { self.tokens.count }, keep: { self.tokens = Array(self.tokens.prefix($0)) },
            agreedStep: { _, _ in
                // A collective every rank takes at each agreed step (Gemma's greedy logprobs).
                self.agreedSteps += 1; _ = self.link.exchange(rank: self.rank, kind: "agreed", [0])
            },
            commit: { _, value in
                self.tokens.append(value)
                if self.rank == 0 { self.published.append(value); self.unanswered = true }
                switch QwenTensorParallelStopRule.outcome(isStopToken: value == Self.stopToken,
                    committed: self.tokens.count, outputCount: outputCount, wanted: true) {
                case .eos: return .eos
                case .length: return .length
                case .clientStop, .proceed: return nil
                }
            },
            localStop: { self.spec.localStopAfter[self.rank] == self.tokens.count })
        var finish = try loop.run(first: Step(index: 0, stop: 0)) ?? .length
        if unanswered {
            unanswered = false
            if !wanted(published.count - 1), finish == .clientStop { clientStopped = true }
        }
        if clientStopped || (stopKeep > 0 && stopKeep < QwenTensorParallelStopRule.lengthStopBase) { finish = .clientStop }
        let end = link.exchange(rank: rank, kind: "end", rank == 0 ? [Float(tokens.count), Float(finish.code)] : [0, 0])
        guard let rank0Finish = QwenTensorParallelStopRule.Finish(code: Int32(end[1])) else {
            throw ProbeError("no agreed finish")
        }
        let ended = QwenTensorParallelStopRule.reconcile(rank: rank, localFinish: finish, localCount: tokens.count,
            localStopped: stopKeep > 0 && !clientStopped, rank0Finish: rank0Finish, rank0Count: Int(end[0]))
        return .init(tokens: Array(tokens.prefix(ended.count)), finish: ended.finish, published: published,
                     events: events, agreedSteps: agreedSteps)
    }
}

func oneTokenPair(_ spec: OneTokenCase) -> (ended: [OneTokenEnded], order: [String], mismatch: String?)? {
    final class Box: @unchecked Sendable { let lock = NSLock(); var values: [OneTokenEnded?] = [nil, nil] }
    let link = OneTokenLink(), box = Box(), done = DispatchGroup()
    for rank in 0 ..< 2 {
        done.enter()
        Thread.detachNewThread {
            defer { done.leave() }
            let ended = try? OneTokenRank(rank: rank, link: link, spec: spec).run()
            box.lock.withLock { box.values[rank] = ended }
        }
    }
    guard done.wait(timeout: .now() + 30) == .success else { return nil }
    let values = box.lock.withLock { box.values }
    guard let zero = values[0], let one = values[1] else { return nil }
    return ([zero, one], link.order, link.mismatch)
}

/// Every greedy step k+1 is built before step k is read (when both exist).
func buildsAhead(_ events: [String]) -> Bool {
    for (position, event) in events.enumerated() where event.hasPrefix("read ") {
        let index = Int(event.dropFirst(5))!
        if events.contains("build \(index + 1)"), !events[..<position].contains("build \(index + 1)") { return false }
    }
    return true
}

func checkOneTokenLoop() {
    var cases: [(String, OneTokenCase)] = []
    for pipelined in [true, false] {
        let tag = pipelined ? "pipelined" : "read-then-build"
        cases.append(("\(tag) stop token", .init(pipelined: pipelined)))
        cases.append(("\(tag) length", .init(pipelined: pipelined, script: [11, 12, 13, 14, 15, 16])))
        cases.append(("\(tag) owner stop", .init(pipelined: pipelined, ownerStopsAt: 1)))
        cases.append(("\(tag) owner stop late", .init(pipelined: pipelined, ownerStopsAt: 3)))
        cases.append(("\(tag) rank 1 local stop", .init(pipelined: pipelined, localStopAfter: [1: 2])))
        cases.append(("\(tag) rank 0 local stop", .init(pipelined: pipelined, localStopAfter: [0: 3])))
        cases.append(("\(tag) rank 1 pages refused", .init(pipelined: pipelined, refusePagesAfter: [1: 2])))
    }
    var byCase: [String: OneTokenEnded] = [:]
    for (label, spec) in cases {
        guard let run = oneTokenPair(spec) else { failures += 1; print("FAIL: one-token \(label): a rank failed or hung"); continue }
        check(run.mismatch == nil, "one-token \(label): ranks ran different collectives: \(run.mismatch ?? "")")
        check(run.ended[0].tokens == run.ended[1].tokens && run.ended[0].finish == run.ended[1].finish,
              "one-token \(label): ranks ended differently: \(run.ended[0].tokens)/\(run.ended[0].finish) vs \(run.ended[1].tokens)/\(run.ended[1].finish)")
        check(run.ended[0].agreedSteps == run.ended[1].agreedSteps, "one-token \(label): agreed-step collectives differ")
        if spec.pipelined {
            check(run.ended.allSatisfy { buildsAhead($0.events) }, "one-token \(label): a greedy step was read before the next was built: \(run.ended[0].events)")
        }
        byCase[label] = run.ended[0]
    }
    // Building ahead changes when steps run, not what a request returns. Two
    // documented exceptions (GLM's step order): a rank's own stop (the request
    // fails on both ranks) rides one step later, so rank 0 may publish one
    // more token before it; and a page growth the pool refused ends the
    // request at its length one token later (the refused growth still leaves
    // the margin's rows, `pageGrowthMargin`).
    for (label, _) in cases where label.hasPrefix("pipelined ") {
        let twin = "read-then-build " + label.dropFirst("pipelined ".count)
        guard let a = byCase[label], let b = byCase[twin] else { continue }
        if label.hasSuffix("pages refused") {
            check(a.finish == .length && b.finish == .length && a.tokens.count == b.tokens.count + 1
                  && Array(a.tokens.prefix(b.tokens.count)) == b.tokens,
                  "one-token \(label): \(a.tokens) is not read-then-build's \(b.tokens) and one token more")
            continue
        }
        check(a.tokens == b.tokens && a.finish == b.finish
              && (label.hasSuffix("local stop") || a.published == b.published),
              "one-token \(label): \(a.tokens)/\(a.finish) differs from read-then-build \(b.tokens)/\(b.finish)")
    }
    // Rank 0's stream against the agreed result. It streams exactly the result,
    // except when built ahead and rank 1 stops on its own or its pages run out:
    // rank 1's flag rides one step later, so rank 0 streams exactly one token the
    // final count drops (the request errors on both ranks then). Never a token
    // past a stop token, and never two extra.
    for (label, run) in byCase {
        let late = label.hasPrefix("pipelined ") && (label.hasSuffix("rank 1 local stop") || label.hasSuffix("rank 1 pages refused"))
        check(run.published.count == run.tokens.count + (late ? 1 : 0) && Array(run.published.prefix(run.tokens.count)) == run.tokens,
              "one-token \(label): rank 0 streamed \(run.published) against the result \(run.tokens)")
        check(run.published.firstIndex(of: OneTokenRank.stopToken).map { $0 == run.published.count - 1 } ?? true,
              "one-token \(label): rank 0 streamed past a stop token: \(run.published)")
    }
    // The read-then-build order (dev's Gemma loop) never builds ahead.
    if let plain = byCase["read-then-build stop token"] { check(!buildsAhead(plain.events), "read-then-build order is detected") }
    let stopToken = byCase["pipelined stop token"]
    check(stopToken?.tokens == [11, 12, 13, 14, 2] && stopToken?.finish == .eos, "pipelined stop token ends at EOS: \(String(describing: stopToken))")
    let late = checkLateOwnStops()
    print("one-token loop: \(cases.count + late) two-rank cases, build-ahead order, collectives and endings checked")
}

/// Rank 1 stops on its own (its memory gate, or pages that could not grow) on
/// the token just before rank 0 ends the request itself, at its stop token or
/// its length. Built one ahead, rank 1's flag rides the step after the one
/// already built, which rank 0, ending there, never reads; nor does the end
/// agreement take an abort (rank 0 did not stop on a flag). The request is
/// complete, so both ranks must report rank 0's finish: the owner fails the
/// request and the pair when rank 1's finish differs from rank 0's
/// (`ClusterWorkerRequest`, "Rank 1 finish or local retirement differs").
/// Rank 1 keeps the tokens it committed. Returns the number of cases.
func checkLateOwnStops() -> Int {
    typealias R = QwenTensorParallelStopRule
    let cases: [(String, OneTokenCase, R.Finish)] = [
        ("rank 1's memory stop just before the stop token", .init(pipelined: true, localStopAfter: [1: 4]), .eos),
        ("rank 1's memory stop just before the length",
         .init(pipelined: true, script: [11, 12, 13, 14, 15, 16], localStopAfter: [1: 5]), .length),
        ("rank 1's pages run out just before the stop token", .init(pipelined: true, refusePagesAfter: [1: 3]), .eos),
    ]
    for (label, spec, finish) in cases {
        guard let run = oneTokenPair(spec) else {
            failures += 1; print("FAIL: one-token \(label): a rank failed or hung"); continue
        }
        let zero = run.ended[0], one = run.ended[1]
        check(run.mismatch == nil, "one-token \(label): ranks ran different collectives: \(run.mismatch ?? "")")
        check(zero.finish == finish && zero.published == zero.tokens,
              "one-token \(label): rank 0 ends the request itself: \(zero.tokens)/\(zero.finish), streamed \(zero.published)")
        check(one.finish == zero.finish,
              "one-token \(label): rank 1 reports \(one.finish) where rank 0 reports \(zero.finish): the owner fails the request and the pair")
        check(one.tokens.count + 1 == zero.tokens.count && Array(zero.tokens.prefix(one.tokens.count)) == one.tokens,
              "one-token \(label): rank 1 keeps the tokens it committed: \(one.tokens) against \(zero.tokens)")
        // The end agreement takes no abort: rank 0 ended the request itself.
        let words = zip(R.endWords(rank: 0, count: zero.tokens.count, finish: zero.finish, clientStopped: false,
                                   stoppedForMemory: false),
                        R.endWords(rank: 1, count: 0, finish: .clientStop, clientStopped: false,
                                   stoppedForMemory: spec.localStopAfter[1] != nil)).map(+)
        check((try? R.readEnd(words)).map { $0.memoryStopRank == nil } == true,
              "one-token \(label): the end agreement \(words) takes no abort")
    }
    return cases.count
}

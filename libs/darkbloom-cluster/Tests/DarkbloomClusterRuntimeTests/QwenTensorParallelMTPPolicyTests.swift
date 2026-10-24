import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelMTPPolicyTests {
    @Test func failedDrainPreservesNativeRootsAndOriginalErrorBeyondCallerCatch() throws {
        final class Root {}
        final class Failure: Error, @unchecked Sendable { let root: Root; init(_ root: Root) { self.root = root } }
        weak var native: Root?, partial: Root?, cause: Failure?
        var custody: QwenTensorParallelMTPAbandonedLoad? = .init()
        do {
            let loaded = Root(), incomplete = Root(), failure = Failure(incomplete)
            native = loaded; partial = incomplete; cause = failure
            custody!.retain(failure, roots: [loaded])
        }
        #expect(native != nil && partial != nil && cause != nil)
        // A non-global test instance models process teardown. Production has
        // one process-lifetime owner and deliberately exposes no refund API.
        custody = nil
        #expect(native == nil && partial == nil && cause == nil)
    }

    @Test func optInBindsExactModelWidthAndNativeGraphWhileNilPreservesLegacy() throws {
        let terms = try QwenMTPTerms(depth: 4)
        for model in QwenRegisteredDenseModel.allCases {
            for width in [1, 2, 4, 8] {
                for keyed in [false, true] {
                    for paged in [false, true] {
                        try QwenTensorParallelMTPPolicy.require(model: model, lanes: width, keyed: keyed,
                            paged: paged, terms: nil, environment: ["DARKBLOOM_QWEN_MTP_SERIAL": "1"])
                        if model == .qwen38TwentySevenB && keyed && paged {
                            try QwenTensorParallelMTPPolicy.require(model: model, lanes: width, keyed: keyed,
                                paged: paged, terms: terms, environment: [:])
                        } else {
                            #expect(throws: ProbeError.self) {
                                try QwenTensorParallelMTPPolicy.require(model: model, lanes: width, keyed: keyed,
                                    paged: paged, terms: terms, environment: [:])
                            }
                        }
                    }
                }
            }
        }
        for width in [Int.min, -1, 0, 9, Int.max] {
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelMTPPolicy.require(model: .qwen38TwentySevenB, lanes: width,
                    keyed: true, paged: true, terms: terms, environment: [:])
            }
        }
        #expect(try QwenTensorParallelMTPPolicy.fields(terms: nil, inventory: nil).isEmpty)
        #expect(throws: ProbeError.self) { try QwenTensorParallelMTPPolicy.fields(terms: terms, inventory: nil) }
        for key in ["DARKBLOOM_QWEN_MTP_SERIAL", "DARKBLOOM_QWEN_MTP_DOUBLE_FORWARD"] {
            for value in ["1", "TRUE", "yes", "on"] {
                #expect(throws: ProbeError.self) {
                    try QwenTensorParallelMTPPolicy.require(model: .qwen38TwentySevenB, lanes: 1, keyed: true,
                        paged: true, terms: terms, environment: [key: value])
                }
            }
        }
        #expect(throws: ProbeError.self) {
            try QwenTensorParallelMTPPolicy.require(model: .qwen38TwentySevenB, lanes: 1, keyed: true,
                paged: true, terms: terms, environment: ["DARKBLOOM_QWEN_MTP_SHORTLIST": "256"])
        }
    }

    @Test func targetPrefixAcceptanceKeepsMismatchBonusStopsAndOutputBound() throws {
        for depth in 1...4 {
            let draft = Array(10..<(10 + depth))
            for accepted in 0...depth {
                var target = draft + [90]
                if accepted < depth { target[accepted] = 80 }
                for remaining in 1...(depth + 1) {
                    let result = try QwenTensorParallelMTPDecoder.accept(drafts: draft, targets: target,
                        remaining: remaining, stopTokens: [], vocabularySize: 100)
                    #expect(result.accepted == accepted)
                    #expect(result.tokens == Array(target.prefix(min(accepted + 1, remaining))))
                    for stopIndex in result.tokens.indices {
                        let stopped = try QwenTensorParallelMTPDecoder.accept(drafts: draft, targets: target,
                            remaining: remaining, stopTokens: [target[stopIndex]], vocabularySize: 100)
                        #expect(stopped.tokens == Array(result.tokens.prefix(stopIndex + 1)))
                    }
                }
            }
        }
        #expect(try QwenTensorParallelMTPDecoder.accept(drafts: [], targets: [7], remaining: 1,
            stopTokens: [], vocabularySize: 100).tokens == [7])
        for (drafts, targets, remaining) in [([1], [1], 1), ([1], [1, 2], 0), ([1], [1, 100], 2),
                                             ([-1], [1, 2], 2), ([1, 2, 3, 4, 5], [1, 2, 3, 4, 5, 6], 6)] {
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelMTPDecoder.accept(drafts: drafts, targets: targets,
                    remaining: remaining, stopTokens: [], vocabularySize: 100)
            }
        }
    }

    @Test func realCancellationAndDeadlineBecomeBilateralBoundaryVotes() throws {
        let id = UUID(), future = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let controls = [QwenResidentControl(deadline: future), QwenResidentControl(deadline: future)]
        for value in controls { try value.loaded(); try value.reserve(id); try value.start(id) }
        func vote(_ deadlines: [UInt64]) throws -> Bool {
            let values = try controls.enumerated().map { rank, value in
                try QwenTensorParallelMTPStopVote.contribution(rank: rank,
                    stopped: (try? value.check(deadline: deadlines[rank])) == nil)
            }
            return try QwenTensorParallelMTPStopVote.stopped(zip(values[0], values[1]).map(+))
        }
        #expect(try !vote([future, future]))
        #expect(try vote([future, 0]))
        controls[1].cancel(id)
        #expect(try vote([future, future]))
        // A malformed reduction never turns a peer stop into permission to
        // enter another assistant or target collective phase.
        for malformed: [Int32] in [[], [0], [0, 0, 0], [2, 0], [0, -1]] {
            #expect(throws: ProbeError.self) { try QwenTensorParallelMTPStopVote.stopped(malformed) }
        }
        #expect(throws: ProbeError.self) { try QwenTensorParallelMTPStopVote.contribution(rank: 2, stopped: false) }
    }
}

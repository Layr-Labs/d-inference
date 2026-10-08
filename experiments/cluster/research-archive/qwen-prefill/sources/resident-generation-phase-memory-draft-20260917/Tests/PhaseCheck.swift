import Foundation

@main struct PhaseCheck {
    static func main() throws {
        var passed = [String]()
        func run(_ name: String, _ body: () throws -> Void) throws { try body(); passed.append(name) }

        try run("closed identity and policy") {
            try identity().validate()
            try rejects("rank") { try identity(rank: 2).validate() }
            try rejects("geometry") { try identity(prompt: 0).validate() }
            try rejects("controller label is not native policy") { try identity(policy: "one_chunk_lookahead_v1").validate() }
        }
        try run("host bounds and finite recording scope") {
            let budget = try fixtureBudget(identity())
            try require(budget.maximumEvents == 64, "Frame-derived capacity")
            try require(budget.requiredHostReservationBytes == budget.eventAllocationBytes
                + budget.encodedResultAllocationBytes + budget.encodingScratchAllowanceBytes
                + budget.metadataAllowanceBytes + budget.memoryAllocationBytes, "Complete named host sum")
            try rejects("undersized allocator bound") {
                _ = try QwenGenerationPhaseBudget.derive(identity: identity(), hostAllocationBound: { $0 - 1 })
            }
            try rejects("oversized allocator bound") {
                _ = try QwenGenerationPhaseBudget.derive(identity: identity(), hostAllocationBound: { _ in Int.max })
            }
            try rejects("too many recorded frames") { _ = try fixtureBudget(identity(prompt: 8192, chunk: 1)) }
        }
        try run("no production observation entry") {
            try require(!QwenGenerationPhaseRecorder.nativeObservationEntryAvailable, "Native entry unexpectedly enabled")
        }
        try run("separate local and bilateral frontiers") {
            var now: UInt64 = 10
            let value = try recorder(clock: { defer { now += 1 }; return now })
            try value.begin(expected: identity())
            let first = QwenGenerationPhaseFrame(sequence: 0, tokenOffset: 0, tokenCount: 16, finalPromptChunk: false)
            let second = QwenGenerationPhaseFrame(sequence: 1, tokenOffset: 16, tokenCount: 16, finalPromptChunk: true)
            try value.observe(event(.requestBegin))
            try value.observe(event(.prepareBegin, frame: first, local: 0))
            try value.observe(event(.prepareEnd, frame: first, local: 16))
            try value.observe(event(.payloadSendEnd, frame: first))
            try value.observe(event(.originalWrapperReleased, frame: first, local: 16))
            try value.observe(event(.prepareBegin, frame: second, local: 16))
            try value.observe(event(.prepareEnd, frame: second, local: 32))
            try value.observe(event(.consumedAckWaitEnd, frame: first))
            try value.observe(event(.frameBegin, frame: second, agreed: 16))
            try value.observe(event(.firstTokenAgreed, frame: second, agreed: 32))
            try value.observe(event(.requestRetired, local: 33, agreed: 33))
            try value.seal()
            let trace = try value.successfulTrace()
            try require(trace.events.count == 11 && trace.events[8].observation.localCommittedTokens == nil,
                "Transport/control marker invented a local frontier")
            try require(trace.clockSource == "injected_cpu_fixture" && !trace.crossProcessClockAlignmentAsserted,
                "Fixture made a native/cross-clock claim")
        }
        try run("identity and incomplete retirement refusal") {
            let value = try recorder(clock: { 1 })
            try rejects("wrong owner") { try value.begin(expected: identity(rank: 1)) }
            try rejects("poisoned begin") { try value.begin(expected: identity()) }
            let incomplete = try recorder(clock: { 1 }); try incomplete.begin(expected: identity())
            try incomplete.observe(event(.requestBegin))
            try rejects("no retired marker") { try incomplete.seal() }
            try rejects("no exported failed trace") { _ = try incomplete.successfulTrace() }
        }
        try run("wrong rank and frame geometry") {
            let wrongRank = try recorder(identity(rank: 1), clock: { 1 })
            try wrongRank.begin(expected: identity(rank: 1))
            try rejects("producer event on consumer") { try wrongRank.observe(event(.prepareBegin)) }
            let wrongFrame = try recorder(clock: { 1 }); try wrongFrame.begin(expected: identity())
            try rejects("incorrect absolute token offset") {
                try wrongFrame.observe(event(.frameBegin,
                    frame: .init(sequence: 1, tokenOffset: 15, tokenCount: 16, finalPromptChunk: true)))
            }
        }
        try run("frontier reversal") {
            let value = try recorder(clock: { 1 }); try value.begin(expected: identity())
            try value.observe(event(.prepareEnd, local: 16))
            try rejects("local frontier") { try value.observe(event(.prepareBegin, local: 15)) }
        }
        try run("backwards and reentrant clocks poison") {
            var stamp: UInt64 = 2
            let backwards = try recorder(clock: { defer { stamp -= 1 }; return stamp })
            try backwards.begin(expected: identity()); try backwards.observe(event(.requestBegin))
            try rejects("clock reversal") { try backwards.observe(event(.readinessBegin)) }
            var reentrant: QwenGenerationPhaseRecorder?
            reentrant = try recorder(clock: {
                try? reentrant?.observe(event(.readinessBegin)); return 1
            })
            try reentrant!.begin(expected: identity())
            try rejects("caught recursive observation") { try reentrant!.observe(event(.requestBegin)) }
        }
        try run("reservation loss and reentry poison") {
            var live = true
            let value = try recorder(clock: { 1 }, reservation: { if !live { throw FixtureFailure.reservation } })
            try value.begin(expected: identity()); try value.observe(event(.requestBegin))
            try value.observe(event(.requestRetired)); live = false
            try rejects("reservation lost before seal") { try value.seal() }
            var nested: QwenGenerationPhaseRecorder?; var recurse = false
            nested = try recorder(clock: { 1 }, reservation: {
                if recurse { try? nested?.observe(event(.readinessBegin)) }
            })
            try nested!.begin(expected: identity()); recurse = true
            try rejects("caught reservation reentry") { try nested!.observe(event(.requestBegin)) }
        }
        try run("capacity and wide-field JSON footprint") {
            // Maximum supported event count with wide timestamp/frontier/frame
            // fields. Repeated markers fabricate a serialization boundary;
            // this is not a valid native action replay or retirement proof.
            let id = identity(prompt: 8192, chunk: 274, output: 128)
            let budget = try fixtureBudget(id)
            try require(budget.maximumEvents == 512, "Maximum event count")
            let value = try recorder(id, clock: { UInt64.max }); try value.begin(expected: id)
            try value.observe(event(.requestBegin))
            let frame = QwenGenerationPhaseFrame(sequence: 29, tokenOffset: 7946,
                tokenCount: 246, finalPromptChunk: true)
            for _ in 0..<(budget.maximumEvents - 2) {
                try value.observe(event(.originalWrapperReleased, frame: frame, local: 8320, agreed: 8320))
            }
            try value.observe(event(.requestRetired)); try value.seal()
            let trace = try value.successfulTrace()
            let data = try JSONEncoder().encode(trace)
            try require(!data.isEmpty && data.count <= QwenGenerationPhaseBudget.maximumEncodedBytes, "Bounded trace JSON")
            let overflow = try recorder(clock: { 1 }); try overflow.begin(expected: identity())
            let overflowBudget = try fixtureBudget(identity())
            for _ in 0..<overflowBudget.maximumEvents { try overflow.observe(event(.readinessBegin)) }
            try rejects("event capacity") { try overflow.observe(event(.requestRetired)) }
        }
        try run("native error precedence and nil/decode suppression") {
            do {
                try event(.requestBegin).deliver(to: { _ in throw FixtureFailure.observation },
                    check: { throw FixtureFailure.native })
                throw FixtureFailure.assertion("Missing native error")
            } catch FixtureFailure.native { }
            var calls = 0
            let prefill = QwenLayerStageFrame(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: 16, finalPromptChunk: false)
            try observeQwenGenerationPhase(nil, .prepareBegin, frame: prefill, check: { calls += 1 })
            let decode = QwenLayerStageFrame(sequence: 2, phase: .decode, tokenOffset: 32, tokenCount: 1, finalPromptChunk: false)
            try observeQwenGenerationPhase({ _ in calls += 1 }, .prepareBegin, frame: decode, check: { calls += 1 })
            try require(calls == 0, "Disabled/decode hook invoked a callback/check")
        }
        let result: [String: Any] = ["groups": passed, "count": passed.count,
            "nativeOrModelExecuted": false, "nativeObservationEntryAvailable": false,
            "actualHostReservationProved": false, "fixtureClockOnly": true]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}

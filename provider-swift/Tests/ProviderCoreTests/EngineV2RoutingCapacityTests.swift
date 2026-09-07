import Testing
@testable import ProviderCore

@Suite("Workspace-aware routing token capacity")
struct EngineV2RoutingCapacityTests {
    @Test func aggregateBoundCoversEveryTwoRequestSplit() {
        let workspace: (Int) -> Int = { tokens in ((tokens + 7) / 8) * 32 }
        let aggregate: (Int, Int) -> Int? = { tokens, count in
            guard tokens > 0 else { return 0 }
            return workspace(tokens) + (min(tokens, count) - 1) * 32
        }
        let result = EngineV2RoutingCapacity.project(
            capacityBytes: 2000, committedBytes: 140, rawUsedTokens: 10,
            bytesPerToken: 10, additionalRequests: 2, fixedBytesPerRequest: 30,
            workspaceBytes: aggregate)
        #expect(result.additionalRequests == 2)
        let additional = Int(result.tokenBudgetMax - 10)
        #expect(additional > 0)
        for first in 0 ... additional {
            let second = additional - first
            let bytes = 140 + 60 + additional * 10 + workspace(first) + workspace(second)
            #expect(bytes <= 2000)
        }
        #expect(140 + 60 + (additional + 1) * 10 + aggregate(additional + 1, 2)! > 2000)
        // An already aggregated bound must not be multiplied by count again.
        #expect(additional > (2000 - 140 - 60) / 18)
    }

    @Test func lowerAdvertisedCountRetainsOneServiceableRequest() {
        let result = EngineV2RoutingCapacity.project(
            capacityBytes: 500, committedBytes: 0, rawUsedTokens: 0,
            bytesPerToken: 10, additionalRequests: 4, fixedBytesPerRequest: 100,
            workspaceBytes: { tokens, count in tokens == 0 ? 0 : count * 200 })
        #expect(result.additionalRequests == 1)
        #expect(result.tokenBudgetMax == 20)
    }

    @Test func nativeZeroWorkspaceKeepsTheLinearCapacity() {
        let result = EngineV2RoutingCapacity.project(
            capacityBytes: 1000, committedBytes: 100, rawUsedTokens: 10,
            bytesPerToken: 10, additionalRequests: 4, fixedBytesPerRequest: 0,
            workspaceBytes: { _, _ in 0 })
        #expect(result.additionalRequests == 4)
        #expect(result.tokenBudgetMax == 100)
    }

    @Test func unknownOrOverflowedBoundsFailClosed() {
        for workspace in [({ _, _ in nil }), ({ _, _ in Int.max }), ({ _, _ in -1 })] as [(Int, Int) -> Int?] {
            let result = EngineV2RoutingCapacity.project(
                capacityBytes: 1000, committedBytes: 100, rawUsedTokens: 10,
                bytesPerToken: 10, additionalRequests: 4, fixedBytesPerRequest: 0,
                workspaceBytes: workspace)
            #expect(result.additionalRequests == 0)
            #expect(result.tokenBudgetMax == 10)
        }
        let huge = EngineV2RoutingCapacity.project(
            capacityBytes: Int.max, committedBytes: 0, rawUsedTokens: 0,
            bytesPerToken: 1, additionalRequests: 1, fixedBytesPerRequest: 0,
            workspaceBytes: { _, _ in 0 })
        #expect(huge.tokenBudgetMax == Int64.max) // midpoint arithmetic must not overflow
    }

    @Test func aggregateProjectionPaysAllRawSplitsUpToItsAdvertisedBudget() {
        // A nonlinear per-row workspace with allocation rounding. The
        // aggregate inequality sum ceil(n/8) <= ceil(sum(n)/8) + K - 1
        // permits a tighter bound than K copies of the longest possible row.
        let workspace: (Int) -> Int = { $0 == 0 ? 0 : 40 + (($0 + 7) / 8) * 32 }
        let aggregate: (Int, Int) -> Int? = { tokens, count in
            guard tokens > 0 else { return 0 }
            let rows = min(tokens, count)
            return rows * 40 + (((tokens + 7) / 8) + rows - 1) * 32
        }
        for requestedCount in 1 ... 4 {
            for capacity in [300, 600, 1000, 2000] {
                let projection = EngineV2RoutingCapacity.project(
                    capacityBytes: capacity, committedBytes: 60, rawUsedTokens: 5,
                    bytesPerToken: 10, additionalRequests: requestedCount,
                    fixedBytesPerRequest: 25, workspaceBytes: aggregate)
                let total = Int(projection.tokenBudgetMax - 5), count = projection.additionalRequests
                guard total > 0 else { continue }
                // Dynamic programming enumerates every possible raw-token
                // split, including fewer rows and totals below the ceiling.
                var worst = Array(repeating: Array(repeating: 0, count: total + 1), count: count + 1)
                for rows in 1 ... count {
                    for tokens in 1 ... total {
                        worst[rows][tokens] = (0 ... tokens).map {
                            worst[rows - 1][tokens - $0] + workspace($0)
                        }.max()!
                        // The zero base also admits partial splits: every
                        // distribution with total <= tokens is covered.
                        let bytes = 60 + count * 25 + tokens * 10 + worst[rows][tokens]
                        #expect(bytes <= capacity)
                    }
                }
            }
        }
    }
}

/// Conservative scalar projection of a byte grant into the coordinator's raw
/// token budget. Workspace monotonically bounds every distribution of total
/// new raw tokens among at most the advertised number of new requests.
enum EngineV2RoutingCapacity {
    struct Projection: Equatable {
        let tokenBudgetMax: Int64
        let additionalRequests: Int
    }

    static func project(
        capacityBytes: Int, committedBytes: Int?, rawUsedTokens: Int64,
        bytesPerToken: Int, additionalRequests: Int, fixedBytesPerRequest: Int?,
        workspaceBytes: (Int, Int) -> Int?
    ) -> Projection {
        let unavailable = Projection(tokenBudgetMax: max(0, rawUsedTokens), additionalRequests: 0)
        guard capacityBytes > 0, let committedBytes, committedBytes >= 0,
            committedBytes < capacityBytes, rawUsedTokens >= 0, bytesPerToken > 0,
            additionalRequests > 0, let fixedBytesPerRequest, fixedBytesPerRequest >= 0
        else { return unavailable }
        let free = capacityBytes - committedBytes
        // Preserve the configured cap when its complete overhead fits. If
        // reserving all remaining slots would hide a serviceable single row,
        // lower only this heartbeat's advertised count to the fitting bound.
        for count in stride(from: additionalRequests, through: 1, by: -1) {
            let (fixed, fixedOverflow) = fixedBytesPerRequest.multipliedReportingOverflow(by: count)
            guard !fixedOverflow, fixed < free else { continue }
            let available = free - fixed
            var low = 0, high = available / bytesPerToken
            while low < high {
                let distance = high - low
                let middle = low + distance / 2 + distance % 2
                let fits: Bool
                if let workspace = workspaceBytes(middle, count), workspace >= 0 {
                    let (tokens, tokenOverflow) = middle.multipliedReportingOverflow(by: bytesPerToken)
                    let (total, totalOverflow) = tokens.addingReportingOverflow(workspace)
                    fits = !tokenOverflow && !totalOverflow && total <= available
                } else {
                    fits = false
                }
                if fits { low = middle } else { high = middle - 1 }
            }
            guard low > 0 else { continue }
            let (maximum, overflow) = rawUsedTokens.addingReportingOverflow(Int64(low))
            guard !overflow else { return unavailable }
            // The engine's aggregate envelope already covers every request
            // split; multiplying it by count again would hide usable capacity.
            return Projection(tokenBudgetMax: maximum, additionalRequests: count)
        }
        return unavailable
    }
}

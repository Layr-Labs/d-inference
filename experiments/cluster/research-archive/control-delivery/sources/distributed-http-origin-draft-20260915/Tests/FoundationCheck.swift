import Foundation

enum CheckFailure: Error { case failed(String), expected }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw CheckFailure.failed(message) }
}

@main struct FoundationCheck {
    static func main() async throws {
        let now = ContinuousClock.now
        let policy = try DistributedFirstTokenBudgetPolicy(
            baseMilliseconds: 10_000, millisecondsPerInputToken: 1)
        let context = DistributedRequestDeadlineContext(generationDeadline: now.advanced(by: .seconds(300)))
        let full = try policy.restricting(context, receivedAt: now, inputTokenCount: 8192)
        try require(full.firstTokenDeadline == now.advanced(by: .milliseconds(18_192)), "8192 actual tokens")
        try require(full.generationDeadline == context.generationDeadline, "generation unchanged")
        let short = try policy.restricting(context, receivedAt: now, inputTokenCount: 3)
        try require(short.firstTokenDeadline == now.advanced(by: .milliseconds(10_003)), "actual count, not profile maximum")

        let earlier = DistributedRequestDeadlineContext(
            generationDeadline: now.advanced(by: .seconds(2)), firstTokenDeadline: now.advanced(by: .seconds(1)))
        let restricted = try policy.restricting(earlier, receivedAt: now, inputTokenCount: 8192)
        try require(restricted == earlier, "earlier coordinator deadline wins")
        let capped = try policy.restricting(.init(generationDeadline: earlier.generationDeadline),
                                           receivedAt: now, inputTokenCount: 8192)
        try require(capped.firstTokenDeadline == earlier.generationDeadline, "generation cap")
        let expired = try policy.restricting(.init(generationDeadline: now.advanced(by: .seconds(-1))),
                                             receivedAt: now, inputTokenCount: 8192)
        do { try expired.checkAdmission(at: now); throw CheckFailure.expected }
        catch DistributedRequestDeadlineError.generationExpired {}

        for invalid in [(Int64(0), Int64(1)), (Int64(-1), Int64(1)), (Int64(1), Int64(-1))] {
            do { _ = try DistributedFirstTokenBudgetPolicy(baseMilliseconds: invalid.0,
                       millisecondsPerInputToken: invalid.1); throw CheckFailure.expected }
            catch DistributedFirstTokenBudgetError.invalidPolicy {}
        }
        do { try policy.validate(maximumPromptTokens: -1); throw CheckFailure.expected }
        catch DistributedFirstTokenBudgetError.invalidTokenCount {}
        let overflowing = try DistributedFirstTokenBudgetPolicy(baseMilliseconds: .max, millisecondsPerInputToken: 1)
        do { try overflowing.validate(maximumPromptTokens: 1); throw CheckFailure.expected }
        catch DistributedFirstTokenBudgetError.overflow {}
        let huge = try DistributedFirstTokenBudgetPolicy(baseMilliseconds: .max, millisecondsPerInputToken: 0)
        let bounded = try huge.restricting(context, receivedAt: now, inputTokenCount: 8192)
        try require(bounded.firstTokenDeadline == context.generationDeadline, "clamp before advancing clock")

        let handler = now.advanced(by: .seconds(-1)), profile = now.advanced(by: .seconds(-2))
        try require(DistributedRequestOrigin.earliest(handler: handler, profile: profile, now: now) == profile,
                    "profile origin wins")
        try require(DistributedRequestOrigin.earliest(handler: handler, profile: nil, now: now) == handler,
                    "handler origin retained")
        try require(DistributedRequestOrigin.earliest(handler: now.advanced(by: .seconds(1)), profile: nil, now: now) == now,
                    "future origin cannot extend")

        try require(DistributedRequestOrigin.current == nil, "empty task scope")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for origin in [handler, profile] {
                group.addTask {
                    try await DistributedRequestOrigin.$current.withValue(origin) {
                        await Task.yield()
                        try require(DistributedRequestOrigin.current == origin, "concurrent request isolation")
                        let copied = DistributedRequestOrigin.current
                        try DistributedRequestOrigin.$current.withValue(nil) {
                            try require(copied == origin, "explicit copy survives ended scope")
                        }
                    }
                    try require(DistributedRequestOrigin.current == nil, "restored task scope")
                }
            }
            try await group.waitForAll()
        }
        do {
            try DistributedRequestOrigin.$current.withValue(handler) { throw CheckFailure.expected }
        } catch CheckFailure.expected {}
        try require(DistributedRequestOrigin.current == nil, "throw restores scope")
        print("{\"groups\":5,\"passed\":true,\"foundationOnly\":true,\"httpTestsExecuted\":false}")
    }
}

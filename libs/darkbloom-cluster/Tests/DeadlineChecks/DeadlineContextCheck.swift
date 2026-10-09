import Foundation

private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private func rejects(_ error: DistributedRequestDeadlineError, _ body: () throws -> Void) throws {
    do { try body() } catch let actual as DistributedRequestDeadlineError {
        try require(actual == error, "wrong refusal: \(actual)"); return
    }
    throw Failure(message: "missing refusal \(error)")
}

@main struct DeadlineContextCheck {
    static func main() throws {
        let origin = ContinuousClock.now
        let context = DistributedRequestDeadlineContext(generationDeadline: origin.advanced(by: .seconds(100)),
                                                        firstTokenDeadline: origin.advanced(by: .seconds(40)))
        // Thirty seconds of preparation/queue wait are already gone at reserve.
        let queued = try context.localDeadlines(at: origin.advanced(by: .seconds(30)), uptimeBeforeNow: 1_000,
            maximumRemaining: .seconds(100), lifetimeDeadline: 200_000_001_000)
        try require(queued.generation == 70_000_001_000 && queued.admission == 10_000_001_000, "queue wait restarted")
        // A worker with less lifetime than the profile remains usable until its
        // existing ceiling; the reservation cannot enlarge that ceiling.
        let lifetime = try context.localDeadlines(at: origin, uptimeBeforeNow: 1_000,
            maximumRemaining: .seconds(100), lifetimeDeadline: 15_000_001_000)
        try require(lifetime.generation == 15_000_001_000 && lifetime.admission == lifetime.generation, "worker lifetime clamp")
        let profile = try context.localDeadlines(at: origin, uptimeBeforeNow: 1_000,
            maximumRemaining: .seconds(20), lifetimeDeadline: 200_000_001_000)
        try require(profile.generation == 20_000_001_000, "profile clamp")
        let earlier = context.restricted(to: .init(generationDeadline: origin.advanced(by: .seconds(200)),
                                                   firstTokenDeadline: origin.advanced(by: .seconds(300))))
        try require(earlier == context, "later policy replenished budget")
        let tighter = context.restricted(to: .init(generationDeadline: origin.advanced(by: .seconds(80)),
                                                   firstTokenDeadline: origin.advanced(by: .seconds(10))))
        try require(tighter.generationDeadline == origin.advanced(by: .seconds(80)) &&
                    tighter.firstTokenDeadline == origin.advanced(by: .seconds(10)), "separate restriction")
        try rejects(.generationExpired) { try context.checkAdmission(at: origin.advanced(by: .seconds(100))) }
        try rejects(.firstTokenExpired) { try context.checkAdmission(at: origin.advanced(by: .seconds(40))) }
        try rejects(.workerLifetimeExpired) {
            _ = try context.localDeadlines(at: origin, uptimeBeforeNow: 1_000,
                maximumRemaining: .seconds(100), lifetimeDeadline: 1_000)
        }
        try rejects(.uptimeOverflow) {
            _ = try context.localDeadlines(at: origin, uptimeBeforeNow: UInt64.max - 2,
                maximumRemaining: .seconds(1), lifetimeDeadline: UInt64.max)
        }
        try rejects(.invalidRemainingDuration) {
            _ = try context.localDeadlines(at: origin, uptimeBeforeNow: 0,
                maximumRemaining: .zero, lifetimeDeadline: 100)
        }
        // Fractional nanoseconds never round a deadline upward.
        let fractional = Duration(secondsComponent: 0, attosecondsComponent: 1_999_999_999)
        let floored = try context.localDeadlines(at: origin, uptimeBeforeNow: 100,
            maximumRemaining: fractional, lifetimeDeadline: 200)
        try require(floored.generation == 101 && floored.admission == 101, "subnanosecond remainder granted")
        try rejects(.invalidRemainingDuration) {
            _ = try context.localDeadlines(at: origin, uptimeBeforeNow: 0,
                maximumRemaining: .init(secondsComponent: 0, attosecondsComponent: 999_999_999), lifetimeDeadline: 100)
        }
        // Omitting TTFT keeps admission bounded by generation; it does not invent
        // a first-token policy. A later reserve loses the actual elapsed budget.
        let ordinary = DistributedRequestDeadlineContext(generationDeadline: origin.advanced(by: .seconds(10)))
        let later = try ordinary.localDeadlines(at: origin.advanced(by: .seconds(4)), uptimeBeforeNow: 50,
            maximumRemaining: .seconds(100), lifetimeDeadline: 20_000_000_000)
        try require(later.generation == 6_000_000_050 && later.admission == later.generation, "ordinary duration reset")
        print("{\"passed\":true,\"checks\":13,\"actualDeadlineSource\":true,\"modelOrNetworkExecution\":false}")
    }
}

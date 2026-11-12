import Foundation

extension StandaloneServer {
    /// How often the resident slots' bridges are sampled. The state file is
    /// rewritten every 250 ms (`startLifecycleControl`); a rate needs a span.
    static let runningRequestSampleSeconds: TimeInterval = 2

    /// The answers in progress for `darkbloom status` on a Mac that serves only
    /// you, as the coordinator-connected provider lists them
    /// (`ProviderLoop.refreshRunningRequests`): every resident slot's bridge,
    /// sampled at most every `runningRequestSampleSeconds`, each elapsed time
    /// carried on to `now` between samples.
    func runningRequestsForState(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async
        -> [DaemonState.RunningRequest]
    {
        if runningRequestsSample.map({ now - $0.at >= Self.runningRequestSampleSeconds }) ?? true {
            var samples: [RunningRequestProgressTracker.Sample] = []
            for (model, slot) in slots.sorted(by: { $0.key < $1.key }) {
                samples += await slot.bridge.runningRequestSamples(model: model)
            }
            runningRequestsSample = (runningRequestTracker.update(samples, now: now), now)
        }
        guard let sample = runningRequestsSample else { return [] }
        return sample.requests.map { request in
            var request = request
            request.elapsedSeconds += max(0, now - sample.at)
            return request
        }
    }
}

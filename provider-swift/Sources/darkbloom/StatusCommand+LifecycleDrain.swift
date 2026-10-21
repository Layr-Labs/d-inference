import ProviderCore

extension Status {
    /// A drain closes admission in the live daemon, and the process outlives a
    /// drain that did not finish or whose relaunch never happened. "Daemon:
    /// running" alone then reads as healthy while the coordinator sees the
    /// provider offline. The record does not say whether `stop`, `restart`,
    /// `start`, `update` or a model switch began the drain, so the advice
    /// names the way out for both stopping and serving again.
    static func lifecycleDrainLine(_ status: ProviderDrainStatus?) -> String? {
        guard let status else { return nil }
        switch status.outcome {
        case .serving:
            return nil
        case .draining:
            return "Not serving: draining, \(status.remaining) unfinished request(s); "
                + "new requests are refused until it finishes"
        case .timedOut, .busy:
            return "Not serving: the last drain did not finish (\(status.remaining) unfinished request(s)); "
                + "new requests are refused. Run `\(BuildEnvironment.current.cliName) stop` or `\(BuildEnvironment.current.cliName) restart` to drain again, "
                + "or add `--force` to interrupt unfinished work"
        case .drained, .forced:
            // Outside its schedule window the daemon idles as drained without a
            // request (`Start.waitOutsideSchedule`); `Availability: inactive`
            // already says so, and the window reopens serving on its own.
            guard status.requestID != nil else { return nil }
            return "Not serving: drained; new requests are refused until the provider is replaced. "
                + "Run `\(BuildEnvironment.current.cliName) restart` or `\(BuildEnvironment.current.cliName) start` to serve again, or `\(BuildEnvironment.current.cliName) stop` to finish stopping"
        }
    }
}

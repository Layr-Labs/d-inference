import ProviderCore

extension Status {
    /// The served counts are this daemon process's own completions, not the
    /// coordinator's paid jobs. They restart at zero with the daemon, count
    /// output tokens only, and include requests that ended early on a
    /// coordinator cancel or a dropped connection, which the coordinator may
    /// not pay for, and free requests routed to the owner's own machine. The
    /// console's Earnings page is the record of paid work.
    static func servedRequestLines(_ stats: DaemonState.Stats, uptime: String) -> [String] {
        var lines = [
            "Requests served since the daemon started (\(uptime) ago): \(stats.requestsServed)"
                + "  |  output tokens: \(stats.tokensGenerated)",
        ]
        guard stats.requestsServed > 0 else { return lines }
        if let endedEarly = stats.cancellationsPartialComplete, endedEarly > 0 {
            lines.append("  \(endedEarly) of them ended early on a coordinator cancel or a dropped connection "
                + "and may be unpaid.")
        }
        lines.append("  Paid jobs are listed under Earnings in the console; requests to your own machine are free.")
        return lines
    }
}

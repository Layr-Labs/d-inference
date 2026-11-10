import ProviderCore

extension Status {
    /// The served counts are this daemon process's own completions, not the
    /// coordinator's paid jobs. They restart at zero with the daemon, count
    /// output tokens only, and include free requests routed to the owner's own
    /// machine and requests that ended early after output went out. The
    /// coordinator's `cancel` carries no cause, so the daemon cannot tell a
    /// paid early end from an unpaid one; the note says which cases the
    /// coordinator pays for. The console's Earnings page is the record of paid
    /// work.
    static func servedRequestLines(state: DaemonState, now: Double) -> [String] {
        let stats = state.stats
        let uptime = compactDuration(state.uptimeSeconds(now: now))
        var lines = [
            "Requests served since the daemon started (\(uptime) ago): \(stats.requestsServed)"
                + "  |  output tokens: \(stats.tokensGenerated)",
        ]
        guard stats.requestsServed > 0 else { return lines }
        if let endedEarly = stats.cancellationsPartialComplete, endedEarly > 0 {
            lines.append("  \(endedEarly) of them ended early: paid for the work done if the requester left mid-answer,")
            lines.append("  unpaid if another Mac answered first, this Mac started too late or lost its connection.")
        }
        lines.append("  Paid jobs are listed under Earnings in the console; requests to your own machine are free.")
        return lines
    }
}

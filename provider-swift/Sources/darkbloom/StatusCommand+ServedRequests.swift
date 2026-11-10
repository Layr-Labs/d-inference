import ProviderCore

extension Status {
    /// The served counts are this daemon process's own completions, not the
    /// coordinator's paid jobs. They restart at zero with the daemon, count
    /// output tokens only, and include free requests routed to the owner's own
    /// machine and requests that ended early after output went out. The
    /// console's Earnings page is the record of paid work.
    static func servedRequestLines(state: DaemonState, now: Double) -> [String] {
        let stats = state.stats
        let uptime = compactDuration(state.uptimeSeconds(now: now))
        var lines = [
            "Requests served since the daemon started (\(uptime) ago): \(stats.requestsServed)"
                + "  |  output tokens: \(stats.tokensGenerated)",
        ]
        guard stats.requestsServed > 0 else { return lines }
        if let endedEarly = stats.cancellationsPartialComplete, endedEarly > 0 {
            lines += endedEarlyLines(total: endedEarly, byCause: stats.endedEarly)
        }
        lines.append("  Paid jobs are listed under Earnings in the console; requests to your own machine are free.")
        return lines
    }

    /// The requests that ended early, by what stopped them and whether the
    /// coordinator pays. A daemon that keeps no causes gets the one note
    /// that says which cases are paid. A coordinator cancel names its cause
    /// only from coordinators that send one; the others share that note.
    static func endedEarlyLines(total: UInt64, byCause counts: EndedEarlyCounts?) -> [String] {
        guard let counts else {
            return [
                "  \(total) of them ended early: paid for the work done if the requester left mid-answer,",
                "  unpaid if another Mac answered first, this Mac started too late or lost its connection.",
            ]
        }
        let causes: [(count: UInt64, words: String)] = [
            (counts.requesterLeftPaid, "paid for the work done: the requester left mid-answer"),
            (counts.stoppedOnThisMac, "paid for the work done: stopped on this Mac (a drain or an add-on hold)"),
            (counts.otherPaid, "paid for the work done: stopped by the network"),
            (counts.anotherMacFirst, "unpaid: another Mac answered first"),
            (counts.startedTooLate, "unpaid: this Mac started too late"),
            (counts.otherUnpaid, "unpaid: stopped by the network for another reason"),
            (counts.connectionLost, "unpaid: this Mac lost its connection"),
        ]
        var lines = ["  \(total) of them ended early:"]
        for cause in causes where cause.count > 0 {
            lines.append("    \(cause.count) \(cause.words)")
        }
        // Counted without a cause: a cancel from a coordinator that gives none.
        let withoutCause = counts.noReason + (total > counts.total ? total - counts.total : 0)
        if withoutCause > 0 {
            lines.append("    \(withoutCause) stopped by the network: paid for the work done if the requester left mid-answer,")
            lines.append("      unpaid if another Mac answered first or this Mac started too late")
        }
        return lines
    }
}

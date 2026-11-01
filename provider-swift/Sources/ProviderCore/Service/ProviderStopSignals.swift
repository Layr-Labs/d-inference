import Darwin

/// Which signals ask a serving process for its cooperative stop.
enum ProviderStopSignals {
    /// SIGTERM and SIGINT always ask for the stop. SIGHUP joins them for a
    /// provider someone started by hand, so closing its terminal drains it
    /// and releases its models instead of ending the process where it stands.
    ///
    /// Two kinds of start leave SIGHUP as they found it:
    /// - The provider's launchd job has no terminal to close, and a
    ///   signal-driven stop also disarms crash recovery, so a hangup sent to
    ///   the daemon does not become one.
    /// - A start that arrives with SIGHUP ignored (`nohup`, a supervisor)
    ///   asked to outlive its terminal.
    static func resolve(launchedByLaunchd: Bool, hangupIgnoredAtStart: Bool) -> [Int32] {
        launchedByLaunchd || hangupIgnoredAtStart ? [SIGTERM, SIGINT] : [SIGTERM, SIGINT, SIGHUP]
    }

    /// Whether SIGHUP was already ignored the first time this process asked.
    /// Read once and kept: a `ProviderSignalHandler` ignores the signals it
    /// takes, so a later read would mistake its doing for a `nohup` start.
    private static let hangupIgnoredAtStart = isIgnored(SIGHUP)

    /// The stop signals for this process, from how it was started.
    static func forCurrentProcess() -> [Int32] {
        resolve(
            launchedByLaunchd: ProviderStartReason.launchedByLaunchd(),
            hangupIgnoredAtStart: hangupIgnoredAtStart)
    }

    /// Runs `exec`, which replaces this process image and returns only when
    /// that fails. An ignored signal stays ignored in the new image, which
    /// would read a SIGHUP its predecessor's handler took as a `nohup` start
    /// and never take hangups again. So a SIGHUP this process ignores only
    /// because its handler took it has its default action across the call,
    /// and is ignored again if `exec` comes back.
    static func withHangupAsAtStart(during exec: () -> Void) {
        let takenByHandler = !hangupIgnoredAtStart && isIgnored(SIGHUP)
        if takenByHandler { signal(SIGHUP, SIG_DFL) }
        exec()
        if takenByHandler { signal(SIGHUP, SIG_IGN) }
    }

    static func isIgnored(_ signo: Int32) -> Bool {
        var current = sigaction()
        guard sigaction(signo, nil, &current) == 0 else { return false }
        // `SIG_IGN` is the address 1, not a function; compare it as a number.
        let handlerAddress = withUnsafeBytes(of: current.__sigaction_u) { $0.load(as: UInt.self) }
        return handlerAddress == unsafeBitCast(SIG_IGN, to: UInt.self)
    }
}

import Foundation

// A pair the coordinator forms (a setup saved with a cluster approval, "offered for pairing") serves only once the
// coordinator committed it and both Macs loaded their share: both members being registered is not serving. On
// 2026-11-03 both screens said "Serving" and "Done" while nothing was loaded (the coordinator refused the pair because
// its rank 0 had no App Attest trust). Pure (Foundation only): the onboarding checks compile it with plain swiftc.

/// How a coordinator-paired part reports its pair's progress in its log (its stderr, the cluster service's
/// `rank.log`): one line per change, the latest one telling where the CURRENT run stands.
public enum ClusterOnboardingPairReport {
    public static let logPrefix = "Pair: "

    /// The coordinator committed a start: both Macs load their share of the model.
    public static let startingLine = logPrefix + "starting"

    /// Both ranks loaded and the pair answered its own first request (the warm-up, `ProviderLoop+ClusterPairWarmup`);
    /// requests from the coordinator reach it now.
    public static func servingLine(warmupSeconds: Double?) -> String {
        logPrefix + "serving" + (warmupSeconds.map { " (first request in \(String(format: "%.2f", $0)) s)" } ?? "")
    }

    /// The committed start ended or never formed, and why: the cause's text between the parentheses
    /// (`ClusterPairStopCause.logText`).
    public static func stoppedLine(_ cause: ClusterPairStopCause) -> String { logPrefix + "stopped (" + cause.logText + ")" }

    /// Where the leader's failure carries rank 1's own words (the follower's reason over the link).
    public static let followerSaidMarker = "; rank 1 said: "

    public enum State: Sendable, Equatable {
        case starting
        /// The first request's time ("in 0.84 s") when the warm-up ran.
        case serving(test: String?)
        /// Why, read back from the text the part wrote.
        case stopped(ClusterPairStopCause)
    }

    /// The latest pair line the part that began writing `log` at `offset` wrote, however many lines follow it
    /// (`ClusterLogScan`); nil when there is none.
    public static func latest(inLogFile log: URL, from offset: UInt64 = 0, limit: UInt64 = ClusterLogScan.limitBytes) -> State? {
        ClusterLogScan.lastLine(in: log, from: offset, limit: limit) { $0.hasPrefix(logPrefix) }
            .flatMap { state(String($0.dropFirst(logPrefix.count))) }
    }

    /// The latest pair line in `log`, nil when there is none.
    public static func latest(inLog log: String) -> State? {
        guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(logPrefix) }) else { return nil }
        return state(String(line.dropFirst(logPrefix.count)))
    }

    /// The state a pair line's text (after the prefix) says; nil for text no build writes.
    public static func state(_ text: String) -> State? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text == "starting" { return .starting }
        if text.hasPrefix("serving") {
            guard let open = text.range(of: "(first request in "), let close = text.range(of: ")", range: open.upperBound..<text.endIndex)
            else { return .serving(test: nil) }
            return .serving(test: "in " + text[open.upperBound..<close.lowerBound])
        }
        if text.hasPrefix("stopped ("), text.hasSuffix(")") {
            return .stopped(ClusterPairStopCause(logText: String(text.dropFirst("stopped (".count).dropLast())))
        }
        return nil
    }

    /// The text a status carries for `state` (`ClusterServiceStatus.Child.pair`): the line without its prefix.
    public static func text(_ state: State) -> String {
        switch state {
        case .starting: return String(startingLine.dropFirst(logPrefix.count))
        case .serving(let test):
            return String(servingLine(warmupSeconds: nil).dropFirst(logPrefix.count)) + (test.map { " (first request \($0))" } ?? "")
        case .stopped(let cause): return String(stoppedLine(cause).dropFirst(logPrefix.count))
        }
    }
}

/// Why a pair the coordinator formed stopped, or never formed, as the part that leads it (rank 0) knows it. That part
/// makes the value where the stop happens and writes it once, as the text between the parentheses of its
/// `Pair: stopped (…)` line (`logText`). Every reader takes that text back to the same value (`init(logText:)`) and
/// says it from the value (`ClusterOnboardingNotServing.words`): no reader looks for letters in the text of a cause
/// that has a case.
///
/// The text crosses the cable in the status both Macs read (`ClusterServiceStatus.Child.pair`), and the other Mac may
/// run another build. So the text of a cause an earlier build wrote never changes. A new cause's text is one that
/// build shows as it is ("The pair stopped (…)": lower case, at most `earlierBuildShownCharacters`, and none of the
/// words it looks for). Text this build has no case for is `other`: written back and said exactly as before.
public enum ClusterPairStopCause: Sendable, Equatable {
    /// A rank's load gate refused its share of the model.
    case memoryRefused(MemoryRefusal)
    /// The start failed and its incident was classified: the incident's guidance code.
    case guidance(Guidance)
    /// The start failed and no incident was recorded for it.
    case didNotForm
    /// A rank ended, or its lease lapsed, while the pair's slot was published.
    case readinessLost
    /// Both ranks loaded, and the pair's own first request (the warm-up) failed. The engine's detail stays in this
    /// Mac's log: the line carries fixed words only.
    case firstRequestFailed
    /// This Mac's part is stopping (a stop, a drain, an update) and no session of its own ended the start first.
    case memberStopping
    /// The member session that committed the start ended, and how; nil in a line that does not say how: an earlier
    /// build's, or this build's for a slot retired after a later session's stop replaced the record of its own
    /// (`ProviderLoop.serveCommittedStart`).
    case sessionEnded(SessionEnd?)
    /// Text no case names: a later build's cause, or what an earlier build wrote. Only `init(logText:)` makes it, so it
    /// never holds text a case writes.
    case other(String)

    /// The longest reason an earlier build shows as it is; a longer one reads "no reason given" there.
    public static let earlierBuildShownCharacters = 80

    /// A rank's load-gate refusal: the rank, and both figures in GiB as that rank said them ("73.57").
    public struct MemoryRefusal: Sendable, Equatable {
        public let rank: Int
        public let needs: String
        public let has: String

        /// From that rank's words ("… needs 73.57 GiB of admissible memory and has 68.20 GiB …"); nil unless they give
        /// both figures.
        public init?(rank: Int, said: String) {
            let pattern = #"needs ([0-9]+(?:\.[0-9]+)?) GiB of admissible memory and has ([0-9]+(?:\.[0-9]+)?) GiB"#
            guard let match = said.range(of: pattern, options: .regularExpression) else { return nil }
            let numbers = said[match].split(separator: " ").filter { Double($0) != nil }
            guard numbers.count == 2 else { return nil }
            self.rank = rank; needs = String(numbers[0]); has = String(numbers[1])
        }

        /// From a stopped line's text ("memory_gate_refused: rank 1 needs 73.57 GiB, has 68.20 GiB"), whatever the
        /// spacing between its words, as every build has read it; nil for any other text.
        init?(reading text: String) {
            let prefix = Guidance.memoryGateRefused.rawValue + ": rank "
            guard text.hasPrefix(prefix) else { return nil }
            let parts = text.dropFirst(prefix.count).split(separator: " ")
            guard parts.count == 7, let rank = Int(parts[0]), parts[1] == "needs", Double(parts[2]) != nil,
                  parts[4] == "has", Double(parts[5]) != nil else { return nil }
            self.rank = rank; needs = String(parts[2]); has = String(parts[5])
        }

        var logText: String { "\(Guidance.memoryGateRefused.rawValue): rank \(rank) needs \(needs) GiB, has \(has) GiB" }

        /// Both figures as the screens say them, one decimal each.
        var shown: (needs: String, has: String) {
            (String(format: "%.1f", Double(needs) ?? 0), String(format: "%.1f", Double(has) ?? 0))
        }
    }

    /// The guidance code of a failed start's incident (`ClusterGuidance.code` in `DarkbloomClusterRemote`). This file is
    /// compiled alone by the onboarding checks and cannot import that module, so the codes are listed here;
    /// `ClusterPairStopCauseTests` holds the two lists equal, and a code added here must be given its words
    /// (`ClusterOnboardingNotServing.words`) before this file compiles.
    public enum Guidance: String, Sendable, CaseIterable {
        case orphanedWiredMemory = "orphaned_wired_memory"
        case deviceBusy = "device_busy"
        case localProviderRunning = "local_provider_running"
        case memoryGateRefused = "memory_gate_refused"
        case followerNotConnected = "follower_not_connected"
        case localNetworkDenied = "local_network_denied"
        case loginRejected = "login_rejected"
        case hostKeyUnknown = "host_key_unknown"
        case hostIdentityChanged = "host_identity_changed"
        case noMatchingHostKey = "no_matching_host_key"
        case addressUnresolved = "address_unresolved"
        case peerUnreachable = "peer_unreachable"
        case bootstrapStalled = "bootstrap_stalled"
        case linkNotReady = "link_not_ready"
        case rdmaCompletionError = "rdma_completion_error"
        case collectiveStall = "collective_stall"
        case rankLeaseExpired = "rank_lease_expired"
        case workerRuntimeUnverified = "worker_runtime_unverified"
        case versionMismatch = "version_mismatch"
        case modelIdentityMismatch = "model_identity_mismatch"
        case modelStageIncomplete = "model_stage_incomplete"
        case planChanged = "plan_changed"
        case unsupportedMode = "unsupported_mode"
        case peerLost = "peer_lost"
        case workerCrashed = "worker_crashed"
        case peerTimeout = "peer_timeout"
        case launchInterrupted = "launch_interrupted"
        case configurationInvalid = "configuration_invalid"
        case cleanupUnresolved = "cleanup_unresolved"
        case modelBusy = "model_busy"
        case listenerFailed = "listener_failed"
        case requestFailed = "request_failed"
        case runtimeError = "runtime_error"
        case unknownFailure = "unknown_failure"
    }

    /// How the member session that committed a start ended (`NativePairMemberSession`), without the error an early end
    /// carries: that stays in the session's own words (`NativePairSessionEnd.words`).
    public enum SessionEnd: Sendable, Equatable, CaseIterable {
        case coordinatorCancelled
        case grantExpired
        case connectionClosed
        case connectionStayedClosed
        case couldNotServe
        case endedEarly
        case ownerInvalidated
        case memberStopping
        case ownerEndedCleanly

        /// The session's own words. The Mac that follows fences the leading Mac's session with them
        /// (`ClusterLinkWorkerServer.sessionEnded`), and its report of that fence reaches the leading Mac over the
        /// link: never reword one.
        public var words: String {
            switch self {
            case .coordinatorCancelled: return "the coordinator cancelled it"
            case .grantExpired: return "the coordinator's grant expired"
            case .connectionClosed: return "its connection to the coordinator closed"
            case .connectionStayedClosed: return "its connection to the coordinator stayed closed past the grace"
            case .couldNotServe: return "this Mac could not serve it"
            case .endedEarly: return "it ended early"
            case .ownerInvalidated: return "its owner was invalidated before the prelude completed"
            case .memberStopping: return "this Mac's member is stopping"
            case .ownerEndedCleanly: return "its owner ended cleanly"
            }
        }

        /// What a stopped line says after "committed start ended: ". Both Macs' screens show the line's text, so
        /// these name no Mac ("this Mac" would be the wrong one on the other screen). They are short and in lower
        /// case, so an earlier build shows the whole reason byte for byte (`earlierBuildShownCharacters`).
        var logWords: String {
            switch self {
            case .coordinatorCancelled: return "the coordinator cancelled it"
            case .grantExpired: return "the coordinator's grant expired"
            case .connectionClosed: return "its connection to the coordinator closed"
            case .connectionStayedClosed: return "its coordinator connection stayed closed"
            case .couldNotServe: return "it could not be served"
            case .endedEarly: return "it ended early"
            case .ownerInvalidated: return "its owner was invalidated before the prelude completed"
            case .memberStopping: return "its part is stopping"
            case .ownerEndedCleanly: return "its owner ended cleanly"
            }
        }
    }

    /// Every cause that has no figure, code or text of its own. `init(logText:)` finds a line's cause here by the text
    /// each writes, so a case this list lacks is written but reads back as `other`, and no switch fails to compile
    /// for it: `ClusterPairStopCauseTests.noCaseIsLeftOutOfTheTables` fails until a new case is listed.
    static let fixed: [ClusterPairStopCause] = [.didNotForm, .readinessLost, .firstRequestFailed, .memberStopping, .sessionEnded(nil)]
        + SessionEnd.allCases.map { .sessionEnded($0) }

    /// The text between the parentheses of the part's `Pair: stopped (…)` line, and of the status's pair text.
    public var logText: String {
        switch self {
        case .memoryRefused(let refusal): return refusal.logText
        case .guidance(let code): return code.rawValue
        case .didNotForm: return "the pair did not form"
        case .readinessLost: return "pair readiness lost"
        case .firstRequestFailed: return "its first request failed"
        case .memberStopping: return "member stopping"
        // An earlier build wrote the first three words alone. What follows them is new, and that build shows it as
        // it is.
        case .sessionEnded(let end): return "committed start ended" + (end.map { ": " + $0.logWords } ?? "")
        case .other(let text): return text
        }
    }

    /// The cause a line's text says. Only text a case writes, byte for byte, is that case; any other text is `other`,
    /// so it is written back unchanged.
    public init(logText text: String) {
        if let refusal = MemoryRefusal(reading: text), refusal.logText == text {
            self = .memoryRefused(refusal)
        } else if let code = Guidance(rawValue: text) {
            self = .guidance(code)
        } else {
            self = Self.fixed.first { $0.logText == text } ?? .other(text)
        }
    }

    /// The cause of a start that failed with `error` (the leader's failure as it was recorded) and the guidance code of
    /// the incident recorded for it (`guidance`; nil: none was). A load-gate refusal the Mac that follows reported
    /// (`ClusterOnboardingPairReport.followerSaidMarker`) is that rank's, with both of its figures.
    public static func failedStart(guidance: String?, error: String) -> ClusterPairStopCause {
        guard let guidance else { return .didNotForm }
        // A code `Guidance` lacks is written as it is, like any text no case names.
        guard let code = Guidance(rawValue: guidance) else { return ClusterPairStopCause(logText: guidance) }
        if code == .memoryGateRefused, let marker = error.range(of: ClusterOnboardingPairReport.followerSaidMarker),
           let refusal = MemoryRefusal(rank: 1, said: String(error[marker.upperBound...])) {
            return .memoryRefused(refusal)
        }
        return .guidance(code)
    }
}

/// The last line of a log that `matches`, read backwards from its end in chunks. A line written once per change (a
/// pair's progress, the serving notice) stays found however many request lines follow it; a fixed tail lost it (the
/// production pair's last 16 KiB held about nine minutes of request lines, 2026-11-04). Never before `offset`, where
/// the part that writes the log began: a line an earlier part wrote is never this part's (a log shorter than `offset`
/// was replaced and is read from its start). At most `limit` bytes back from the end.
public enum ClusterLogScan {
    /// 8 MiB: tens of thousands of request lines (160–300 bytes each), days of a busy pair; a status read never scans
    /// more, so a line written longer ago than that reads as absent.
    public static let limitBytes: UInt64 = 8 * 1024 * 1024
    public static let chunkBytes = 64 * 1024

    public static func lastLine(in log: URL, from offset: UInt64 = 0, limit: UInt64 = limitBytes, chunk: Int = chunkBytes,
                                where matches: (Substring) -> Bool) -> Substring? {
        guard let handle = FileHandle(forReadingAtPath: log.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let floor = max(offset <= size ? offset : 0, size > limit ? size - limit : 0)
        var end = size
        // The start of the line the chunk edge below cut, completed by the next chunk read.
        var carry = Data()
        while end > floor {
            let begin = end - min(end - floor, UInt64(max(1, chunk)))
            guard (try? handle.seek(toOffset: begin)) != nil, var data = try? handle.read(upToCount: Int(end - begin)) else { return nil }
            data.append(carry)
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            carry = begin > floor ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() {
                let text = Substring(String(decoding: line, as: UTF8.self))
                if matches(text) { return text }
            }
            end = begin
        }
        return nil
    }
}

/// The live rows while the parts load: the first row is the wait itself, then one row per Mac ("This Mac: loading
/// its share"), each with the time since the wait began; a Mac's time stops when it is first seen ready. A progress
/// report carries the Mac rows after its first line, one per line. No bar or percent: no real fraction is reported.
public struct ClusterOnboardingLoadRows: Sendable {
    public let started: Date
    private var readyAt: [String: Date] = [:]

    public init(started: Date) { self.started = started }

    /// `width`: the room of a live row; a Mac's row that does not fit drops its layers, then its long words, before
    /// the terminal would cut it.
    public mutating func rows(_ title: String, report: String?, now: Date, width: Int? = nil) -> [String] {
        let parts = report?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let head = (parts.first.map { "\(title) (\($0))" } ?? title) + " \u{00B7} " + Self.elapsed(now.timeIntervalSince(started))
        return [head] + parts.dropFirst().map { row in
            let mac = row.components(separatedBy: ": ").first ?? row
            let ready = row.hasSuffix(": ready") || row.contains(": ready (")
            if ready, readyAt[mac] == nil { readyAt[mac] = now }
            let end = ready ? readyAt[mac] ?? now : now
            let time = " \u{00B7} " + Self.elapsed(end.timeIntervalSince(started))
            return ClusterOnboardingStartWords.fitted(Self.shorter(row).map { $0 + time }, width: width)
        }
    }

    /// A Mac's row, then shorter forms of it: without its layers, "Other Mac", "loading".
    static func shorter(_ row: String) -> [String] {
        var forms = [row]
        func add(_ text: String) { if text != forms.last { forms.append(text) } }
        let bare = row.replacingOccurrences(of: #" \(layers [^)]*\)"#, with: "", options: .regularExpression)
        add(bare)
        add(bare.replacingOccurrences(of: "The other Mac", with: "Other Mac"))
        add(forms.last!.replacingOccurrences(of: "loading its share", with: "loading")
            .replacingOccurrences(of: "starting its part", with: "starting"))
        return forms
    }

    /// "48 s", "1 min 15 s".
    static func elapsed(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return whole < 60 ? "\(whole) s" : "\(whole / 60) min \(whole % 60) s"
    }
}

/// Why a pair the coordinator forms does not serve, in one plain line for the screens, with what to do. The words come
/// from what the two Macs know: their Darkbloom login, the coordinator's trust status for each member (App Attest),
/// the guidance of the incident a failed start recorded, and a coordinator refusal reason when one reaches them.
public enum ClusterOnboardingNotServing {
    /// `mac` as the screen names it ("this Mac", "the other Mac (Apple M3 Ultra, 256 GB)").
    public static func notLoggedIn(_ macs: [String]) -> String {
        "\(ClusterOnboardingMacName.sentence(joined(macs))) \(macs.count == 1 ? "isn't" : "aren't") logged in to Darkbloom, "
            + "so the coordinator won't pair \(macs.count == 1 ? "it" : "them")"
    }

    /// The reason is a missing login (`notLoggedIn`): no wait mends it, only `darkbloom login`.
    public static func isMissingLogin(_ reason: String) -> Bool { reason.contains("logged in to Darkbloom") }

    /// The coordinator pairs only members Apple has verified (App Attest). `retryAt`: when this Mac's local
    /// key-generation safeguard lets Darkbloom try again, said in local time; unknown, "within minutes". A restart
    /// meanwhile cut an attestation once (an end user's M4 pair, 2026-11-03), so the line asks to leave both Macs alone.
    public static func notVerified(_ mac: String, retryAt: Date? = nil, timeZone: TimeZone = .current) -> String {
        let when = retryAt.map { "at about " + clock($0, timeZone: timeZone) } ?? "within minutes"
        return "\(ClusterOnboardingMacName.sentence(mac)) isn't verified by Apple yet; Darkbloom retries by itself \(when). "
            + "Don't restart either Mac until then"
    }

    /// "00:34": hours and minutes in `timeZone`.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// A Mac's memory is the reason (`lacksMemory`, or a load-gate refusal with its figures).
    public static func isMemoryShort(_ line: String) -> Bool {
        line.contains("lacks free memory") || line.contains("enough free memory for its share")
    }

    public static func lacksMemory(_ mac: String) -> String { "\(ClusterOnboardingMacName.sentence(mac)) lacks free memory for its share" }

    /// The plain words for why a pair's start stopped, about `mac`. A rank's load-gate refusal names that Mac when
    /// `viewerRank` (the rank of the Mac whose screen the words are for) is known, and both figures. Every case is
    /// decided here: a cause without words of its own is said with its text ("The pair stopped (peer_lost)"), which
    /// is the pair's, never the coordinator's: the coordinator committed the start, and a Mac's part ended it.
    public static func words(_ cause: ClusterPairStopCause, mac: String, viewerRank: Int? = nil) -> String {
        switch cause {
        case .memoryRefused(let refusal): return words(refusal, mac: mac, viewerRank: viewerRank)
        case .guidance(let code): return words(code, mac: mac)
        case .didNotForm, .readinessLost, .firstRequestFailed, .memberStopping, .sessionEnded:
            return pairStopped(cause.logText)
        case .other(let text): return words(unnamed: text, mac: mac, viewerRank: viewerRank)
        }
    }

    private static func words(_ refusal: ClusterPairStopCause.MemoryRefusal, mac: String, viewerRank: Int?) -> String {
        let who = viewerRank.map { $0 == refusal.rank ? "this Mac" : "the other Mac" } ?? mac
        return "\(ClusterOnboardingMacName.sentence(who)) doesn't have enough free memory for its share "
            + "(needs \(refusal.shown.needs) GiB, has \(refusal.shown.has) GiB)"
    }

    private static func words(_ code: ClusterPairStopCause.Guidance, mac: String) -> String {
        switch code {
        case .memoryGateRefused: return lacksMemory(mac)
        case .deviceBusy: return deviceHeldWords + mac
        case .versionMismatch: return versionsDifferWords
        case .modelBusy: return busy(mac)
        case .orphanedWiredMemory, .localProviderRunning, .followerNotConnected, .localNetworkDenied, .loginRejected,
             .hostKeyUnknown, .hostIdentityChanged, .noMatchingHostKey, .addressUnresolved, .peerUnreachable, .bootstrapStalled,
             .linkNotReady, .rdmaCompletionError, .collectiveStall, .rankLeaseExpired, .workerRuntimeUnverified,
             .modelIdentityMismatch, .modelStageIncomplete, .planChanged, .unsupportedMode, .peerLost, .workerCrashed,
             .peerTimeout, .launchInterrupted, .configurationInvalid, .cleanupUnresolved, .listenerFailed, .requestFailed,
             .runtimeError, .unknownFailure:
            return pairStopped(code.rawValue)
        }
    }

    /// An unresolved device journal (`device_busy`): the words up to the Mac.
    static let deviceHeldWords = "An earlier session still holds the cluster device of "
    /// Two ranks whose workers speak different versions (`version_mismatch`), in the version split's words
    /// (`ClusterOnboardingVersionSplit`), which name the versions after them.
    static let versionsDifferWords = "The two Macs run different Darkbloom versions"

    private static func busy(_ mac: String) -> String { "\(ClusterOnboardingMacName.sentence(mac)) is busy with other work" }
    private static func pairStopped(_ text: String) -> String { "The pair stopped (\(text))" }

    /// The words for text no cause names, chosen as every build has chosen them, by the words the text contains: what
    /// the coordinator says when it refuses a pair (`liveness:trust_floor`, `private_text`, `serves_model`, …), or
    /// another build's text. Text it does not know is shown as it is when it is short and plain.
    private static func words(unnamed reason: String, mac: String, viewerRank: Int?) -> String {
        if let refusal = ClusterPairStopCause.MemoryRefusal(reading: reason) { return words(refusal, mac: mac, viewerRank: viewerRank) }
        let reason = reason.lowercased()
        let trust = ["trust_floor", "private_text", "app_attest", "no_trust_evidence", "runtime_unverified", "challenge_stale",
                     "attestation", "untrusted", "private_only"]
        if trust.contains(where: reason.contains) { return notVerified(mac) }
        if reason.contains("memory_gate") || reason.contains("free_memory") || reason.contains("no_headroom") { return lacksMemory(mac) }
        if reason.contains("serves_model") || reason.contains("not_serving_model") {
            return "The coordinator doesn't let \(mac) serve this model in a pair"
        }
        if reason.contains("offline") || reason.contains("heartbeat") || reason.contains("not_logged_in") {
            return "\(ClusterOnboardingMacName.sentence(mac)) isn't connected to Darkbloom"
        }
        if reason.contains("idle:") || reason.contains("busy") { return busy(mac) }
        if reason.contains("release") || reason.contains("build_hash") { return "The two Macs run different Darkbloom builds" }
        if reason.contains("clock") { return "The clock of \(mac) is off; turn on Set time automatically there" }
        return pairStopped(shown(reason))
    }

    /// `reason` when it is short and plain enough to show, else "no reason given".
    private static func shown(_ reason: String) -> String {
        reason.count <= ClusterPairStopCause.earlierBuildShownCharacters && ClusterOnboardingDeployment.shownPlainly(reason)
            ? reason : "no reason given"
    }

    /// `words` for a cause as text: the pair text of a status, from either build.
    public static func words(reason: String, mac: String, viewerRank: Int? = nil) -> String {
        words(ClusterPairStopCause(logText: reason), mac: mac, viewerRank: viewerRank)
    }

    /// `words` on a pair whose Macs report their App Attest authorization: Apple verification is named only when a Mac
    /// reports it missing (`anyUnverified`); otherwise a trust word is the coordinator's, said as such (DevNet,
    /// 2026-11-05: `private_text` on two authorized Macs read "isn't verified"). Only text no cause names can be a
    /// trust word.
    public static func words(_ cause: ClusterPairStopCause, mac: String, anyUnverified: Bool, viewerRank: Int? = nil) -> String {
        let said = words(cause, mac: mac, viewerRank: viewerRank)
        guard !anyUnverified, case .other(let reason) = cause, said.contains("isn't verified by Apple yet") else { return said }
        return "The coordinator didn't accept the pair yet (\(shown(reason))); both Macs are verified by Apple, and it retries by itself"
    }

    /// The same for a cause as text.
    public static func words(reason: String, mac: String, anyUnverified: Bool, viewerRank: Int? = nil) -> String {
        words(ClusterPairStopCause(logText: reason), mac: mac, anyUnverified: anyUnverified, viewerRank: viewerRank)
    }

    /// What a person does about a stopped pair, for the causes where something they do mends it sooner than the pair's
    /// own retries.
    public enum StopRemedy: Sendable, Equatable, CaseIterable {
        /// A Mac lacks free memory for its share: quit apps there, or change the model.
        case freeMemory
        /// An earlier session's device journal is unresolved: `darkbloom cluster recover` clears it.
        case recoverDevice
        /// The two Macs run different versions: `darkbloom update`. It never clears by itself.
        case updateBothMacs
    }

    /// What mends the stopped pair a reason's words say (`words`), nil for any other reason. A reader holds only the
    /// words: the status line the leading Mac answers the other Mac with, an outcome block. This is the one place a
    /// stopped pair's sentence is read back: for the remedy under it (`remedy(forReason:)`), for whether a start's wait
    /// ends on it and for the next step `darkbloom cluster status` names (`ClusterPairSummary`).
    public static func stopRemedy(saidBy line: String) -> StopRemedy? {
        if isMemoryShort(line) { return .freeMemory }
        if line.hasPrefix(deviceHeldWords) { return .recoverDevice }
        // The whole sentence: the version split's title begins with the same words and brings its own remedies.
        if line == versionsDifferWords { return .updateBothMacs }
        return nil
    }

    /// The remedy as the setup's outcome block says it, above its choices (Retry, Change model, Diagnostics).
    static func words(_ remedy: StopRemedy) -> String {
        switch remedy {
        case .freeMemory: return "Quit apps on that Mac, then Retry; or change the model."
        case .recoverDevice: return "Run `\(ClusterOnboardingCommand.name) cluster recover` on each Mac, then Retry."
        case .updateBothMacs: return "Run `\(ClusterOnboardingCommand.name) update` on both Macs, then Retry."
        }
    }

    /// What to do next, said under the reason (the choices follow it, and through Darkbloom the line that names
    /// `darkbloom cluster local`: `ClusterOnboardingDriver.localPairHint`).
    public static func remedy(forReason line: String) -> String? {
        if isMissingLogin(line) { return "Run `\(ClusterOnboardingCommand.name) login` on each Mac named, then Retry." }
        if line.contains("isn't verified by Apple yet") { return "Then choose Retry." }
        if let remedy = stopRemedy(saidBy: line) { return words(remedy) }
        return notPublicRemedy(forReason: line)
    }

    /// The outcome block's title when nothing serves (`reason` without its final period): the leader's after a start,
    /// and the other Mac's from the status.
    public static func title(reason: String) -> String {
        reason.hasPrefix(notPublicPrefix) ? reason + "." : "Not serving: \(reason)."
    }

    /// A pair the coordinator paired but sends no public request (`ClusterPublicServingCheck`): the reason starts with
    /// this and ends with why, in parentheses.
    public static let notPublicPrefix = "Not serving publicly: the coordinator paired both Macs but doesn't send public requests to this pair ("
    static let notPublicModelApproval = ", which serves only this account's own requests"
    static let notPublicModel = " isn't approved for public pairs"
    static let notPublicFamilies = " is approved for public pairs in "

    /// What to do about a not-public reason, nil for any other line.
    static func notPublicRemedy(forReason line: String) -> String? {
        guard line.hasPrefix(notPublicPrefix) else { return nil }
        let command = ClusterOnboardingCommand.name
        if line.contains(notPublicModelApproval) {
            return "Update both Macs (`\(command) update`) to a release that approves this model for public pairs, then run `\(command) cluster` again."
        }
        if line.contains(notPublicModel) {
            return "Choose a model approved for public pairs in `\(command) cluster`; this one serves this account's own requests."
        }
        if let start = line.range(of: notPublicFamilies)?.upperBound, let end = line.range(of: " only)", options: .backwards)?.lowerBound,
           start < end {
            var families = String(line[start..<end])
            if let and = families.range(of: " and ", options: .backwards) { families.replaceSubrange(and, with: " or ") }
            return "Choose \(families) in `\(command) cluster`."
        }
        return nil
    }

    /// The status line of a pair that does not serve yet (`OnboardingLive.localStatus`); the other Mac's window reads
    /// it back (`reason(inStatusLine:)`) to show the outcome block.
    public static func statusLine(model: String, reason: String) -> String { model + statusMarker + reason + "." }

    /// The reason a `statusLine` carries, without its final period; nil for any other line.
    public static func reason(inStatusLine line: String) -> String? {
        guard let marker = line.range(of: statusMarker) else { return nil }
        let reason = line[marker.upperBound...]
        return String(reason.hasSuffix(".") ? reason.dropLast() : reason)
    }

    static let statusMarker = " is not serving yet: "

    static func joined(_ macs: [String]) -> String {
        macs.count <= 1 ? (macs.first ?? ClusterOnboardingMacName.other) : macs.dropLast().joined(separator: ", ") + " and " + macs.last!
    }
}

/// Apple's check of each Mac of a pair the coordinator forms (App Attest), which pair membership requires. A part that
/// just started has none yet: its authorization lands about a minute after it registers, so the coordinator's first
/// trust status for it carries none (seen on a DevNet pair: every healthy 45-second start said "isn't verified by
/// Apple yet … Don't restart either Mac" for both Macs).
///
/// The warning (`ClusterOnboardingNotServing.notVerified`) is said only when it is real (`Mac.warns`); until then the
/// check is progress, said in the status line's reason place and read as loading. Only the leading Mac's look decides
/// which (`OnboardingLive.pairLook`, from both Macs' reports); every other reader reads its words (`isChecking`).
public enum ClusterOnboardingAppleCheck {
    /// How long a Mac's part may run without App Attest before its check is slow: the usual minute, twice over.
    public static let slowSeconds: Double = 120

    /// One Mac, as its cluster service reports its running part (`ClusterServiceStatus.Child`).
    public struct Mac: Sendable, Equatable {
        /// As the screens name it ("this Mac", "the other Mac (Apple M5 Max, 128 GB)").
        public var name: String
        /// `appAttest`: whether the coordinator's latest trust status for the part carries it; nil before the first.
        public var verified: Bool?
        /// `appAttestRetryAt`: when this Mac's key-generation safeguard lets it try again, while it holds it back.
        public var retryAt: Double?
        /// `startedAt`: when its part started (seconds since 1970); nil when not known.
        public var startedAt: Double?

        public init(name: String, verified: Bool?, retryAt: Double? = nil, startedAt: Double? = nil) {
            self.name = name
            self.verified = verified
            self.retryAt = retryAt
            self.startedAt = startedAt
        }

        /// The warning is real for this Mac: it reports no App Attest authorization, and its key-generation safeguard
        /// holds it back, or its part has run `slowSeconds` without one, or its part's age is unknown (an older build's
        /// status, as before). A Mac with the authorization, or with no trust status yet, never warns. The age counts
        /// from this part's start, in that Mac's clock: a part that starts again starts a new wait.
        func warns(now: Double) -> Bool {
            verified == false
                && (retryAt != nil || startedAt.map { now - $0 >= ClusterOnboardingAppleCheck.slowSeconds } ?? true)
        }
    }

    public enum Look: Sendable, Equatable {
        /// No Mac reports it missing.
        case verified
        /// Every Mac without it is new to the check: words for the status line's reason place, read as loading.
        case checking(String)
        /// A Mac's warning is real (`Mac.warns`): the warning, as the reason.
        case slow(String)
    }

    /// The pair's check now: the first Mac whose warning is real, else the Macs still checking.
    public static func look(_ macs: [Mac], now: Double, timeZone: TimeZone = .current) -> Look {
        if let slow = macs.first(where: { $0.warns(now: now) }) {
            return .slow(ClusterOnboardingNotServing.notVerified(slow.name, retryAt: slow.retryAt.map { Date(timeIntervalSince1970: $0) },
                                                                 timeZone: timeZone))
        }
        let checking = macs.filter { $0.verified == false }
        guard !checking.isEmpty else { return .verified }
        let named = checking.count > 1 && checking.count == macs.count ? "both Macs"
            : ClusterOnboardingNotServing.joined(checking.map(\.name))
        return .checking(checkingPrefix + named + checkingSuffix)
    }

    /// Whether a status line's reason is `look`'s progress words ("checking both Macs with Apple").
    public static func isChecking(_ reason: String) -> Bool { reason.hasPrefix(checkingPrefix) && reason.hasSuffix(checkingSuffix) }

    private static let checkingPrefix = "checking ", checkingSuffix = " with Apple"
}

/// The leading Mac's wait for the coordinator to pair both Macs (`OnboardingLive.pairServing`), decided look by look:
/// a reason the Macs report now ends it (a missing login at once, any other after the settle), and at the bound the ✗
/// says what the last look said. A reason seen earlier and gone since (a new key's App Attest authorization, which
/// lands a minute after registering) is never the ✗'s: with both Macs registered and nothing reported, the coordinator
/// simply didn't pair them (DevNet Gemma pair, 2026-11-05: the 15-minute ✗ blamed Apple while both Macs were authorized
/// and the coordinator refused `serves_model`).
public struct ClusterOnboardingPairWait: Sendable {
    public let started: Double
    public let bound: Double
    public let settle: Double
    /// What the latest look reported, nil when nothing.
    public private(set) var current: String?

    public init(started: Double, bound: Double = 900, settle: Double = 90) {
        self.started = started; self.bound = bound; self.settle = settle
    }

    /// One look: `reason`, what the Macs report now; `holds`, a reason only a person mends (a login, a catalog refusal),
    /// which ends the wait at once. The ✗'s reason when the wait ends now, else nil.
    public mutating func look(reason: String?, holds: Bool, now: Double) -> String? {
        current = reason
        if let reason, holds || now - started >= settle { return reason }
        if now - started >= bound { return timedOut }
        return nil
    }

    /// The ✗'s reason at the bound: what the last look still reported, else that the coordinator didn't pair them.
    public var timedOut: String { current ?? Self.notPaired(minutes: Int((bound / 60).rounded())) }

    public static func notPaired(minutes: Int = 15) -> String {
        "The coordinator didn't pair both Macs within \(minutes) minutes; both are registered with it, and it gave no reason"
    }

    /// What the pair waits for, in the status line's reason place (`OnboardingLive.pairLook`): the start the coordinator
    /// committed (both Macs load their share), else Apple's check of a new part, which comes before the coordinator can
    /// pair it, else the coordinator's pairing.
    static func words(rankZero: ClusterOnboardingPairReport.State?, apple: ClusterOnboardingAppleCheck.Look) -> String {
        if rankZero == .starting { return paired }
        if case .checking(let checking) = apple { return checking }
        return pairing
    }

    /// Whether a status line's reason is the wait's words (`words`): progress, never a reason, so it reads as loading on
    /// both Macs, which read the leading Mac's words and never work them out themselves.
    public static func isProgress(_ reason: String) -> Bool {
        reason == pairing || reason == paired || ClusterOnboardingAppleCheck.isChecking(reason)
    }

    static let pairing = "waiting for the coordinator to pair both Macs"
    static let paired = "the coordinator paired both Macs"
}

/// A stop from anywhere (`darkbloom cluster stop` in another window, or on the other Mac) while a screen waits for the
/// pair: the wait ends at once with this, on both Macs. The leading Mac counts each stop a person asks for
/// (`ClusterSetupRecord.stopsAsked`) and its status carries the count (`ClusterOnboardingLeaderStatus.stopsAsked`), so a
/// screen knows such a stop from the start's own: a status that reads "Stopped" tells nothing of who stopped.
public enum ClusterOnboardingStopped {
    public static let line = "Stopped (by `darkbloom cluster stop` on one of the Macs): the pair isn't starting any more. "
        + "Run `darkbloom cluster` on the leading Mac to start it again."
    /// What a screen that leaves the coordinator's wait says: what keeps going, and how to check.
    public static let leftPairWaitLine = "Left the wait: both Macs stay registered and the pair keeps trying to be paired by "
        + "the coordinator by itself. Check with `darkbloom status`."
    /// Under `line` on the leading Mac when the stop ended its download or copy of the model.
    public static let transferKeptLine = "What was downloaded or copied so far stays: the next start goes on from there."

    /// A stop a person asked for since the count was `before`. A count not known then or now (a status that couldn't be
    /// read, a leader on an older build, which counts none) never tells one.
    public static func asked(since before: Int?, now: Int?) -> Bool {
        guard let before, let now else { return false }
        return now > before
    }
}

/// The stop the Mac that joined ends its follow on (`ClusterOnboardingDriver.followStart`): one a person asked for since
/// the start began. The leading Mac's status reads "Stopped" until both parts start, so through a whole download or copy
/// of the model, and again while the start stops both parts to register them: none of that is a stop (an external pair
/// on 0.10.12, 2026-11-12: the joining Mac said "Stopped (by `darkbloom cluster stop` …)" 20 s into a download nobody
/// stopped). Each look before the start began takes the count as the one to compare with, so a stop then (the leading
/// Mac still at its model list, whose start goes on) is no stop of this start.
public struct ClusterOnboardingFollowedStop: Sendable {
    private var before: Int?
    /// The count the leading Mac read when its start began, as its step carries it (`ClusterOnboardingLeaderStep.stopsBefore`).
    private var startStops: Int?

    public init() {}

    /// One look at the leading Mac's status: the stops it counts (nil: not read, or a leader on an older build), whether
    /// the start had begun by then, and the count its start began with when its step says it. True when a stop asked
    /// since the start began ends it: compared with the leading Mac's own count where it says it, so both Macs count the
    /// same stops, else with this Mac's last look before the start began. A count lower than before (a record made
    /// again) is the one to compare with from then on.
    public mutating func look(_ stopsAsked: Int?, begun: Bool, startStops: Int? = nil) -> Bool {
        if let startStops { self.startStops = startStops }
        guard let stopsAsked else { return false }
        if begun, let startStops = self.startStops { return ClusterOnboardingStopped.asked(since: startStops, now: stopsAsked) }
        guard begun, let before, stopsAsked >= before else {
            self.before = stopsAsked
            return false
        }
        return stopsAsked > before
    }
}

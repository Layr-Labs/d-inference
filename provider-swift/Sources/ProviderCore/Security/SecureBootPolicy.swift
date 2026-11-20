import Foundation

/// The boot security policy macOS reports for the running system (the
/// Startup Security Utility setting), read unprivileged from
/// `system_profiler -json SPiBridgeDataType`. On a Mac with Apple silicon any
/// SIP custom configuration also moves the policy to Permissive Security.
public enum SecureBootPolicy: String, Sendable, Equatable {
    case full
    case reduced
    case permissive
    /// The report was missing, failed, timed out or held an unexpected value
    /// (`SecureBootReadFailure` says which).
    case unknown

    /// Each `system_profiler` run gets this long.
    public static let commandTimeout: TimeInterval = 20
    /// And keeps at most this much of each output stream; the report is about
    /// 600 bytes.
    public static let outputLimit = 65_536

    /// The command runner for one live read with `timeout`.
    public static func liveRunner(timeout: TimeInterval = commandTimeout) -> SecurityCommandRunner {
        .bounded(timeout: timeout, outputLimit: outputLimit)
    }

    /// The JSON report carries the unlocalized value of `ibridge_secure_boot`;
    /// anything else reads as unknown rather than as a downgrade.
    public static func parse(systemProfilerJSON data: Data) -> SecureBootPolicy {
        classify(systemProfilerJSON: data).policy
    }

    public static func current(runner: SecurityCommandRunner = liveRunner()) -> SecureBootPolicy {
        read(runner: runner).policy
    }

    /// One reading: runs `system_profiler -json SPiBridgeDataType` once and says
    /// why the policy is unknown when it is.
    public static func read(runner: SecurityCommandRunner = liveRunner()) -> SecureBootReading {
        let started = DispatchTime.now()
        func took() -> String {
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            return String(format: "after %.1f s", seconds)
        }
        let result: SecurityCommandResult
        do {
            result = try runner.run("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"])
        } catch SecurityCommandRunner.CommandError.timedOut {
            return SecureBootReading(failure: .timedOut, detail: "no answer \(took())")
        } catch SecurityCommandRunner.CommandError.outputTooLarge {
            return SecureBootReading(failure: .outputTooLarge, detail: "a stream passed \(outputLimit) bytes \(took())")
        } catch SecurityCommandRunner.CommandError.outputUnreadable {
            return SecureBootReading(failure: .outputUnreadable, detail: "a stream failed to read \(took())")
        } catch SecurityCommandRunner.CommandError.exitUnobserved {
            return SecureBootReading(failure: .exitUnobserved, detail: "its exit couldn't be seen \(took())")
        } catch {
            return SecureBootReading(failure: .launchFailed, detail: took(), privateDetail: String(describing: error))
        }
        guard result.terminationStatus == 0 else {
            return SecureBootReading(
                failure: .exitStatus,
                detail: "exit status \(result.terminationStatus) \(took()), "
                    + "\(result.stdout.utf8.count) bytes on stdout, \(result.stderr.utf8.count) on stderr",
                privateDetail: result.stderr.split(whereSeparator: \.isNewline).first.map { "stderr: \($0)" } ?? "")
        }
        let reading = classify(systemProfilerJSON: Data(result.stdout.utf8))
        guard let failure = reading.failure else { return reading }
        return SecureBootReading(failure: failure, detail: "\(reading.detail) \(took())", privateDetail: reading.privateDetail)
    }

    /// What a `system_profiler -json SPiBridgeDataType` run that exited 0
    /// printed. Each report entry is read on its own: any Permissive, then any
    /// Reduced decides; Full only when every entry says it. An entry without a
    /// value, or with one this provider doesn't recognize, leaves it unknown.
    public static func classify(systemProfilerJSON data: Data) -> SecureBootReading {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return SecureBootReading(failure: .notJSON, detail: "\(data.count) bytes",
                                     privateDetail: "starts: \(String(decoding: data.prefix(80), as: UTF8.self))")
        }
        guard let items = root["SPiBridgeDataType"] as? [Any], !items.isEmpty else {
            return SecureBootReading(failure: .noReport, detail: "\(root.count) top-level keys",
                                     privateDetail: "keys: \(keyList(root.keys))")
        }
        let labels: [String?] = items.map { ($0 as? [String: Any])?["ibridge_secure_boot"] as? String }
        let policies = labels.map { $0.flatMap(policy(label:)) }
        if policies.contains(where: { $0 == .permissive }) { return SecureBootReading(policy: .permissive) }
        if policies.contains(where: { $0 == .reduced }) { return SecureBootReading(policy: .reduced) }
        if policies.allSatisfy({ $0 == .full }) { return SecureBootReading(policy: .full) }
        if let unrecognized = labels.compactMap({ $0 }).first(where: { policy(label: $0) == nil }) {
            return SecureBootReading(failure: .unrecognizedValue, detail: "\(unrecognized.utf8.count)-byte value",
                                     privateDetail: "value: \(unrecognized)")
        }
        let keys = items.compactMap { ($0 as? [String: Any])?.keys }.flatMap { $0 }
        return SecureBootReading(failure: .noValue,
                                 detail: "\(labels.filter { $0 == nil }.count) of \(items.count) report entries without one",
                                 privateDetail: "report keys: \(keyList(keys))")
    }

    private static func policy(label: String) -> SecureBootPolicy? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Full Security": return .full
        case "Reduced Security", "Medium Security": return .reduced
        case "Permissive Security", "No Security": return .permissive
        default: return nil
        }
    }

    /// The service's reading: after a failed read it waits and reads again
    /// (`SecureBootReadRetry`), so one failed read isn't the answer. It returns
    /// the first reading with a policy, or the last failure with every attempt
    /// counted. `read` runs one `system_profiler` with the bound it is given;
    /// `onFailure` hears each failed read and the wait before the next one (nil:
    /// none follows). One clock sample decides whether to wait and when to
    /// wake. Waits go in steps of at most a second toward that wake time: a
    /// cancelled step, `shouldStop` between steps and before each read, or
    /// less than a second of the budget left ends the reading with the last
    /// failure (a read in progress keeps its own bound). No read but the first
    /// starts with less than a second of the budget left, so the reads and
    /// waits end within it. The first read always runs, with at least a
    /// second: a caller that may already have been stopped asks before calling
    /// (`collectSecurityPosture` does).
    public static func readRetrying(
        _ retry: SecureBootReadRetry = .service,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64((max(0, $0) * 1e9).rounded())) },
        shouldStop: () async -> Bool = { false },
        read: (_ timeout: TimeInterval) -> SecureBootReading,
        onFailure: (_ reading: SecureBootReading, _ nextIn: TimeInterval?) -> Void = { _, _ in }
    ) async -> SecureBootReading {
        let start = now()
        func left() -> TimeInterval { retry.budget - (now() - start) }
        var attempts = 1
        var reading = read(min(retry.readTimeout, max(left(), minimumRead))).counting(attempts)
        var wait = retry.firstWait
        while reading.failure != nil {
            let decidedAt = now()
            let next: TimeInterval? = retry.budget - (decidedAt - start) - wait >= minimumRead ? wait : nil
            onFailure(reading, next)
            guard let next else { return reading }
            let wakeAt = decidedAt + next
            while now() < wakeAt {
                guard left() >= minimumRead else { return reading }
                do { try await sleep(min(stopCheckInterval, wakeAt - now())) } catch { return reading }
                if await shouldStop() { return reading }
            }
            // Asked again even when no step was slept (the failure callback took the wait), and cancellation is
            // checked again after the answer, which may come back from another actor.
            if Task.isCancelled { return reading }
            let stop = await shouldStop()
            if stop || Task.isCancelled { return reading }
            // A wait that overslept leaves the budget's end where it was.
            let remaining = left()
            guard remaining >= minimumRead else { return reading }
            attempts += 1
            reading = read(min(retry.readTimeout, remaining)).counting(attempts)
            wait = min(wait * 2, retry.maxWait)
        }
        return reading
    }

    /// How often a wait checks for a stop, and the least time a read may get.
    static let stopCheckInterval: TimeInterval = 1
    static let minimumRead: TimeInterval = 1

    public var summary: String {
        switch self {
        case .full: return "Full Security"
        case .reduced: return "Reduced Security"
        case .permissive: return "Permissive Security"
        case .unknown: return "could not be read"
        }
    }

    /// Only an explicit downgrade blocks serving: an unreadable report is
    /// shown as unconfirmed, and Apple's App Attest key policy still requires
    /// Full Security before the coordinator authorizes this Mac.
    public var isDowngraded: Bool { self == .reduced || self == .permissive }

    /// Text from the tool, made fit for one log line: control, format and line
    /// separator characters become spaces, and it is cut to `maxBytes` of UTF-8.
    static func logText(_ text: String, maxBytes: Int = 200) -> String {
        let unsafe = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters)
        let space = Unicode.Scalar(UInt8(0x20))
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { cleaned.append(unsafe.contains(scalar) ? space : scalar) }
        let line = String(cleaned).trimmingCharacters(in: .whitespaces)
        guard line.utf8.count > maxBytes else { return line }
        var cut = String.UnicodeScalarView()
        var bytes = 0
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            guard bytes + size <= maxBytes - 3 else { break }
            cut.append(scalar)
            bytes += size
        }
        return String(cut) + "…"
    }

    private static func keyList<Keys: Sequence>(_ keys: Keys) -> String where Keys.Element == String {
        let unique = Array(Set(keys)).sorted()
        guard !unique.isEmpty else { return "none" }
        return unique.prefix(12).joined(separator: ", ") + (unique.count > 12 ? ", …" : "")
    }
}

/// Why a Secure Boot reading is unknown. Each value is a fixed label, so a
/// registration can report it (`secure_boot_read_failure`).
public enum SecureBootReadFailure: String, Sendable, Equatable, CaseIterable {
    /// `system_profiler` didn't answer within its bound.
    case timedOut = "timed_out"
    /// It could not be started.
    case launchFailed = "launch_failed"
    /// It exited with a nonzero status.
    case exitStatus = "exit_status"
    /// An output stream passed `SecureBootPolicy.outputLimit`.
    case outputTooLarge = "output_too_large"
    /// An output stream couldn't be read to its end.
    case outputUnreadable = "output_unreadable"
    /// Its exit couldn't be seen.
    case exitUnobserved = "exit_unobserved"
    /// Its output wasn't a JSON object.
    case notJSON = "not_json"
    /// The JSON held no `SPiBridgeDataType` report.
    case noReport = "no_report"
    /// The report held no `ibridge_secure_boot` value.
    case noValue = "no_value"
    /// It held a value this provider doesn't recognize.
    case unrecognizedValue = "unrecognized_value"

    /// For `doctor` and `status`.
    public var summary: String {
        switch self {
        case .timedOut: return "no answer in time"
        case .launchFailed: return "it could not be started"
        case .exitStatus: return "it exited with an error"
        case .outputTooLarge: return "its output was too large"
        case .outputUnreadable: return "its output couldn't be read"
        case .exitUnobserved: return "its exit couldn't be seen"
        case .notJSON: return "its output isn't JSON"
        case .noReport: return "no SPiBridgeDataType report"
        case .noValue: return "no `ibridge_secure_boot` value"
        case .unrecognizedValue: return "a value Darkbloom doesn't recognize"
        }
    }
}

/// A Secure Boot reading: the policy and, when it is unknown, why.
public struct SecureBootReading: Sendable, Equatable {
    public let policy: SecureBootPolicy
    /// Why `policy` is unknown; nil when it was read.
    public let failure: SecureBootReadFailure?
    /// How many reads were attempted for this reading (one whose `system_profiler` couldn't start counts too).
    public let attempts: Int
    /// The failure's particulars that hold no text from the tool (exit status,
    /// byte counts, the time it took), for the log. Never reported.
    public let detail: String
    /// Text from the tool behind the failure (stderr's first line, the start of
    /// the output, the keys the report held, an unrecognized value, a launch
    /// error), fit for one line (`SecureBootPolicy.logText`). Logged as private;
    /// never reported.
    public let privateDetail: String

    /// A policy that was read.
    public init(policy: SecureBootPolicy, attempts: Int = 1) {
        self.policy = policy
        self.failure = nil
        self.attempts = attempts
        self.detail = ""
        self.privateDetail = ""
    }

    /// A read that failed: the policy is unknown.
    public init(failure: SecureBootReadFailure, detail: String = "", privateDetail: String = "", attempts: Int = 1) {
        self.policy = .unknown
        self.failure = failure
        self.attempts = attempts
        self.detail = detail
        self.privateDetail = SecureBootPolicy.logText(privateDetail)
    }

    /// The same reading, with `attempts` runs behind it.
    func counting(_ attempts: Int) -> SecureBootReading {
        failure.map { SecureBootReading(failure: $0, detail: detail, privateDetail: privateDetail, attempts: attempts) }
            ?? SecureBootReading(policy: policy, attempts: attempts)
    }
}

/// When the service reads Secure Boot again after a failed read: it waits
/// `firstWait`, then twice as long each time up to `maxWait`, and starts no
/// read with less than a second of `budget` left, counted from the first
/// read's start. Each read gets `readTimeout`, cut to what is left of `budget`.
public struct SecureBootReadRetry: Sendable, Equatable {
    public var budget: TimeInterval
    public var firstWait: TimeInterval
    public var maxWait: TimeInterval
    public var readTimeout: TimeInterval

    public init(budget: TimeInterval, firstWait: TimeInterval, maxWait: TimeInterval, readTimeout: TimeInterval) {
        self.budget = budget
        self.firstWait = firstWait
        self.maxWait = maxWait
        self.readTimeout = readTimeout
    }

    /// A minute: reads 1, 2, 4, 8, 16 and 16 s apart, seven at most when each
    /// fails at once, three when each times out.
    public static let service = SecureBootReadRetry(
        budget: 60, firstWait: 1, maxWait: 16, readTimeout: SecureBootPolicy.commandTimeout)
}

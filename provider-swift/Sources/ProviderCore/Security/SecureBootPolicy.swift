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

    /// The JSON report carries the unlocalized value of `ibridge_secure_boot`;
    /// anything else reads as unknown rather than as a downgrade.
    public static func parse(systemProfilerJSON data: Data) -> SecureBootPolicy {
        classify(systemProfilerJSON: data).policy
    }

    public static func current(runner: SecurityCommandRunner = .bounded(timeout: commandTimeout)) -> SecureBootPolicy {
        read(runner: runner).policy
    }

    /// One reading: runs `system_profiler -json SPiBridgeDataType` once and says
    /// why the policy is unknown when it is.
    public static func read(runner: SecurityCommandRunner = .bounded(timeout: commandTimeout)) -> SecureBootReading {
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
        } catch {
            return SecureBootReading(failure: .launchFailed, detail: "\(excerpt(String(describing: error))) \(took())")
        }
        guard result.terminationStatus == 0 else {
            let stderr = result.stderr.split(whereSeparator: \.isNewline).first.map { "; stderr: \(excerpt(String($0)))" }
            return SecureBootReading(failure: .exitStatus,
                                     detail: "exit status \(result.terminationStatus) \(took())\(stderr ?? "")")
        }
        let reading = classify(systemProfilerJSON: Data(result.stdout.utf8))
        guard let failure = reading.failure else { return reading }
        return SecureBootReading(failure: failure, detail: "\(reading.detail) \(took())")
    }

    /// What a `system_profiler -json SPiBridgeDataType` run that exited 0 printed.
    public static func classify(systemProfilerJSON data: Data) -> SecureBootReading {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return SecureBootReading(failure: .notJSON,
                                     detail: "\(data.count) bytes: \(excerpt(String(decoding: data.prefix(80), as: UTF8.self)))")
        }
        guard let items = root["SPiBridgeDataType"] as? [[String: Any]], !items.isEmpty else {
            return SecureBootReading(failure: .noReport, detail: "keys: \(keyList(root.keys))")
        }
        guard let value = items.lazy.compactMap({ $0["ibridge_secure_boot"] as? String }).first else {
            return SecureBootReading(failure: .noValue, detail: "report keys: \(keyList(items.flatMap(\.keys)))")
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Full Security": return SecureBootReading(policy: .full)
        case "Reduced Security", "Medium Security": return SecureBootReading(policy: .reduced)
        case "Permissive Security", "No Security": return SecureBootReading(policy: .permissive)
        default: return SecureBootReading(failure: .unrecognizedValue, detail: "value: \(excerpt(value))")
        }
    }

    /// The service's reading: after a failed read it waits and reads again
    /// (`SecureBootReadRetry`), so one failed read isn't the answer. It returns
    /// the first reading with a policy, or the last failure with every attempt
    /// counted. `read` runs one `system_profiler` with the bound it is given;
    /// `onFailure` hears each failed read and the wait before the next one (nil:
    /// none follows). A cancelled wait ends it with the last failure.
    public static func readRetrying(
        _ retry: SecureBootReadRetry = .service,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64((max(0, $0) * 1e9).rounded())) },
        read: (_ timeout: TimeInterval) -> SecureBootReading,
        onFailure: (_ reading: SecureBootReading, _ nextIn: TimeInterval?) -> Void = { _, _ in }
    ) async -> SecureBootReading {
        let start = now()
        var attempts = 0
        var wait = retry.firstWait
        var timeout = retry.readTimeout
        while true {
            attempts += 1
            let reading = read(timeout).counting(attempts)
            guard reading.failure != nil else { return reading }
            let nextStart = now() - start + wait
            let next: TimeInterval? = nextStart < retry.budget ? wait : nil
            onFailure(reading, next)
            guard let next else { return reading }
            do { try await sleep(next) } catch { return reading }
            timeout = max(1, min(retry.readTimeout, retry.budget - (now() - start)))
            wait = min(wait * 2, retry.maxWait)
        }
    }

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

    /// One line of at most 120 characters, without control characters, for the log.
    static func excerpt(_ text: String) -> String {
        let space = Unicode.Scalar(UInt8(0x20))
        let line = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? space : $0
        })).trimmingCharacters(in: .whitespaces)
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    private static func keyList<Keys: Sequence>(_ keys: Keys) -> String where Keys.Element == String {
        let unique = Array(Set(keys.map(excerpt))).sorted()
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
    /// How many times `system_profiler` ran for this reading.
    public let attempts: Int
    /// The failure's particulars for the log (exit status, stderr's first line,
    /// the keys the report held, an unrecognized value, the time it took).
    /// Never reported.
    public let detail: String

    /// A policy that was read.
    public init(policy: SecureBootPolicy, attempts: Int = 1) {
        self.policy = policy
        self.failure = nil
        self.attempts = attempts
        self.detail = ""
    }

    /// A read that failed: the policy is unknown.
    public init(failure: SecureBootReadFailure, detail: String = "", attempts: Int = 1) {
        self.policy = .unknown
        self.failure = failure
        self.attempts = attempts
        self.detail = detail
    }

    /// The same reading, with `attempts` runs behind it.
    func counting(_ attempts: Int) -> SecureBootReading {
        failure.map { SecureBootReading(failure: $0, detail: detail, attempts: attempts) }
            ?? SecureBootReading(policy: policy, attempts: attempts)
    }
}

/// When the service reads Secure Boot again after a failed read: it waits
/// `firstWait`, then twice as long each time up to `maxWait`, and starts no
/// read that would begin `budget` or more after the first one began. Each read
/// gets `readTimeout`, shortened to what is left of `budget` (at least 1 s).
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

    /// About a minute: reads 1, 2, 4, 8, 16 and 16 s apart, seven at most
    /// when each fails at once, three when each times out.
    public static let service = SecureBootReadRetry(
        budget: 60, firstWait: 1, maxWait: 16, readTimeout: SecureBootPolicy.commandTimeout)
}

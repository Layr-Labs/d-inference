import Foundation

/// The boot security policy macOS reports for the running system (the
/// Startup Security Utility setting), read unprivileged from
/// `system_profiler -json SPiBridgeDataType`. On a Mac with Apple silicon any
/// SIP custom configuration also moves the policy to Permissive Security.
public enum SecureBootPolicy: String, Sendable, Equatable {
    case full
    case reduced
    case permissive
    /// The report was missing, failed, timed out or held an unexpected value.
    case unknown

    public static let commandTimeout: TimeInterval = 20
    public static let outputLimit = 65_536

    public static func liveRunner(timeout: TimeInterval = commandTimeout) -> SecurityCommandRunner {
        .bounded(timeout: timeout)
    }

    /// The JSON report carries the unlocalized value of `ibridge_secure_boot`;
    /// anything else reads as unknown rather than as a downgrade.
    public static func parse(systemProfilerJSON data: Data) -> SecureBootPolicy {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPiBridgeDataType"] as? [[String: Any]],
              let value = items.lazy.compactMap({ $0["ibridge_secure_boot"] as? String }).first
        else { return .unknown }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Full Security": return .full
        case "Reduced Security", "Medium Security": return .reduced
        case "Permissive Security", "No Security": return .permissive
        default: return .unknown
        }
    }

    public static func current(runner: SecurityCommandRunner = liveRunner()) -> SecureBootPolicy {
        guard let result = try? runner.run("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]),
              result.terminationStatus == 0
        else { return .unknown }
        return parse(systemProfilerJSON: Data(result.stdout.utf8))
    }

    public static func read(runner: SecurityCommandRunner = liveRunner()) -> SecureBootReading {
        SecureBootReading(policy: current(runner: runner))
    }

    public static func classify(systemProfilerJSON data: Data) -> SecureBootReading {
        SecureBootReading(policy: parse(systemProfilerJSON: data))
    }

    public static func readRetrying(
        _ retry: SecureBootReadRetry = .service,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64((max(0, $0) * 1e9).rounded())) },
        shouldStop: () async -> Bool = { false },
        read: (_ timeout: TimeInterval) -> SecureBootReading,
        onFailure: (_ reading: SecureBootReading, _ nextIn: TimeInterval?) -> Void = { _, _ in }
    ) async -> SecureBootReading {
        read(retry.readTimeout)
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

    static func logText(_ text: String, maxBytes: Int = 200) -> String {
        text
    }
}

public enum SecureBootReadFailure: String, Sendable, Equatable, CaseIterable {
    case timedOut = "timed_out"
    case launchFailed = "launch_failed"
    case exitStatus = "exit_status"
    case outputTooLarge = "output_too_large"
    case notJSON = "not_json"
    case noReport = "no_report"
    case noValue = "no_value"
    case unrecognizedValue = "unrecognized_value"

    public var summary: String {
        switch self {
        case .timedOut: return "no answer in time"
        case .launchFailed: return "it could not be started"
        case .exitStatus: return "it exited with an error"
        case .outputTooLarge: return "its output was too large"
        case .notJSON: return "its output isn't JSON"
        case .noReport: return "no SPiBridgeDataType report"
        case .noValue: return "no `ibridge_secure_boot` value"
        case .unrecognizedValue: return "a value Darkbloom doesn't recognize"
        }
    }
}

public struct SecureBootReading: Sendable, Equatable {
    public let policy: SecureBootPolicy
    public let failure: SecureBootReadFailure?
    public let attempts: Int
    public let detail: String
    public let privateDetail: String

    public init(policy: SecureBootPolicy, attempts: Int = 1) {
        self.policy = policy
        self.failure = nil
        self.attempts = attempts
        self.detail = ""
        self.privateDetail = ""
    }

    public init(failure: SecureBootReadFailure, detail: String = "", privateDetail: String = "", attempts: Int = 1) {
        self.policy = .unknown
        self.failure = failure
        self.attempts = attempts
        self.detail = detail
        self.privateDetail = privateDetail
    }

    func counting(_ attempts: Int) -> SecureBootReading {
        failure.map { SecureBootReading(failure: $0, detail: detail, privateDetail: privateDetail, attempts: attempts) }
            ?? SecureBootReading(policy: policy, attempts: attempts)
    }
}

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

    public static let service = SecureBootReadRetry(
        budget: 60, firstWait: 1, maxWait: 16, readTimeout: SecureBootPolicy.commandTimeout)
}

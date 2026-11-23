import Foundation

/// Red control only: the earlier behaviour for the new test calls. No switch,
/// and the heartbeat publishes the decode EWMA however old.
enum DecodeRateIdleAge {
    static let environmentKey = "DARKBLOOM_DECODE_RATE_IDLE_MAX_AGE_SECONDS"

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Duration? {
        nil
    }

    static func published(ewma: Double, newestSampleAge: Duration?, idle: Bool, maximum: Duration?) -> Double {
        ewma
    }
}

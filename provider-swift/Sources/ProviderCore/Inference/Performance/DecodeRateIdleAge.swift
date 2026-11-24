import Foundation

/// How long an idle slot keeps publishing its decode EWMA (`observed_decode_tps`).
///
/// The EWMA is a per-stream rate measured at whatever batch the slot ran. It
/// restarts only when a new decode sample arrives (`applyRateObservation`), and
/// an idle slot gets none, so a Mac that served several requests at once and
/// then went idle kept publishing the stacked rate. On 2026-11-23 idle M5 Macs
/// kept advertising about 16 tok/s for Gemma 4 against a fleet median near 80,
/// so routing ranked them last and sent them nothing.
///
/// Once nothing has run or waited on the slot since a decode sample older than
/// the maximum, the heartbeat publishes no decode rate (zero, omitted on the
/// wire). The coordinator then prices the Mac from its profile or the fleet,
/// as after a reload. The EWMA itself is kept, and the next sample restarts it
/// as before.
///
/// `DARKBLOOM_DECODE_RATE_IDLE_MAX_AGE_SECONDS`: unset is 1,800 s, the
/// coordinator's idle measurement age; a positive whole number of seconds sets
/// it; `0`, `false`, `no` or `off` (trimmed, case-insensitive) publishes the
/// last rate however old, as 0.10.17 did. Any other value keeps the default.
///
/// A coordinator that decays a stale rate by its age advertises
/// `decode_rate_age_decay` in `trust_status.coordinator_features`; while it
/// does, the heartbeat publishes the rate and its age instead (`effectiveMaximum`).
enum DecodeRateIdleAge {
    static let environmentKey = "DARKBLOOM_DECODE_RATE_IDLE_MAX_AGE_SECONDS"
    static let defaultMaximum: Duration = .seconds(1_800)
    static let configured = resolve()

    /// The maximum age, or nil when the switch is off.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Duration? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return defaultMaximum }
        if ["0", "false", "no", "off"].contains(raw) { return nil }
        guard let seconds = Int(raw), seconds > 0 else { return defaultMaximum }
        return .seconds(seconds)
    }

    /// The `trust_status.coordinator_features` entry of a coordinator that
    /// decays a stale published decode rate itself, by its
    /// `observed_decode_tps_age_ms`.
    static let coordinatorDecayFeature = "decode_rate_age_decay"

    /// Whether the connected coordinator advertised `coordinatorDecayFeature`
    /// in its latest `trust_status`. False until it does, and again after a
    /// disconnect or a `trust_status` without it.
    static let coordinatorDecays = CoordinatorDecayAdvertisement()

    /// Tests set this to price one heartbeat without the process-wide value.
    @TaskLocal static var coordinatorDecaysOverride: Bool?

    /// The maximum the heartbeat applies: none while the coordinator decays a
    /// stale rate itself (it then sees the rate and its age), else `configured`.
    static func effectiveMaximum(configured: Duration?, coordinatorDecays: Bool) -> Duration? {
        coordinatorDecays ? nil : configured
    }

    static var effectiveMaximum: Duration? {
        effectiveMaximum(configured: configured,
            coordinatorDecays: coordinatorDecaysOverride ?? coordinatorDecays.value)
    }

    /// The decode rate the heartbeat publishes: `ewma`, or zero when the slot
    /// is idle and its newest decode sample is older than `maximum`.
    static func published(ewma: Double, newestSampleAge: Duration?, idle: Bool, maximum: Duration?) -> Double {
        guard let maximum, idle, let newestSampleAge, newestSampleAge > maximum else { return ewma }
        return 0
    }

    /// The age the heartbeat sends with a published `rate`
    /// (`observed_decode_tps_age_ms`): whole milliseconds since `movedAt`, the
    /// newest sample that moved it (`publishedDecodeAt`). nil without a
    /// published rate or that time. It changes nothing the provider decides;
    /// the coordinator can decay a stale rate with it.
    static func publishedAgeMilliseconds(rate: Double, movedAt: ContinuousClock.Instant?,
                                         now: ContinuousClock.Instant) -> Int64? {
        guard rate > 0, let movedAt else { return nil }
        let age = max(.zero, now - movedAt)
        return age.components.seconds * 1_000 + age.components.attoseconds / 1_000_000_000_000_000
    }
}

/// The connected coordinator's `decode_rate_age_decay` advertisement
/// (`DecodeRateIdleAge.coordinatorDecays`).
final class CoordinatorDecayAdvertisement: @unchecked Sendable {
    private let lock = NSLock()
    private var advertised = false

    var value: Bool { lock.withLock { advertised } }

    /// From one `trust_status`: nil (an older coordinator) or a list without
    /// the feature keeps the provider's idle age.
    func update(features: [String]?) {
        let decays = features?.contains(DecodeRateIdleAge.coordinatorDecayFeature) ?? false
        lock.withLock { advertised = decays }
    }

    func reset() { lock.withLock { advertised = false } }
}

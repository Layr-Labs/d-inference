import Foundation

protocol PrefixCacheDonationRecording: Sendable {
    func record(_ outcome: PrefixCacheDonationOutcome)
}

/// Process-lifetime, privacy-safe donation counters. Heartbeats publish only
/// this fixed outcome vocabulary and monotonic counts; no model, request,
/// account, provider, path, hash, or cache identity is retained.
final class PrefixCacheDonationTelemetry: PrefixCacheDonationRecording, @unchecked Sendable {
    static let shared = PrefixCacheDonationTelemetry()

    private let lock = NSLock()
    private var counts: [PrefixCacheDonationOutcome: UInt64] = [:]

    func record(_ outcome: PrefixCacheDonationOutcome) {
        lock.withLock {
            let current = counts[outcome, default: 0]
            counts[outcome] = current == .max ? .max : current + 1
        }
    }

    func snapshot() -> [PrefixCacheDonationOutcomeCount] {
        lock.withLock {
            PrefixCacheDonationOutcome.allCases.compactMap { outcome in
                guard let count = counts[outcome], count > 0 else { return nil }
                return PrefixCacheDonationOutcomeCount(outcome: outcome, count: count)
            }
        }
    }
}

/// A donation crosses synchronous extraction and asynchronous write-behind
/// branches. This settlement box guarantees exactly one final outcome for the
/// opportunity regardless of which branch terminates it.
final class PrefixCacheDonationSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: any PrefixCacheDonationRecording
    private var settled = false

    init(recorder: any PrefixCacheDonationRecording) {
        self.recorder = recorder
    }

    func settle(_ outcome: PrefixCacheDonationOutcome) {
        let shouldRecord = lock.withLock {
            guard !settled else { return false }
            settled = true
            return true
        }
        if shouldRecord {
            recorder.record(outcome)
        }
    }
}

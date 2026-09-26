import Foundation

/// Rolling record of generateKey attempts, kept on the shared budget record
/// so account churn cannot hide generation storms.
enum KeyGenerationHistory {
    static let cap = 20

    static func appending(_ date: Date, to history: [Date]?) -> [Date] {
        Array(((history ?? []) + [date]).suffix(cap))
    }
}

/// Diagnostic bookkeeping on the stored key. Nothing here gates enrollment.
extension ShadowKeyRecord {
    /// Only failures inside the Apple call count: an error callback, a
    /// callback without an NSError, or the callback deadline. Local admission
    /// (`busy`), cancellation and invalid requests do not.
    static func isAppleCallFailure(_ error: any Error) -> Bool {
        if error is AppleAppAttestFailure { return true }
        if (error as? AppAttestAppleErrorSource) == .callbackWithoutNSError { return true }
        return (error as? ShadowFailure) == .operationTimeout
    }

    mutating func recordAppleSuccess(at date: Date) {
        lastSuccessAt = date
        consecutiveAssertionFailures = 0
    }

    mutating func recordAssertionFailures(_ count: Int) {
        guard count > 0 else { return }
        let current = consecutiveAssertionFailures ?? 0
        consecutiveAssertionFailures = min(AppAttestKeyHistory.maxConsecutiveFailures, current + count)
    }
}

extension AppAttestKeyHistory {
    static let generationWindow: TimeInterval = 86_400
    /// `kern.boottime` can shift by a few seconds when the wall clock is stepped.
    static let bootTimeTolerance: Int64 = 60

    /// Pure summary for the account scope's key and the shared budget record.
    /// Key-level members are omitted without a usable key identifier or when
    /// the record predates these fields; ages are omitted when negative.
    static func build(record: ShadowKeyRecord?, budget: ShadowKeyRecord?, now: Date, bootTime: Int64?) -> AppAttestKeyHistory? {
        var history = AppAttestKeyHistory()
        if let budget {
            if let attempts = budget.generationHistory {
                history.generationsLast24h = min(maxGenerations, attempts.filter {
                    $0 <= now && now.timeIntervalSince($0) < generationWindow
                }.count)
                history.lastGenerationAgeSeconds = attempts.max().flatMap { age(from: $0, to: now) }
            }
        } else {
            // The budget record is written before every generateKey call, so
            // its absence means this install never generated a key here.
            history.generationsLast24h = 0
        }
        if let record, !record.keyID.isEmpty {
            history.keyAgeSeconds = age(from: record.createdAt, to: now)
            history.lastSuccessAgeSeconds = record.lastSuccessAt.flatMap { age(from: $0, to: now) }
            history.consecutiveAssertionFailures = record.consecutiveAssertionFailures
                .map { max(0, min(maxConsecutiveFailures, $0)) }
            if let created = record.createdBootTime, let bootTime {
                history.createdBootMatches = abs(created - bootTime) <= bootTimeTolerance
            }
            history.createdAppVersion = record.createdAppVersion.flatMap { value in
                let bounded = String(value.prefix(maxVersionLength))
                return bounded.isEmpty ? nil : bounded
            }
        }
        return history.isEmpty ? nil : history
    }

    private static func age(from date: Date, to now: Date) -> Int? {
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int32.max) else { return nil }
        return Int(seconds)
    }
}

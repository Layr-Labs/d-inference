import Foundation

/// Prepare while serving, fence new admissions, then let accepted work reach
/// idle before publication. A timeout restores admission without cancelling
/// existing requests. Publication and drain cleanup are caller-owned.
enum MTPIdleUpgrade {
    enum PreparationError: Error { case insufficientMemory }

    enum Outcome: Equatable { case notReady, installed, deferred, cancelled, failed }

    static func run<Candidate: Sendable>(
        maximumIdleChecks: Int = 120,
        prepare: @Sendable () async throws -> Candidate?,
        waitBeforeDrain: @Sendable () async throws -> Void = {},
        beginDrain: @Sendable (Candidate) async throws -> Void,
        commitIfIdle: @Sendable (Candidate) async throws -> Bool,
        discard: @Sendable (Candidate) async -> Void,
        finishDrain: @Sendable (Candidate) async -> Void,
        pause: @Sendable () async throws -> Void = { try await taskSleep(.milliseconds(500)) }
    ) async -> Outcome {
        let candidate: Candidate
        do {
            try Task.checkCancellation()
            guard let prepared = try await prepare() else { return .notReady }
            candidate = prepared
        } catch is CancellationError { return .cancelled }
        catch { return .failed }
        var outcome = Outcome.deferred
        do {
            try await waitBeforeDrain()
            try Task.checkCancellation()
            try await beginDrain(candidate)
            for _ in 0..<max(0, maximumIdleChecks) {
                try Task.checkCancellation()
                if try await commitIfIdle(candidate) {
                    // Publication owns the replacement now. Cancellation must
                    // never discard it or leave admission fenced afterward.
                    await finishDrain(candidate)
                    return .installed
                }
                try await pause()
            }
        } catch is CancellationError { outcome = .cancelled }
        catch { outcome = .failed }
        await discard(candidate)
        // beginDrain may throw after fencing; owner-checked cleanup is needed
        // even when the first drain call did not return successfully.
        await finishDrain(candidate)
        return outcome
    }
}

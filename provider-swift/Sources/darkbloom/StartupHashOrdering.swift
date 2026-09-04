/// Startup ordering contract for `darkbloom start` (T4-02): the auto-update
/// check runs BEFORE the startup weight-hash pass.
///
/// The hash pass is a full SHA-256 read of every advertised model (tens of
/// seconds on a catalog box). On `.updated` / `.restartRequired` the updater
/// execs the new binary, which repeats the pass — so hashing first paid it
/// twice on every release-day restart and once more on every subsequent
/// boot. Nothing between the two steps consumes the hashes; the only thing
/// that must stay ahead of the update is `confirmRunningCandidateLaunch`,
/// which the caller keeps where it was.
///
/// Pure over two closures so the order is unit-testable without a
/// coordinator, an updater, or a model cache.
enum StartupHashOrdering {
    static func run<Hashes>(
        checkForUpdate: () async throws -> Void,
        hashModels: () -> Hashes
    ) async rethrows -> Hashes {
        try await checkForUpdate()
        return hashModels()
    }
}

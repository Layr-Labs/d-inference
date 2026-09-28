import ProviderCore
import Testing

@testable import darkbloom

@Test("a termination signal releases local startup without waiting for a wedged load")
func localStartupInterruptWakesWaiter() async {
    let barrier = LocalStartupPreloadBarrier()
    let waiter = Task { await barrier.wait() }

    barrier.interrupt()

    #expect(await waiter.value == .interrupted)
}

@Test("a completed local preload returns its load summary")
func localStartupCompletionReturnsSummary() async {
    let barrier = LocalStartupPreloadBarrier()
    var summary = StartupPreloader.Summary()
    summary.loaded = ["model-a"]
    barrier.complete(summary)

    #expect(await barrier.wait() == .completed(summary))
}

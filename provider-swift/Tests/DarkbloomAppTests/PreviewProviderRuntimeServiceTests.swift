import Testing
@testable import DarkbloomApp

@Test("Starting publishes a transitional state before the provider is online")
func previewStartTransitionIsOrdered() async throws {
    let service = PreviewProviderRuntimeService(
        scenario: .paused,
        transitionDelay: .zero
    )
    let stream = await service.updates()
    var iterator = stream.makeAsyncIterator()

    let initial = await iterator.next()
    #expect(initial?.runState == .paused)

    let completed = try await service.perform(.start)
    let transitioning = await iterator.next()
    let publishedCompletion = await iterator.next()

    #expect(transitioning?.runState == .starting)
    #expect(publishedCompletion?.runState == .online)
    #expect(completed == publishedCompletion)
    #expect(completed.activity.requestsServed == 0)
    #expect(completed.startedAt == completed.sourceUpdatedAt)
}

@Test("Stopping and restarting mirror the provider lifecycle")
func previewStopAndRestartTransitions() async throws {
    let service = PreviewProviderRuntimeService(
        scenario: .serving,
        transitionDelay: .zero
    )

    let stopped = try await service.perform(.stop)
    #expect(stopped.runState == .paused)
    #expect(stopped.pid == nil)
    #expect(stopped.capacity == nil)
    #expect(stopped.warmModels.isEmpty)

    let restarted = try await service.perform(.restart)
    #expect(restarted.runState == .online)
    #expect(restarted.pid != nil)
    #expect(restarted.startedAt != nil)
    #expect(restarted.activity.requestsServed == 0)
    #expect(restarted.warmModels.count == 1)
}

@Test("A scheduled-off provider cannot invent a temporary override")
func previewScheduledStartIsUnavailable() async throws {
    let service = PreviewProviderRuntimeService(
        scenario: .scheduledOff,
        transitionDelay: .zero
    )

    await #expect(throws: ProviderRuntimeServiceError.self) {
        try await service.perform(.start)
    }

    let unchanged = await service.currentSnapshot()
    #expect(unchanged.runState == .scheduledOff)
    #expect(unchanged.availability.state == .scheduledOff)
    #expect(unchanged.localEndpoint == nil)
}

@Test("Restarting outside a window preserves the schedule gate")
func previewScheduledRestartRemainsOff() async throws {
    let service = PreviewProviderRuntimeService(
        scenario: .scheduledOff,
        transitionDelay: .zero
    )

    let restarted = try await service.perform(.restart)

    #expect(restarted.runState == .scheduledOff)
    #expect(restarted.availability.state == .scheduledOff)
    #expect(restarted.availability.nextChangeAt != nil)
    #expect(restarted.localEndpoint == nil)
}

@Test("A manual pause keeps the saved schedule for the next resume")
func previewScheduledPauseResumeRetainsPolicy() async throws {
    let service = PreviewProviderRuntimeService(
        scenario: .pausedScheduled,
        transitionDelay: .zero
    )

    let resumed = try await service.perform(.start)
    #expect(resumed.runState == .online)
    #expect(resumed.availability.state == .scheduledActive)
    #expect(resumed.availability.nextChangeAt != nil)

    let paused = try await service.perform(.stop)
    #expect(paused.runState == .paused)

    let resumedAgain = try await service.perform(.start)
    #expect(resumedAgain.availability.state == .scheduledActive)
}

@Test("Read-only actions never manufacture a healthy state from a stale source")
func previewRefreshPreservesStaleness() async throws {
    let service = PreviewProviderRuntimeService(
        scenario: .stale,
        transitionDelay: .zero
    )
    let before = await service.currentSnapshot()
    let after = try await service.perform(.runDiagnostics)

    #expect(after.runState == .stale)
    #expect(after.sourceUpdatedAt == before.sourceUpdatedAt)
    #expect(after.sampledAt > before.sampledAt)
    #expect(after.isStale)
}

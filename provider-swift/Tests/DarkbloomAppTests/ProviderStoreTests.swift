import Foundation
import Testing
@testable import DarkbloomApp

@Test("Provider store exposes one primary action and follows preview transitions")
@MainActor
func providerStorePerformsPrimaryActions() async {
    let service = PreviewProviderRuntimeService(
        scenario: .paused,
        transitionDelay: .zero
    )
    let store = ProviderStore(
        service: service,
        initialSnapshot: ProviderPreviewScenario.paused.snapshot
    )

    #expect(store.primaryAction == .start)
    #expect(store.canPerform(.start))

    await store.perform(.start)

    #expect(store.snapshot.runState == .online)
    #expect(store.primaryAction == .stop)
    #expect(store.loadState == .loaded)
    #expect(store.pendingAction == nil)
    #expect(store.failure == nil)

    await store.perform(.stop)

    #expect(store.snapshot.runState == .paused)
    #expect(store.primaryAction == .start)
}

@Test("A schedule boundary cannot be overridden with the generic start action")
@MainActor
func providerStoreKeepsScheduledOffUnderScheduleControl() {
    let store = ProviderStore(previewScenario: .scheduledOff)

    #expect(store.snapshot.runState == .scheduledOff)
    #expect(store.primaryAction == .refresh)
    #expect(!store.canPerform(.start))
    #expect(store.canPerform(.refresh))
}

@Test("Provider store preserves its last snapshot when an action fails")
@MainActor
func providerStoreSurfacesFailuresWithoutDiscardingState() async {
    let initial = ProviderPreviewScenario.online.snapshot
    let store = ProviderStore(
        service: FailingProviderRuntimeService(snapshot: initial),
        initialSnapshot: initial
    )

    await store.refresh()

    #expect(store.snapshot == initial)
    #expect(store.loadState == .failed)
    #expect(store.failure?.action == .refresh)
    #expect(store.failure?.message == "Preview runtime is unavailable.")
    #expect(store.retryableFailureAction == .refresh)

    store.dismissFailure()
    #expect(store.failure == nil)
    #expect(store.loadState == .loaded)
}

@Test("Provider store retries the preserved failed action")
@MainActor
func providerStoreRetriesFailure() async {
    let initial = ProviderPreviewScenario.online.snapshot
    let service = FlakyProviderRuntimeService(snapshot: initial)
    let store = ProviderStore(service: service, initialSnapshot: initial)

    await store.refresh()

    #expect(store.failure?.action == .refresh)
    #expect(store.snapshot == initial)

    await store.retryFailure()

    let attemptCount = await service.attemptCount
    #expect(store.failure == nil)
    #expect(store.loadState == .loaded)
    #expect(attemptCount == 2)
}

private actor FailingProviderRuntimeService: ProviderRuntimeServicing {
    let snapshot: ProviderSnapshot

    init(snapshot: ProviderSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> ProviderSnapshot {
        snapshot
    }

    func updates() -> AsyncStream<ProviderSnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func perform(_: ProviderAction) throws -> ProviderSnapshot {
        throw ProviderRuntimeServiceError.unavailable("Preview runtime is unavailable.")
    }
}

private actor FlakyProviderRuntimeService: ProviderRuntimeServicing {
    let snapshot: ProviderSnapshot
    private(set) var attemptCount = 0

    init(snapshot: ProviderSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> ProviderSnapshot {
        snapshot
    }

    func updates() -> AsyncStream<ProviderSnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func perform(_: ProviderAction) throws -> ProviderSnapshot {
        attemptCount += 1
        if attemptCount == 1 {
            throw ProviderRuntimeServiceError.unavailable("Preview runtime is unavailable.")
        }
        return snapshot
    }
}

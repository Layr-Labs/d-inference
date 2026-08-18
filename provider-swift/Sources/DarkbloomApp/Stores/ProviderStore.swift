import Foundation
import Observation

enum ProviderStoreLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

struct ProviderStoreFailure: Equatable, Sendable {
    let action: ProviderAction?
    let message: String
}

@MainActor
@Observable
final class ProviderStore {
    private(set) var snapshot: ProviderSnapshot
    private(set) var loadState: ProviderStoreLoadState = .idle
    private(set) var pendingAction: ProviderAction?
    private(set) var failure: ProviderStoreFailure?

    @ObservationIgnored
    private let service: any ProviderRuntimeServicing

    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?

    init(
        service: any ProviderRuntimeServicing,
        initialSnapshot: ProviderSnapshot
    ) {
        self.service = service
        snapshot = initialSnapshot
    }

    convenience init(previewScenario: ProviderPreviewScenario = .online) {
        let service = PreviewProviderRuntimeService(scenario: previewScenario)
        self.init(service: service, initialSnapshot: previewScenario.snapshot)
    }

    /// Live store: tracks the real provider daemon via its state file and
    /// drives lifecycle through the `darkbloom` CLI.
    convenience init(daemon service: DaemonRuntimeService) {
        self.init(service: service, initialSnapshot: service.initialSnapshot)
    }

    deinit {
        monitoringTask?.cancel()
    }

    var primaryAction: ProviderAction {
        switch snapshot.runState {
        case .paused:
            .start
        case .scheduledOff:
            .refresh
        case .stale:
            .restart
        case .online, .serving, .attention, .starting, .stopping, .restarting:
            .stop
        }
    }

    var retryableFailureAction: ProviderAction? {
        guard let action = failure?.action, canPerform(action) else { return nil }
        return action
    }

    func canPerform(_ action: ProviderAction) -> Bool {
        guard pendingAction == nil else { return false }

        switch action {
        case .start:
            return snapshot.runState == .paused
        case .stop:
            return snapshot.runState == .online
                || snapshot.runState == .serving
                || snapshot.runState == .attention
                || snapshot.runState == .stale
        case .restart:
            return !snapshot.runState.isTransitioning
        case .refresh, .runDiagnostics:
            return true
        }
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        let service = service

        monitoringTask = Task { [weak self] in
            let updates = await service.updates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.accept(update)
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func refresh() async {
        await perform(.refresh)
    }

    func perform(_ action: ProviderAction) async {
        guard canPerform(action) else { return }

        pendingAction = action
        loadState = .loading
        defer { pendingAction = nil }

        do {
            let updated = try await service.perform(action)
            snapshot = updated
            loadState = .loaded
            failure = nil
        } catch is CancellationError {
            loadState = .idle
        } catch {
            loadState = .failed
            failure = ProviderStoreFailure(
                action: action,
                message: error.localizedDescription
            )
        }
    }

    func dismissFailure() {
        failure = nil
        if loadState == .failed {
            loadState = .loaded
        }
    }

    func retryFailure() async {
        guard let action = retryableFailureAction else { return }
        dismissFailure()
        await perform(action)
    }

    private func accept(_ update: ProviderSnapshot) {
        snapshot = update
        loadState = .loaded
    }
}

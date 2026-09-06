import Foundation
import Observation
import ProviderCoreFoundation

/// Owns only a foreground process requested from Local API. The endpoint store
/// owns discovery/probes; a CLI exit is never used as evidence of readiness.
@MainActor
@Observable
final class LocalAPIStartController {
    private(set) var state: LocalAPIStartState = .idle
    private(set) var hasActiveSession = false
    private(set) var ownedProcessIdentity: ProcessIdentity?

    private let cli: (any LocalAPIProviderRunning)?
    private let configuration: LocalAPIStartConfiguration
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var waitID: UUID?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var processLifetime: LocalAPIProcessLifetime?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var stopDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var observation: (@MainActor () async -> Bool)?
    @ObservationIgnored private var invalidateProbe: (@MainActor () -> Void)?
    @ObservationIgnored private var didChangeProcess: (@MainActor () -> Void)?
    private var modelID: String?

    init(cli: (any LocalAPIProviderRunning)?, configuration: LocalAPIStartConfiguration) {
        self.cli = cli
        self.configuration = configuration
    }

    deinit {
        commandTask?.cancel()
        readinessTask?.cancel()
        deadlineTask?.cancel()
        stopDeadlineTask?.cancel()
    }

    var isLaunchSupported: Bool { cli != nil && configuration.nonReplacingLaunchVerified }

    func cancelBeforeStart() {
        guard !hasActiveSession else { return }
        state = .cancelled
    }

    func reject(_ error: LocalAPIStartError) {
        guard !hasActiveSession else { return }
        state = .failed(error)
    }

    func start(
        modelID: String,
        preflight: @escaping @MainActor () throws -> Void,
        observe: @escaping @MainActor () async -> Bool,
        invalidateProbe: @escaping @MainActor () -> Void,
        didChangeProcess: @escaping @MainActor () -> Void
    ) {
        guard !hasActiveSession else { return }
        guard !Task.isCancelled else {
            state = .cancelled
            return
        }
        guard let cli else {
            reject(.fixtureMode)
            return
        }
        guard isLaunchSupported else {
            reject(.nonReplacingLaunchUnavailable)
            return
        }
        let id = UUID()
        sessionID = id
        self.modelID = modelID
        observation = observe
        self.invalidateProbe = invalidateProbe
        self.didChangeProcess = didChangeProcess
        hasActiveSession = true
        state = .starting(modelID: modelID)
        commandTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try preflight()
                guard self?.sessionID == id else { return }
                self?.beginWaiting(session: id, modelID: modelID)
                let result = try await cli.run(
                    arguments: LocalAPIStartCommand.arguments(modelID: modelID),
                    onLaunch: { [weak self] identity in
                        Task { @MainActor [weak self] in
                            guard self?.sessionID == id else { return }
                            self?.ownedProcessIdentity = identity
                        }
                    }
                )
                try Task.checkCancellation()
                let error: LocalAPIStartError = result.exitStatus == 0
                    ? .processExited
                    : .cli(.exited(result.exitStatus, message: result.failureMessage))
                self?.finish(session: id, error: error)
            } catch is CancellationError {
                self?.finish(session: id, error: nil)
            } catch let error as LocalAPIStartError {
                self?.finish(session: id, error: error)
            } catch let error as ProviderCLIError {
                self?.finish(session: id, error: .cli(error))
            } catch {
                self?.finish(session: id, error: .launchFailed(error.localizedDescription))
            }
        }
        if let commandTask { processLifetime = LocalAPIProcessLifetime(task: commandTask) }
    }

    /// Cancels only the child this controller launched. Keep the ownership token
    /// until the runner returns: a delayed cancellation must not admit a second
    /// launch while the first process is still being reaped.
    func cancel() {
        guard hasActiveSession, state != .cancelling else { return }
        state = .cancelling
        endWaiting()
        commandTask?.cancel()
        let session = sessionID
        let timeout = configuration.shutdownTimeout
        stopDeadlineTask?.cancel()
        stopDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self?.sessionID == session, self?.hasActiveSession == true,
                  self?.state == .cancelling else { return }
            self?.state = .failed(.shutdownTimedOut)
        }
    }

    /// Parent AppDelegate must await this from applicationShouldTerminate and
    /// reply to .terminateLater. A closed window does not call this hook.
    func shutdown() async -> Bool {
        guard hasActiveSession else { return true }
        cancel()
        let deadline = ContinuousClock.now.advanced(by: configuration.shutdownTimeout)
        while hasActiveSession && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        if hasActiveSession {
            state = .failed(.shutdownTimedOut)
            return false
        }
        return true
    }

    func checkAgain() {
        guard hasActiveSession, state != .cancelling,
              let sessionID, let modelID else { return }
        beginWaiting(session: sessionID, modelID: modelID)
    }

    /// Discovery changed or the endpoint stopped answering after a successful
    /// start. Never leave a cached green start banner above a failed endpoint.
    func endpointBecameUnready() {
        guard case .ready = state else { return }
        checkAgain()
    }

    func endpointDidUpdate(health: LocalAPIHealth, modelCatalog: LocalAPIModelCatalog) {
        guard case .ready(let modelID) = state else { return }
        if health == .reachable, case .available(let modelIDs) = modelCatalog,
           modelIDs.contains(modelID) { return }
        checkAgain()
    }

    private func beginWaiting(session: UUID, modelID: String) {
        endWaiting()
        guard let observation else { return }
        let wait = UUID()
        waitID = wait
        state = .waitingForEndpoint(modelID: modelID)
        let interval = configuration.pollInterval
        readinessTask = Task { [weak self] in
            while !Task.isCancelled {
                let ready = await observation()
                guard !Task.isCancelled,
                      self?.sessionID == session, self?.waitID == wait else { return }
                if ready {
                    self?.state = .ready(modelID: modelID)
                    self?.endWaiting()
                    self?.didChangeProcess?()
                    return
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
        let timeout = configuration.readinessTimeout
        let waitForTimeout = configuration.waitForReadinessTimeout
        deadlineTask = Task { [weak self] in
            do { try await waitForTimeout(timeout) } catch { return }
            guard !Task.isCancelled,
                  self?.sessionID == session, self?.waitID == wait else { return }
            self?.state = .failed(.readinessTimedOut(modelID: modelID))
            self?.endWaiting()
        }
    }

    private func endWaiting() {
        waitID = nil
        readinessTask?.cancel()
        readinessTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        invalidateProbe?()
    }

    private func finish(session: UUID, error: LocalAPIStartError?) {
        guard sessionID == session else { return }
        let cancelled = state == .cancelling || Task.isCancelled
        endWaiting()
        sessionID = nil
        stopDeadlineTask?.cancel()
        stopDeadlineTask = nil
        commandTask = nil
        hasActiveSession = false
        ownedProcessIdentity = nil
        if cancelled {
            state = .cancelled
        } else if let error {
            state = .failed(error)
        } else {
            state = .cancelled
        }
        processLifetime = nil
        observation = nil
        invalidateProbe = nil
        let callback = didChangeProcess
        didChangeProcess = nil
        callback?()
    }
}

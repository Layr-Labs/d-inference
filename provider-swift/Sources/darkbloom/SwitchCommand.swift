import ArgumentParser
import Foundation
import ProviderCore

struct Switch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Change the running provider's hosted models without restarting.",
        discussion: "Validates the full selection, gracefully drains accepted requests, and replaces the model inventory on the existing coordinator session. With no selection flags, opens the start model picker. A timeout never interrupts requests; the provider remains draining. Standalone --local servers do not support this command."
    )

    @Option(help: "Local model ID to host (repeatable; skips the picker).")
    var model: [String] = []

    @Flag(help: "Host all eligible local models (skips the picker).")
    var all = false

    @Option(help: "Graceful drain deadline in seconds (0...3600). Zero does not wait for unfinished work; an idle provider still allows up to 30 seconds for the coordinator barrier. No requests are cancelled on timeout.")
    var timeout: Int = 600

    mutating func validate() throws {
        guard !all || model.isEmpty else { throw ValidationError("--all and --model are mutually exclusive") }
        guard (0...3600).contains(timeout) else { throw ValidationError("--timeout must be between 0 and 3600 seconds") }
    }

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        // Identity and daemon capability checks precede catalog fetch/downloads.
        let state = try Self.requireLiveState(DaemonStateFile.read())
        guard let identity = state.processIdentity, let configPath = state.configPath,
              let reportedCapabilities = state.runtimeCapabilities, let coordinatorURL = state.coordinatorUrl else {
            throw ValidationError("The running provider lacks live-switch metadata. Upgrade it before switching.")
        }
        let capabilities = Set(reportedCapabilities.map { ProviderRuntimeCapability(rawValue: $0) })
        let snapshot = try loadRuntimeSnapshot(configPath: configPath, migrateOnDisk: false)
        guard let hardware = snapshot.hardware else {
            throw ValidationError("Cannot scan local models: hardware detection failed.")
        }
        let selected: [String]
        if !model.isEmpty {
            selected = try Self.selectModels(requested: model, local: ModelScanner.scanAllModels(hardwareInfo: hardware), capabilities: capabilities)
        } else if all {
            selected = try Self.selectModels(requested: [], local: ModelScanner.scanAllModels(hardwareInfo: hardware), capabilities: capabilities)
        } else {
            selected = try await Start().interactiveCatalogPicker(
                snapshot: snapshot, config: snapshot.config, coordinatorURL: coordinatorURL,
                runtimeCapabilities: capabilities)
        }
        guard !selected.isEmpty else { throw ValidationError("No models selected; the running provider was not changed.") }

        let updater = SelfUpdater(coordinatorBaseURL: coordinatorURL)
        let session = try updater.beginUpdateSession(operation: "provider-model-switch", timeout: 0)
        defer { session.release() }
        let latest = try Self.requireLiveState(DaemonStateFile.read())
        guard latest.processIdentity == identity, latest.configPath == configPath else {
            throw ValidationError("The running provider changed during selection. No switch request was sent; retry.")
        }
        let request = ProviderModelSwitchRequest(target: identity, models: selected, timeoutSeconds: timeout)
        guard try JSONEncoder().encode(request).count <= 8192 else {
            throw ValidationError("The model selection exceeds the local control message limit.")
        }
        let mailbox = LifecycleMailbox(identity: identity)
        try mailbox.writeSwitchRequest(request)
        print("Switch requested: waiting for validation, graceful drain and same-session inventory confirmation.")
        let status = try await Self.wait(request: request, mailbox: mailbox)
        print("Hosted models switched (provider process and coordinator session unchanged):")
        for id in status.models { print("  \(id)") }
    }

    static func requireLiveState(
        _ state: DaemonState?, now: Double = Date().timeIntervalSince1970,
        isCurrent: (ProcessIdentity) -> Bool = { $0.isCurrent() }
    ) throws -> DaemonState {
        guard let state, let identity = state.processIdentity, identity.pid == state.pid,
              isCurrent(identity), state.writtenAt.isFinite, state.writtenAt <= now + 5,
              !state.isStale(now: now) else {
            throw ValidationError("No fresh live provider identity is available. Nothing was started, stopped or changed.")
        }
        guard let status = state.modelSwitch, state.runtimeCapabilities != nil,
              let path = state.configPath, !path.isEmpty, state.coordinatorUrl != nil else {
            throw ValidationError("This provider does not support live model switching. Upgrade the provider; standalone --local servers are not supported.")
        }
        guard ![.validating, .draining, .switching].contains(status.outcome) else {
            throw ValidationError("A provider model switch is already in progress; wait for its receipt before retrying.")
        }
        return state
    }

    static func selectModels(requested: [String], local: [ModelInfo], capabilities: Set<ProviderRuntimeCapability>) throws -> [String] {
        let supported = EngineV2SupportedModels.partition(local).supported
        let eligible = supported.filter { ModelRuntimeRequirements.isEligible(modelID: $0.id, available: capabilities) }
        let known = Set(eligible.map(\.id))
        if requested.isEmpty { return eligible.map(\.id).sorted() }
        let invalid = requested.filter { !known.contains($0) }
        guard invalid.isEmpty else {
            throw ValidationError("Selection rejected; missing or unsupported local model(s): \(invalid.joined(separator: ", ")). No models were changed.")
        }
        var seen = Set<String>()
        return requested.filter { seen.insert($0).inserted }
    }

    /// Only a matching terminal receipt proves success, never publication or a
    /// daemon snapshot left over from an earlier switch.
    static func terminalReceipt(_ status: ProviderModelSwitchStatus?, request: ProviderModelSwitchRequest) throws -> ProviderModelSwitchStatus? {
        guard let status, status.requestID == request.id else { return nil }
        switch status.outcome {
        case .switched:
            guard Set(status.models) == Set(request.models) else {
                throw ValidationError("The provider's switch receipt does not match the requested model set; success is unconfirmed.")
            }
            return status
        case .timedOut, .failed, .busy:
            throw ValidationError(status.message ?? "Switch \(status.outcome.rawValue); \(status.remaining) request(s) unfinished. No requests were forcibly cancelled.")
        case .serving, .validating, .draining, .switching:
            return nil
        }
    }

    static func wait(request: ProviderModelSwitchRequest, mailbox: LifecycleMailbox) async throws -> ProviderModelSwitchStatus {
        var phase: ProviderModelSwitchStatus.Outcome?
        var deadline: ContinuousClock.Instant? = .now.advanced(by: .seconds(10))
        while true {
            guard request.target.isCurrent() else {
                throw ValidationError("The target provider exited. Switch success is unconfirmed; no replacement was launched.")
            }
            let status = mailbox.readSwitchStatus()
            if let result = try terminalReceipt(status, request: request) { return result }
            if let status, status.requestID == request.id, status.outcome != phase {
                phase = status.outcome
                switch status.outcome {
                case .validating:
                    deadline = nil // Hashing precedes the daemon's drain deadline.
                case .draining:
                    deadline = .now.advanced(by: .seconds((request.timeoutSeconds == 0 ? 30 : request.timeoutSeconds) + 10))
                case .switching:
                    deadline = .now.advanced(by: .seconds(120))
                default:
                    break
                }
            }
            if phase != nil {
                let now = Date().timeIntervalSince1970
                guard let state = DaemonStateFile.read(), state.processIdentity == request.target,
                      state.writtenAt.isFinite, state.writtenAt <= now + 5, !state.isStale(now: now) else {
                    throw ValidationError("The provider's live state became unavailable. Switch success is unconfirmed; the operation may continue. No process was stopped.")
                }
            }
            if let deadline, ContinuousClock.now >= deadline {
                throw ValidationError("No matching switch completion receipt arrived. Success is unconfirmed; the operation may continue and accepted work was not interrupted. Check provider status before retrying.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

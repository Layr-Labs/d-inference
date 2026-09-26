import ArgumentParser
import Foundation
import Testing
@testable import darkbloom
@testable import ProviderCore

@Suite("Live model switching CLI")
struct SwitchCommandTests {
    @Test func parserRejectsAmbiguousOrDestructiveOptions() throws {
        let command = try #require(try Darkbloom.parseAsRoot(["switch", "--model", "a", "--model", "b", "--timeout", "0"]) as? Switch)
        #expect(command.model == ["a", "b"] && command.timeout == 0)
        #expect(try Switch.parse(["--all", "--timeout", "3600"]).all)
        for arguments in [["--all", "--model", "a"], ["--timeout", "-1"], ["--timeout", "3601"], ["--force"]] {
            #expect(throws: (any Error).self) { _ = try Switch.parse(arguments) }
        }
    }

    @Test func staleMissingAndOlderDaemonsFailClosed() throws {
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 10)
        var state = DaemonState(pid: 42, processIdentity: identity, version: "test", writtenAt: 1000, startedAt: 900,
            coordinatorURL: "wss://fixture.invalid", modelSwitch: .init(), configPath: "/fixture.toml", runtimeCapabilities: [])
        #expect(throws: (any Error).self) { _ = try Switch.requireLiveState(nil, now: 1000) }
        #expect(throws: (any Error).self) { _ = try Switch.requireLiveState(state, now: 1000, isCurrent: { _ in false }) }
        #expect(throws: (any Error).self) { _ = try Switch.requireLiveState(state, now: 1091, isCurrent: { _ in true }) }
        #expect(try Switch.requireLiveState(state, now: 1000, isCurrent: { $0 == identity }).processIdentity == identity)
        state.runtimeCapabilities = nil
        #expect(throws: (any Error).self) { _ = try Switch.requireLiveState(state, now: 1000, isCurrent: { _ in true }) }
        state.runtimeCapabilities = []
        state.modelSwitch = nil
        #expect(throws: (any Error).self) { _ = try Switch.requireLiveState(state, now: 1000, isCurrent: { _ in true }) }
        state.modelSwitch = .init(outcome: .switching)
        #expect(throws: (any Error).self) { _ = try Switch.requireLiveState(state, now: 1000, isCurrent: { _ in true }) }
        state.modelSwitch = .init(outcome: .timedOut)
        #expect(try Switch.requireLiveState(state, now: 1000, isCurrent: { _ in true }).modelSwitch?.outcome == .timedOut)
    }

    @Test func explicitSelectionIsAllOrNothing() throws {
        let local = [ModelInfo(id: "a", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1),
                     ModelInfo(id: "unsupported", modelType: "unknown", sizeBytes: 1, estimatedMemoryGb: 1)]
        #expect(try Switch.selectModels(requested: ["a", "a"], local: local, capabilities: []) == ["a"])
        #expect(throws: (any Error).self) { _ = try Switch.selectModels(requested: ["a", "missing"], local: local, capabilities: []) }
        #expect(throws: (any Error).self) { _ = try Switch.selectModels(requested: ["a", "unsupported"], local: local, capabilities: []) }
        #expect(try Switch.selectModels(requested: [], local: local, capabilities: []) == ["a"])
    }

    @Test func matchingReceiptRequiredAndTimeoutNeverSignals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = ProviderModelSwitchRequest(target: try #require(ProcessIdentity.current()), models: ["new"], timeoutSeconds: 0)
        let mailbox = LifecycleMailbox(identity: request.target, directory: directory)
        #expect(try Switch.terminalReceipt(.init(requestID: "old", outcome: .switched, models: ["new"]), request: request) == nil)
        #expect(try Switch.terminalReceipt(.init(requestID: request.id, outcome: .switching, models: ["new"]), request: request) == nil)
        #expect(throws: (any Error).self) {
            _ = try Switch.terminalReceipt(.init(requestID: request.id, outcome: .switched, models: ["old"]), request: request)
        }
        try mailbox.writeSwitchStatus(.init(requestID: request.id, outcome: .timedOut, remaining: 2))
        await #expect(throws: (any Error).self) { _ = try await Switch.wait(request: request, mailbox: mailbox) }
        #expect(request.target.isCurrent())
        try mailbox.writeSwitchStatus(.init(requestID: request.id, outcome: .switched, models: ["new"]))
        #expect(try await Switch.wait(request: request, mailbox: mailbox).models == ["new"])
    }

    @Test func durableSelectionOverridesOnlyLaunchManagedArgv() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("custom.toml")
        var original = ProviderConfig(provider: ProviderSettings(name: "retained"))
        original.backend.idleTimeoutMins = 17
        original.backend.enabledModels = ["old"]
        try ConfigManager.save(original, to: path)
        try ProviderModelSelection.save(["new"], configPath: path)
        let loaded = try ConfigManager.load(from: path)
        #expect(loaded.backend.enabledModels == ["new"])
        #expect(loaded.provider.name == "retained" && loaded.backend.idleTimeoutMins == 17)
        let models = ["old", "new"].map { ModelInfo(id: $0, sizeBytes: 1, estimatedMemoryGb: 1) }
        func restartedSelection(managed: Bool) -> [String] {
            let pinned = Start.usesPinnedModelSelection(configPath: path, launchManaged: managed)
            return advertisedModels(from: models, config: loaded, modelOverrides: pinned ? [] : ["old"]).map(\.id)
        }
        #expect(restartedSelection(managed: true) == ["new"])
        #expect(restartedSelection(managed: false) == ["old"])
        try ProviderModelSelection.save([], configPath: path)
        #expect(try ConfigManager.load(from: path).backend.enabledModels == [])
    }

    @Test func mailboxSeparatesSwitchFromStopAndBindsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 1)
        let mailbox = LifecycleMailbox(identity: identity, directory: directory)
        let request = ProviderModelSwitchRequest(target: identity, models: ["new"], timeoutSeconds: 0, createdAt: 100)
        let drain = ProviderDrainRequest(target: identity, timeoutSeconds: 1)
        try mailbox.writeRequest(drain)
        try mailbox.writeSwitchRequest(request)
        #expect(mailbox.readRequest() == drain && mailbox.readSwitchRequest() == request)
        #expect(request.isValid(for: identity, now: 100))
        let reusedPID = ProcessIdentity(pid: 42, startTimeMicros: 2)
        #expect(!request.isValid(for: reusedPID, now: 100))
        #expect(!request.isValid(for: identity, now: 4000))
        #expect(LifecycleMailbox(identity: reusedPID, directory: directory).readSwitchRequest() == nil)
        var state = DaemonState(pid: 42, processIdentity: identity, version: "test", writtenAt: 100, startedAt: 90)
        state.modelSwitch = .init(requestID: request.id, outcome: .switched, models: ["new"])
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(DaemonState.self, from: encoder.encode(state)).modelSwitch == state.modelSwitch)
    }
}

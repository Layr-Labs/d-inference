import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot snapshot persistence and wire coding")
struct AutopilotSnapshotCodingTests {
    private func snapshot() -> ModelAutopilotSnapshot {
        var value = ModelAutopilotSnapshot(enabled: true, minDwellSeconds: 180,
            pinnedModels: ["gemma"], maxModelSlots: 3,
            residentModels: [.init(modelId: "gemma", residentSeconds: 120, idleSeconds: 60,
                weightsGb: 17.4, residentGb: 14.8)], freeForLoadNoEvictGb: 22,
            activeCommandId: "active", lastCommandId: "previous", lastCommandStatus: .succeeded)
        value.observeOnly = true
        value.sessionId = "test-session"
        value.revision = "test-revision"
        value.selectedModels = ["gemma", "qwen"]
        value.loadHistory = [.init(modelId: "gemma", loadMs: 2000, measuredAtMs: 10000, weightHash: "test-hash")]
        value.lastElapsedMs = 3000
        value.lastReleaseMs = 1000
        value.lastLoadMs = 2000
        return value
    }

    @Test func enrolledDaemonStateRemainsReadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autopilot-state-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = snapshot()
        let state = DaemonState(pid: 123, processIdentity: .init(pid: 123, startTimeMicros: 90_000_000),
            version: "test", writtenAt: 100, startedAt: 90, warmModels: ["gemma"],
            lifecycle: .init(outcome: .serving), autopilot: expected, autopilotPhase: "shadow")
        DaemonStateFile.write(state, to: url)
        let actual = try #require(DaemonStateFile.read(from: url))
        #expect(actual == state)
        #expect(actual.processIdentity == state.processIdentity)
        #expect(actual.lifecycle?.outcome == .serving)
        #expect(actual.pid == 123)
        #expect(actual.warmModels == ["gemma"])
        #expect(actual.autopilot == expected)
        #expect(actual.autopilotPhase == "shadow")
    }

    @Test func newSnapshotsRemainReadableByThePreUpdateWatchdog() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let expected = DaemonState(pid: 123, version: "0.9.16", writtenAt: 100, startedAt: 90,
            autopilot: snapshot(), autopilotPhase: "shadow")
        let data = try encoder.encode(expected)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["autopilot"] == nil)
        #expect(json["autopilot_state"] != nil)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let old = try decoder.decode(LegacyAutopilotDaemonState.self, from: data)
        #expect(old.version == "0.9.16")
        #expect(old.writtenAt == 100)
        #expect(old.autopilot == nil)
        #expect(try decoder.decode(DaemonState.self, from: data) == expected)
    }

    @Test func previousReleaseSnapshotsStillDecodeIncludingAutopilot() throws {
        let expected = DaemonState(pid: 123, version: "0.9.15", writtenAt: 100, startedAt: 90,
            autopilot: snapshot(), autopilotPhase: "shadow")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var old = try #require(JSONSerialization.jsonObject(with: encoder.encode(expected)) as? [String: Any])
        old["autopilot"] = old.removeValue(forKey: "autopilot_state")
        let data = try JSONSerialization.data(withJSONObject: old)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(throws: DecodingError.self) { try decoder.decode(LegacyAutopilotDaemonState.self, from: data) }
        #expect(try decoder.decode(DaemonState.self, from: data) == expected)
    }

    @Test(arguments: [false, true])
    func snapshotDecodesWireAndDaemonKeyStrategies(convertSnakeCase: Bool) throws {
        let expected = snapshot()
        let data = try JSONEncoder().encode(expected)
        let decoder = JSONDecoder()
        if convertSnakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        #expect(try decoder.decode(ModelAutopilotSnapshot.self, from: data) == expected)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["observe_only"] as? Bool == true)
        #expect(json["observeOnly"] == nil)
        #expect(json["protocol"] as? Int == 2)
        let residents = try #require(json["resident_models"] as? [[String: Any]])
        #expect(residents.first?["resident_gb"] as? Double == 14.8)
        let history = try #require(json["load_history"] as? [[String: Any]])
        #expect(history.first?["weight_hash"] as? String == "test-hash")
    }

    @Test(arguments: [false, true])
    func absentOptionalFieldsRemainAbsent(convertSnakeCase: Bool) throws {
        let expected = ModelAutopilotSnapshot(enabled: false)
        let decoder = JSONDecoder()
        if convertSnakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        #expect(try decoder.decode(ModelAutopilotSnapshot.self,
            from: JSONEncoder().encode(expected)) == expected)
    }

    @Test(arguments: [false, true])
    func missingRequiredFieldsAreStillRejected(convertSnakeCase: Bool) throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        json.removeValue(forKey: "observe_only")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        if convertSnakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        #expect(throws: DecodingError.self) { try decoder.decode(ModelAutopilotSnapshot.self, from: data) }
    }
}

import Foundation
import Testing
@testable import ProviderCoreFoundation

// The schedule-posture + identity blocks of DaemonState are the app's
// availability/contributions read channel. They must round-trip losslessly
// and stay ABSENT (nil, omitted on the wire) for state files written by
// pre-schedule-reporting daemons — backwards compatibility at schema 1.

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dstate-sched-\(UUID().uuidString).json")
}

@Suite("DaemonState schedule + identity fields")
struct DaemonStateScheduleIdentityTests {
    @Test("schedule + identity fields round-trip through the state file")
    func roundTrip() throws {
        let url = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var state = DaemonState(pid: 4242, version: "0.9.0", writtenAt: 1_000, startedAt: 900)
        state.schedule = DaemonState.SchedulePosture(
            mode: "scheduled-active",
            summary: "Mon,Tue,Wed,Thu,Fri 20:00-07:00",
            nextChangeAtEpoch: 1_800)
        state.identity = DaemonState.Identity(
            providerName: "darkbloom-mac16-1",
            operatorAddress: "acct-test-123")

        DaemonStateFile.write(state, to: url)
        let decoded = try #require(DaemonStateFile.read(from: url))

        #expect(decoded.schedule?.mode == "scheduled-active")
        #expect(decoded.schedule?.summary == "Mon,Tue,Wed,Thu,Fri 20:00-07:00")
        #expect(decoded.schedule?.nextChangeAtEpoch == 1_800)
        #expect(decoded.identity?.providerName == "darkbloom-mac16-1")
        #expect(decoded.identity?.operatorAddress == "acct-test-123")
    }

    @Test("absent fields decode as nil and stay omitted when re-encoded")
    func absenceStaysAbsent() throws {
        // A pre-schedule-reporting state file: hand-shaped JSON without the
        // new keys must decode (schema 1 continues to admit it).
        let legacyJSON = """
        {
          "schema": 1,
          "pid": 7,
          "version": "0.8.5",
          "written_at": 1000,
          "started_at": 900,
          "warm_models": [],
          "inference_active": false,
          "stats": {"requests_served": 0, "tokens_generated": 0, "usage_gaps": 0}
        }
        """
        let url = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(legacyJSON.utf8).write(to: url)

        let decoded = try #require(DaemonStateFile.read(from: url))
        #expect(decoded.schedule == nil)
        #expect(decoded.identity == nil)

        // Re-encoding MUST NOT materialize the keys: downstream readers key
        // "reported vs. not reported" on presence, not on null values.
        DaemonStateFile.write(decoded, to: url)
        let reencoded = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!reencoded.contains("\"schedule\""))
        #expect(!reencoded.contains("\"identity\""))
    }

    @Test("optional subfields omit cleanly")
    func optionalSubfields() throws {
        let url = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var state = DaemonState(pid: 1, version: "x", writtenAt: 1, startedAt: 1)
        state.schedule = DaemonState.SchedulePosture(mode: "always", summary: "always available")
        state.identity = DaemonState.Identity(providerName: "darkbloom")
        DaemonStateFile.write(state, to: url)

        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(raw.contains("\"next_change_at_epoch\"") == false)
        #expect(raw.contains("\"operator_address\"") == false)
        #expect(raw.contains("\"provider_name\":\"darkbloom\""))

        let decoded = try #require(DaemonStateFile.read(from: url))
        #expect(decoded.schedule?.mode == "always")
        #expect(decoded.schedule?.nextChangeAtEpoch == nil)
        #expect(decoded.identity?.providerName == "darkbloom")
        #expect(decoded.identity?.operatorAddress == nil)
    }

    @Test("wire keys use snake_case expected by consumers")
    func wireKeyCasing() throws {
        let url = tmpStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var state = DaemonState(pid: 1, version: "x", writtenAt: 1, startedAt: 1)
        state.schedule = DaemonState.SchedulePosture(
            mode: "scheduled-off", summary: "Sat,Sun 09:00-18:00", nextChangeAtEpoch: 4_096)
        state.identity = DaemonState.Identity(providerName: "n", operatorAddress: "acct-x")
        DaemonStateFile.write(state, to: url)

        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for key in ["\"schedule\"", "\"mode\"", "\"summary\"", "\"next_change_at_epoch\"",
                    "\"identity\"", "\"provider_name\"", "\"operator_address\""] {
            #expect(raw.contains(key), "missing wire key \(key)")
        }
    }
}

// Contract under test: `DaemonState.runtimeIntegrity`, an optional field on
// `DaemonState` (Sources/ProviderCore/Service/DaemonStateFile.swift), nested
// the same way `Trust` is:
//
//     public var runtimeIntegrity: RuntimeIntegrity?
//
//     public struct RuntimeIntegrity: Codable, Sendable, Equatable {
//         public var status: String              // "outdated"
//         public var mismatchCount: Int
//         public var mismatches: [RuntimeMismatch] // component/expected/got
//                                                    // (reuses ProviderCore's
//                                                    // existing
//                                                    // Protocol/Types.swift
//                                                    // RuntimeMismatch)
//         public var receivedAt: Double           // epoch seconds
//         public init(status: String, mismatchCount: Int,
//                     mismatches: [RuntimeMismatch], receivedAt: Double)
//     }
//
// `schema`/`DaemonState.currentSchema` stay at 1 -- this is an additive
// optional field, not a schema bump, so older CLIs and older state files
// keep working.
//
// A JSON file written by a pre-change daemon (no `runtime_integrity` key)
// still decodes via `DaemonStateFile.read`, with the new field nil. A
// `DaemonState` with `runtimeIntegrity` set round-trips exactly through
// `DaemonStateFile.write` / `DaemonStateFile.read`.

import Foundation
import Testing
@testable import ProviderCore

@Suite("DaemonState runtime-integrity coding")
struct DaemonStateRuntimeIntegrityCodingTests {

    @Test("a state file written before this change decodes with the new field nil")
    func legacyStateFileDecodesWithNilRuntimeIntegrity() throws {
        // Exactly the required (non-optional) DaemonState keys, snake_case,
        // as a pre-change daemon would have written -- no `runtime_integrity`.
        let legacyJSON = """
        {
          "schema": 1,
          "pid": 4242,
          "version": "0.9.0",
          "written_at": 1000.0,
          "started_at": 900.0,
          "warm_models": [],
          "inference_active": false,
          "stats": {"requests_served": 0, "tokens_generated": 0, "usage_gaps": 0}
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-daemon-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(legacyJSON.utf8).write(to: url)

        let decoded = try #require(DaemonStateFile.read(from: url))
        #expect(decoded.pid == 4242)
        #expect(decoded.runtimeIntegrity == nil)
    }

    @Test("a state file with runtimeIntegrity set round-trips exactly")
    func runtimeIntegrityRoundTripsThroughWriteAndRead() throws {
        var state = DaemonState(
            pid: 777, version: "1.2.3", writtenAt: 5000, startedAt: 4000)
        state.runtimeIntegrity = DaemonState.RuntimeIntegrity(
            status: "outdated",
            mismatchCount: 2,
            mismatches: [
                RuntimeMismatch(component: "binary_hash", expected: "aaa111", got: "bbb222"),
                RuntimeMismatch(component: "template_hash:chatml", expected: "ccc333", got: "ddd444"),
            ],
            receivedAt: 4999.5)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-daemon-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        DaemonStateFile.write(state, to: url)
        let decoded = try #require(DaemonStateFile.read(from: url))

        #expect(decoded == state)
        #expect(decoded.runtimeIntegrity?.status == "outdated")
        #expect(decoded.runtimeIntegrity?.mismatchCount == 2)
        #expect(decoded.runtimeIntegrity?.mismatches.count == 2)
        #expect(decoded.runtimeIntegrity?.mismatches.first?.component == "binary_hash")
        #expect(decoded.runtimeIntegrity?.receivedAt == 4999.5)
    }
}

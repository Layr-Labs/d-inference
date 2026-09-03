// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

@Suite("EngineV2 production wiring: state persistence and kill switch", .serialized)
struct EngineV2ProductionStatePersistenceKillSwitchTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }
    @Test("a refused explicit paged load reaches the state file as a non-serving slot")
    func daemonStateCarriesRefusedPagedLoad() async throws {
        // An explicit paged request that cannot be built REFUSES, so no
        // engine and no live slot survives. `recordModelLoadError` writes
        // the state file immediately, and the join turns that record into a
        // slot entry rather than leaving doctor to guess from absence.
        // `recordModelLoadError` writes the REAL state file, so redirect it
        // through the per-loop seam (a process-global DARKBLOOM_STATE_FILE
        // setenv would race concurrently running suites' daemon-state
        // writes into this file) — then read the bytes back, which is the
        // actual contract: the CLI decodes this file, it does not call
        // into the daemon.
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dstate-refused-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let loop = try productionMakeWiringLoop(kvBackend: "paged")
        await loop.setDaemonStateFileForTesting(stateURL)
        await loop.recordModelLoadError(
            model: "gemma-4-26b-qat-4bit",
            message: "Model 'gemma-4-26b-qat-4bit' loaded but its v2 engine construction "
                + "failed: engine_v2: paged KV backend explicitly requested but unavailable "
                + "— kernel preflight failed — unloaded")

        let slots = try #require(DaemonStateFile.read(from: stateURL)?.slots)
        #expect(slots.count == 1)
        #expect(slots[0].model == "gemma-4-26b-qat-4bit")
        #expect(slots[0].kvBackend == nil, "no engine was built; naming a backend would be a lie")
        #expect(slots[0].kvBackendRequested == "paged")
        #expect(slots[0].loadError?.contains("explicitly requested but unavailable") == true)
    }
    @Test("the kill switch degrade is reported, not hidden")
    func killSwitchDegradeIsReported() async throws {
        // `DARKBLOOM_CBV2_PAGED_KV=0` on a paged-configured fleet is a
        // deliberate rollback, and the fleet still has to SEE that the slot it
        // is measuring is not the backend it configured.
        let slot = try await productionHeartbeatSlot(kind: .contiguous, fallbackReason: "kill_switch")
        #expect(slot.kvBackendFallbackReason == "kill_switch")
    }
}

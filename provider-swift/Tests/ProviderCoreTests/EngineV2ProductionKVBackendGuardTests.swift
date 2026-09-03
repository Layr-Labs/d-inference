// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

@Suite("EngineV2 production wiring: KV backend guard and fallback")
struct EngineV2ProductionKVBackendGuardTests {
    @Test("kvBytesCapacity clamp: a ceiling above physical RAM is capped")
    func kvBytesCapacityClamp() {
        let physical: UInt64 = 16 * 1024 * 1024 * 1024  // 16 GiB
        // A sane budget passes through untouched.
        #expect(EngineV2Factory.clampKVBytesCapacity(
            4 * 1024 * 1024 * 1024, physicalBytes: physical) == 4 * 1024 * 1024 * 1024)
        // A ceiling larger than physical is clamped to physical.
        #expect(EngineV2Factory.clampKVBytesCapacity(
            Int.max, physicalBytes: physical) == Int(physical))
        // Negative degrades to 0 (the > 0 guard then rejects it upstream).
        #expect(EngineV2Factory.clampKVBytesCapacity(-1, physicalBytes: physical) == 0)
    }
}
// MARK: - KV-backend degrade → heartbeat

/// The KV-backend degrade is DELIBERATE and unchanged by these tests; what
/// they pin is that it stops being SILENT. The path under test is the real
/// one, end to end inside the provider: `ProductionBuild.kvBackendFallbackReason`
/// → `EngineV2Factory.makeBridge` → `EngineV2Bridge` → `backendSlotCapacity()`
/// → `BackendSlotCapacity.kv_backend_fallback_reason` on the heartbeat wire.
///
/// It rides the HEARTBEAT, not the telemetry-event sink, on purpose: the
/// once-per-construction `engine_v2_kv_backend` event is best-effort and
/// droppable, so a fleet that misses it books a degraded slot as a
/// deliberately-contiguous one for the life of the slot.
@Suite("EngineV2 production wiring: KV-backend degrade is visible on the heartbeat")
struct EngineV2KVBackendFallbackHeartbeatTests {


    @Test("a degraded slot reports the reason on EVERY heartbeat")
    func degradedSlotReportsTheReason() async throws {
        let slot = try await productionHeartbeatSlot(kind: .contiguous,
        fallbackReason: "kernel_preflight: paged kernels unavailable")
        // The resolved kind is contiguous — the degrade really happened and
        // the slot really serves contiguous. That is exactly why the kind
        // alone cannot carry the signal.
        #expect(slot.kvBackend == "contiguous")
        #expect(slot.kvBackendFallbackReason == "kernel_preflight: paged kernels unavailable")

        // …and it survives the wire, where the coordinator reads it.
        let encoded = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(BackendSlotCapacity.self, from: encoded)
        #expect(decoded.kvBackendFallbackReason == slot.kvBackendFallbackReason)
    }

    @Test("a slot that did NOT degrade omits the field entirely")
    func cleanSlotOmitsTheField() async throws {
        // Same resolved kind as the degraded slot above — an operator who
        // configured contiguous. This half matters as much as the other: a
        // field that is always present is not a signal.
        let chosen = try await productionHeartbeatSlot(kind: .contiguous, fallbackReason: nil)
        #expect(chosen.kvBackend == "contiguous")
        #expect(chosen.kvBackendFallbackReason == nil)
        let chosenJSON = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(chosen)) as? [String: Any]
        #expect(chosenJSON?["kv_backend_fallback_reason"] == nil)

        // A paged slot that got what it asked for is likewise silent.
        let paged = try await productionHeartbeatSlot(kind: .paged, fallbackReason: nil)
        #expect(paged.kvBackend == "paged")
        #expect(paged.kvBackendFallbackReason == nil)
    }


    @Test("an over-long reason is clamped, keeping the class the fleet groups on")
    func longReasonIsClamped() async throws {
        // The reasons interpolate arbitrary MLX/Metal error text and this
        // rides every heartbeat of every slot, unlike the once-per-load event.
        let cap = EngineV2Bridge.maxHeartbeatFallbackReasonLength
        let long = "ineligible: " + String(repeating: "x", count: cap * 4)
        let slot = try await productionHeartbeatSlot(kind: .contiguous, fallbackReason: long)
        let reported = try #require(slot.kvBackendFallbackReason)
        #expect(reported.count == cap)
        // Truncated from the TAIL, so the leading class survives.
        #expect(reported.hasPrefix("ineligible:"))

        // The clamp must not turn "no degrade" into an empty-string degrade.
        #expect(EngineV2Bridge.heartbeatFallbackReason(nil) == nil)
    }
}
